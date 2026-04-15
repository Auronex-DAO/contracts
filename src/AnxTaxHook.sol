// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ICLHooks, HOOKS_BEFORE_SWAP_OFFSET, HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET, HOOKS_AFTER_SWAP_OFFSET} from "@pancakeswap/v4-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "@pancakeswap/v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "@pancakeswap/v4-core/src/interfaces/IVault.sol";
import {ILockCallback} from "@pancakeswap/v4-core/src/interfaces/ILockCallback.sol";
import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@pancakeswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@pancakeswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@pancakeswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@pancakeswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";

interface IAnxPriceOracle {
    function getLatestAnxUsdPriceE8() external view returns (uint256);
}

/**
 * @title AnxTaxHook
 * @notice PancakeSwap Infinity (V4) hook that implements dynamic ANX taxes and embeds
 *         a Uniswap V3-compatible TWAP oracle. afterSwap() records observations;
 *         beforeSwap() reads a 30-minute geometric mean tick to determine the tax tier.
 *         The external observe() function exposes the same interface as a V3 pool so
 *         AnxPriceOracle can read the hook's TWAP directly.
 */
contract AnxTaxHook is Initializable, AccessControlUpgradeable, PausableUpgradeable, UUPSUpgradeable, ICLHooks, ILockCallback {
    using SafeCast for uint256;
    using SafeCast for int256;
    using PoolIdLibrary for PoolKey;

    // ── Roles ────────────────────────────────────────────────────────────────
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant TAX_ADMIN_ROLE = keccak256("TAX_ADMIN_ROLE");

    // ── Core state ───────────────────────────────────────────────────────────
    ICLPoolManager public poolManager;
    IVault public vault;
    IAnxPriceOracle public priceOracle;   // kept for staking/AUGR; not used for tax tiers
    Currency public anxToken;
    address public taxTreasury;

    uint256 public constant BPS_DENOMINATOR = 10000;

    // ── Tax configuration ────────────────────────────────────────────────────
    uint256 public buyTaxBps;            // 5%  (price <= $1.00)
    uint256 public buyPremiumTaxBps;     // 3%  (price > $1.00)
    uint256 public sellPremiumTaxBps;    // 3%  (> $1.00)
    uint256 public sellUpsideTaxBps;     // 5%  ($0.25 – $1.00)
    uint256 public sellParTaxBps;        // 8%  ($0.21 – $0.25)
    uint256 public sellDefensiveTaxBps;  // 15% (< $0.21)

    uint256 public parThresholdPriceE8;    // $0.21
    uint256 public upsideThresholdPriceE8; // $0.25
    uint256 public premiumThresholdPriceE8;// $1.00

    mapping(address => bool) public isTaxExempt;

    // ── TWAP observation state ────────────────────────────────────────────────
    /// @dev Simplified V3 Oracle observation (no secondsPerLiquidityCumulative).
    struct Observation {
        uint32 blockTimestamp;
        int56  tickCumulative;
        bool   initialized;
    }

    // Packed into one storage slot (10 bytes total, 22 bytes padding).
    uint16 public  observationIndex;
    uint16 public  observationCardinality;
    uint16 public  observationCardinalityNext;
    int24  internal _currentTick;   // last tick recorded by afterSwap
    bool   internal _anxIsToken0;   // set on first afterSwap

    uint256 public minPriceE8;   // $0.18 floor  → 18_000_000
    uint256 public maxPriceE8;   // $5.00 ceiling → 500_000_000

    // 30-minute TWAP window (seconds). Alter via upgrade if needed.
    uint32 public constant TWAP_WINDOW = 1800;

    // Observation array — occupies 65535 storage slots, placed last so upgrades
    // can add new scalar variables above without shifting the array.
    Observation[65535] internal _obsArr;

    // ── Events / errors ───────────────────────────────────────────────────────
    event TaxTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event TaxExemptStatusChanged(address indexed account, bool isExempt);
    event TaxConfigUpdated(uint256 buyTax, uint256 buyPremium, uint256 sellPremium, uint256 sellUpside, uint256 sellPar, uint256 sellDefensive);
    event TaxThresholdsUpdated(uint256 parThreshold, uint256 upsideThreshold, uint256 premiumThreshold);

    error NotTreasury();
    error ZeroAddress();
    error OnlyPoolManager();
    error TaxTooHigh();
    error InvalidThresholds();

    modifier poolManagerOnly() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address upgrader,
        address taxAdmin,
        address _poolManager,
        address _vault,
        address _priceOracle,
        address _taxTreasury,
        address _anxToken
    ) external initializer {
        if (admin == address(0) || upgrader == address(0) || taxAdmin == address(0)) revert ZeroAddress();
        if (_poolManager == address(0) || _vault == address(0)) revert ZeroAddress();
        if (_priceOracle == address(0) || _taxTreasury == address(0) || _anxToken == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, upgrader);
        _grantRole(TAX_ADMIN_ROLE, taxAdmin);

        poolManager = ICLPoolManager(_poolManager);
        vault = IVault(_vault);
        priceOracle = IAnxPriceOracle(_priceOracle);
        taxTreasury = _taxTreasury;
        anxToken = Currency.wrap(_anxToken);

        buyTaxBps = 500;
        buyPremiumTaxBps = 300;
        sellPremiumTaxBps = 300;
        sellUpsideTaxBps = 500;
        sellParTaxBps = 800;
        sellDefensiveTaxBps = 1500;

        parThresholdPriceE8    = 21_000_000;
        upsideThresholdPriceE8 = 25_000_000;
        premiumThresholdPriceE8 = 100_000_000;

        isTaxExempt[_taxTreasury] = true;

        observationCardinality     = 1;
        observationCardinalityNext = 1;
        minPriceE8 = 18_000_000;
        maxPriceE8 = 500_000_000;
    }

    // ── Hooks registration ────────────────────────────────────────────────────

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return uint16(
            (uint16(1) << HOOKS_BEFORE_SWAP_OFFSET) |
            (uint16(1) << HOOKS_AFTER_SWAP_OFFSET)  |
            (uint16(1) << HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET)
        );
    }

    // ── beforeSwap ────────────────────────────────────────────────────────────

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override poolManagerOnly whenNotPaused returns (bytes4, BeforeSwapDelta, uint24) {
        if (isTaxExempt[sender]) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        bool isAnxZero = (key.currency0 == anxToken);
        bool isAnxOne  = (key.currency1 == anxToken);
        if (!isAnxZero && !isAnxOne) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 taxBps;
        if (params.zeroForOne) {
            taxBps = isAnxZero ? _getSellTaxBps() : _getBuyTaxBps();
        } else {
            taxBps = isAnxOne ? _getSellTaxBps() : _getBuyTaxBps();
        }

        if (taxBps > 0) {
            if (params.amountSpecified == type(int256).min) {
                return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
            }
            uint256 amount = params.amountSpecified < 0
                ? uint256(-params.amountSpecified)
                : uint256(params.amountSpecified);

            uint256 taxAmount = (amount * taxBps) / BPS_DENOMINATOR;

            if (taxAmount > 0) {
                // Tax is always collected in the specified currency (what the swapper is
                // paying). For sells (ANX is specified): tax in ANX. For buys (USDT is
                // specified): tax in USDT. Applying tax to the unspecified token causes a
                // unit mismatch — USDT-scale taxAmount misinterpreted as ANX wei — which
                // leaves the pool unable to settle, reverting with CurrencyNotSettled.
                Currency specifiedCurrency = params.zeroForOne ? key.currency0 : key.currency1;

                // vault.mint credits the hook with ERC-6909 tokens and records a
                // -taxAmount delta; the +taxAmount specifiedDelta nets it to zero.
                vault.mint(address(this), specifiedCurrency, taxAmount);

                return (
                    this.beforeSwap.selector,
                    toBeforeSwapDelta(taxAmount.toInt256().toInt128(), 0),
                    0
                );
            }
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ── afterSwap — records TWAP observation ─────────────────────────────────

    function afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, int128) {
        bool isAnxZero = (key.currency0 == anxToken);
        bool isAnxOne  = (key.currency1 == anxToken);
        if (!isAnxZero && !isAnxOne) return (this.afterSwap.selector, 0);

        // Fetch current tick from pool manager
        (, int24 tick, , ) = poolManager.getSlot0(key.toId());
        _currentTick = tick;

        uint32 blockTimestamp = uint32(block.timestamp);

        if (!_obsArr[0].initialized) {
            // First observation ever: initialise slot 0
            _obsArr[0] = Observation({
                blockTimestamp: blockTimestamp,
                tickCumulative: 0,
                initialized: true
            });
            _anxIsToken0 = isAnxZero;
            // observationIndex=0, observationCardinality=1 already set by initialize()
            return (this.afterSwap.selector, 0);
        }

        uint16 index          = observationIndex;
        uint16 cardinality    = observationCardinality;
        uint16 cardinalityNext = observationCardinalityNext;

        Observation storage last = _obsArr[index];

        // Same-block: skip (one write per block)
        if (last.blockTimestamp == blockTimestamp) return (this.afterSwap.selector, 0);

        // Grow cardinality if we are at the boundary and next > current
        uint16 cardinalityUpdated = cardinality;
        if (cardinalityNext > cardinality && index == (cardinality - 1)) {
            cardinalityUpdated = cardinalityNext;
        }

        uint16 indexUpdated = (index + 1) % cardinalityUpdated;

        uint32 delta     = blockTimestamp - last.blockTimestamp;
        int56  newCumul  = last.tickCumulative + int56(tick) * int56(int32(delta));

        _obsArr[indexUpdated] = Observation({
            blockTimestamp: blockTimestamp,
            tickCumulative: newCumul,
            initialized: true
        });

        observationIndex      = indexUpdated;
        observationCardinality = cardinalityUpdated;

        return (this.afterSwap.selector, 0);
    }

    /// @notice True when ANX is token0 in the pool. Set on the first afterSwap.
    ///         Read by AnxPriceOracle in HOOK_TWAP mode to determine token ordering.
    function anxIsToken0() external view returns (bool) {
        return _anxIsToken0;
    }

    // ── External observe() — V3-compatible interface ──────────────────────────

    /// @notice Returns tick cumulatives for each secondsAgo. Same ABI as IPancakeV3Pool.observe().
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        require(_obsArr[0].initialized, "I"); // not initialised

        uint16 index      = observationIndex;
        uint16 cardinality = observationCardinality;
        uint32 time       = uint32(block.timestamp);
        int24  tick       = _currentTick;

        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);

        for (uint256 i = 0; i < secondsAgos.length; i++) {
            tickCumulatives[i] = _observeSingle(time, secondsAgos[i], tick, index, cardinality);
        }
    }

    /// @notice Grow the observation buffer. Permissionless.
    ///         New slots start uninitialized; the binary search handles them.
    function increaseObservationCardinality(uint16 next) external {
        if (next > observationCardinalityNext) {
            observationCardinalityNext = next;
        }
    }

    /// @notice Return stored observation at index.
    function observations(uint256 index) external view returns (uint32, int56, bool) {
        Observation storage obs = _obsArr[index];
        return (obs.blockTimestamp, obs.tickCumulative, obs.initialized);
    }

    // ── Internal TWAP price ───────────────────────────────────────────────────

    /// @dev Returns the 30-minute geometric mean price in E8, or 0 if insufficient history.
    ///      Callers must treat 0 as "use fallback" rather than as a real price.
    function _readTwapE8() internal view virtual returns (uint256) {
        if (!_obsArr[0].initialized) return 0;

        uint32 time       = uint32(block.timestamp);
        uint16 cardinality = observationCardinality;
        uint16 index      = observationIndex;

        // Find oldest initialized observation
        Observation storage oldestObs = _obsArr[(index + 1) % cardinality];
        if (!oldestObs.initialized) oldestObs = _obsArr[0];

        // Require at least TWAP_WINDOW seconds of history
        if (time - oldestObs.blockTimestamp < TWAP_WINDOW) return 0;

        int24 tick = _currentTick;

        int56 cumAtWindow = _observeSingle(time, TWAP_WINDOW, tick, index, cardinality);
        int56 cumAtNow    = _observeSingle(time, 0,           tick, index, cardinality);

        int56 delta = cumAtNow - cumAtWindow;
        int24 meanTick;
        // Floor division (round toward −∞ for negative deltas)
        if (delta < 0 && delta % int56(int32(TWAP_WINDOW)) != 0) {
            meanTick = int24(delta / int56(int32(TWAP_WINDOW)) - 1);
        } else {
            meanTick = int24(delta / int56(int32(TWAP_WINDOW)));
        }

        return _tickToE8Price(meanTick);
    }

    /// @dev Convert a tick to an ANX/USDT price in E8 using OracleLibrary-style arithmetic.
    ///      Assumes the paired token is USDT with 18 decimals; ANX has 8 decimals.
    function _tickToE8Price(int24 tick) internal view returns (uint256) {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);

        // getQuoteAtTick pattern: compute (baseAmount=1e8 ANX_wei) of other token
        uint256 priceInOtherWei;
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            priceInOtherWei = _anxIsToken0
                ? FullMath.mulDiv(ratioX192, 1e8, uint256(1) << 192)
                : FullMath.mulDiv(uint256(1) << 192, 1e8, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, uint256(1) << 64);
            priceInOtherWei = _anxIsToken0
                ? FullMath.mulDiv(ratioX128, 1e8, uint256(1) << 128)
                : FullMath.mulDiv(uint256(1) << 128, 1e8, ratioX128);
        }

        // priceInOtherWei = USDT_wei per 1 ANX (human).
        // priceE8 = USDT_per_ANX * 1e8 = priceInOtherWei / 1e10
        uint256 priceE8 = priceInOtherWei / 1e10;

        if (priceE8 < minPriceE8) return minPriceE8;
        if (priceE8 > maxPriceE8) return maxPriceE8;
        return priceE8;
    }

    // ── Tax tier logic ────────────────────────────────────────────────────────

    function _getSellTaxBps() internal view returns (uint256) {
        uint256 priceE8 = _readTwapE8();
        if (priceE8 == 0) {
            // Bootstrap: no TWAP history yet — fall back to oracle
            try priceOracle.getLatestAnxUsdPriceE8() returns (uint256 p) {
                priceE8 = p;
            } catch {
                return sellDefensiveTaxBps;
            }
        }

        if (priceE8 > premiumThresholdPriceE8) return sellPremiumTaxBps;
        if (priceE8 > upsideThresholdPriceE8)  return sellUpsideTaxBps;
        if (priceE8 >= parThresholdPriceE8)    return sellParTaxBps;
        return sellDefensiveTaxBps;
    }

    function _getBuyTaxBps() internal view returns (uint256) {
        uint256 priceE8 = _readTwapE8();
        if (priceE8 == 0) {
            try priceOracle.getLatestAnxUsdPriceE8() returns (uint256 p) {
                priceE8 = p;
            } catch {
                return buyTaxBps;
            }
        }

        if (priceE8 > premiumThresholdPriceE8) return buyPremiumTaxBps;
        return buyTaxBps;
    }

    // ── Oracle observation internals (V3-compatible, no secondsPerLiquidity) ──

    function _observeSingle(
        uint32 time,
        uint32 secondsAgo,
        int24  tick,
        uint16 index,
        uint16 cardinality
    ) internal view returns (int56 tickCumulative) {
        if (secondsAgo == 0) {
            Observation storage last = _obsArr[index];
            if (last.blockTimestamp != time) {
                uint32 d = time - last.blockTimestamp;
                return last.tickCumulative + int56(tick) * int56(int32(d));
            }
            return last.tickCumulative;
        }

        uint32 target = time - secondsAgo;
        (Observation memory beforeOrAt, Observation memory atOrAfter) =
            _getSurroundingObs(time, target, tick, index, cardinality);

        if (target == beforeOrAt.blockTimestamp) return beforeOrAt.tickCumulative;
        if (target == atOrAfter.blockTimestamp)  return atOrAfter.tickCumulative;

        // Interpolate
        uint32 span      = atOrAfter.blockTimestamp - beforeOrAt.blockTimestamp;
        uint32 targetDelta = target - beforeOrAt.blockTimestamp;
        return beforeOrAt.tickCumulative +
            ((atOrAfter.tickCumulative - beforeOrAt.tickCumulative) / int56(int32(span))) *
            int56(int32(targetDelta));
    }

    function _transform(Observation memory last, uint32 ts, int24 tick)
        internal pure returns (Observation memory)
    {
        uint32 d = ts - last.blockTimestamp;
        return Observation({
            blockTimestamp: ts,
            tickCumulative: last.tickCumulative + int56(tick) * int56(int32(d)),
            initialized: true
        });
    }

    function _getSurroundingObs(
        uint32 time,
        uint32 target,
        int24  tick,
        uint16 index,
        uint16 cardinality
    ) internal view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        beforeOrAt = _obsArr[index]; // newest

        // Is target chronologically at or after the newest observation?
        if (_lte(time, beforeOrAt.blockTimestamp, target)) {
            if (beforeOrAt.blockTimestamp == target) return (beforeOrAt, atOrAfter);
            // Target is in the "future" of the newest obs — extrapolate
            return (beforeOrAt, _transform(beforeOrAt, target, tick));
        }

        // Target is older than newest — find oldest initialized observation
        beforeOrAt = _obsArr[(index + 1) % cardinality];
        if (!beforeOrAt.initialized) beforeOrAt = _obsArr[0];

        require(_lte(time, beforeOrAt.blockTimestamp, target), "OLD");

        return _binarySearch(time, target, index, cardinality);
    }

    function _binarySearch(
        uint32 time,
        uint32 target,
        uint16 index,
        uint16 cardinality
    ) internal view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        uint256 l = (index + 1) % cardinality; // oldest
        uint256 r = l + cardinality - 1;
        uint256 i;
        while (true) {
            i = (l + r) / 2;
            beforeOrAt = _obsArr[uint16(i % cardinality)];
            if (!beforeOrAt.initialized) { l = i + 1; continue; }
            atOrAfter = _obsArr[uint16((i + 1) % cardinality)];
            bool toa = _lte(time, beforeOrAt.blockTimestamp, target);
            if (toa && _lte(time, target, atOrAfter.blockTimestamp)) break;
            if (!toa) r = i - 1;
            else      l = i + 1;
        }
    }

    /// @dev Timestamp comparator safe for 32-bit overflow (V3 lte).
    function _lte(uint32 time, uint32 a, uint32 b) internal pure returns (bool) {
        if (a <= time && b <= time) return a <= b;
        uint256 aAdj = a > time ? a : uint256(a) + (1 << 32);
        uint256 bAdj = b > time ? b : uint256(b) + (1 << 32);
        return aAdj <= bAdj;
    }

    // ── Admin functions ───────────────────────────────────────────────────────

    function setTaxConfig(
        uint256 _buyTax, uint256 _buyPremium, uint256 _sellPremium,
        uint256 _sellUpside, uint256 _sellPar, uint256 _sellDefensive
    ) external onlyRole(TAX_ADMIN_ROLE) {
        if (_buyTax > BPS_DENOMINATOR || _buyPremium > BPS_DENOMINATOR ||
            _sellPremium > BPS_DENOMINATOR || _sellUpside > BPS_DENOMINATOR ||
            _sellPar > BPS_DENOMINATOR || _sellDefensive > BPS_DENOMINATOR) revert TaxTooHigh();
        buyTaxBps = _buyTax;
        buyPremiumTaxBps = _buyPremium;
        sellPremiumTaxBps = _sellPremium;
        sellUpsideTaxBps = _sellUpside;
        sellParTaxBps = _sellPar;
        sellDefensiveTaxBps = _sellDefensive;
        emit TaxConfigUpdated(_buyTax, _buyPremium, _sellPremium, _sellUpside, _sellPar, _sellDefensive);
    }

    function setTaxThresholds(
        uint256 _parThreshold, uint256 _upsideThreshold, uint256 _premiumThreshold
    ) external onlyRole(TAX_ADMIN_ROLE) {
        if (_parThreshold == 0 || _parThreshold >= _upsideThreshold || _upsideThreshold >= _premiumThreshold)
            revert InvalidThresholds();
        parThresholdPriceE8 = _parThreshold;
        upsideThresholdPriceE8 = _upsideThreshold;
        premiumThresholdPriceE8 = _premiumThreshold;
        emit TaxThresholdsUpdated(_parThreshold, _upsideThreshold, _premiumThreshold);
    }

    function setTaxTreasury(address _taxTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_taxTreasury == address(0)) revert ZeroAddress();
        isTaxExempt[taxTreasury] = false;
        emit TaxTreasuryUpdated(taxTreasury, _taxTreasury);
        taxTreasury = _taxTreasury;
        isTaxExempt[_taxTreasury] = true;
    }

    function setTaxExempt(address account, bool isExempt) external onlyRole(TAX_ADMIN_ROLE) {
        isTaxExempt[account] = isExempt;
        emit TaxExemptStatusChanged(account, isExempt);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    /// @notice Transfer accumulated tax vault-tokens to the taxTreasury.
    ///         The hook holds vault ERC-6909 tokens minted during each taxed swap.
    ///         This function opens a vault lock, burns those tokens, and takes the
    ///         underlying ERC-20 tokens directly to the treasury.
    function collectTaxes(Currency currency) external {
        if (msg.sender != taxTreasury) revert NotTreasury();
        uint256 balance = vault.balanceOf(address(this), currency);
        if (balance > 0) vault.lock(abi.encode(currency, balance));
    }

    /// @inheritdoc ILockCallback
    /// @dev Called by the vault during collectTaxes. Burns this hook's vault tokens
    ///      and sends the underlying currency directly to the taxTreasury.
    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(vault)) revert OnlyPoolManager(); // reuse error: caller must be vault
        (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));
        vault.burn(address(this), currency, amount);
        vault.take(currency, taxTreasury, amount);
        return "";
    }

    // ── ICLHooks no-ops ───────────────────────────────────────────────────────

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        return this.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        return this.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ICLPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4)
    {
        return this.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(address, PoolKey calldata, ICLPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, BalanceDelta)
    {
        return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ICLPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4)
    {
        return this.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(address, PoolKey calldata, ICLPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, BalanceDelta)
    {
        return (this.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4)
    {
        return this.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4)
    {
        return this.afterDonate.selector;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        newImplementation;
    }
}
