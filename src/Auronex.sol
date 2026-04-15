// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20BurnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {
    ERC20CappedUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";
import {
    ERC20PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Auronex is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20CappedUpgradeable,
    ERC20PausableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    uint8 public constant TOKEN_DECIMALS = 8;
    uint256 public constant MAX_SUPPLY = 42_000_000 * 10 ** TOKEN_DECIMALS;
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant ADMIN_BURN_ROLE = keccak256("ADMIN_BURN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant BLOCKER_ROLE = keccak256("BLOCKER_ROLE");
    bytes32 public constant CONFISCATION_ROLE = keccak256("CONFISCATION_ROLE");

    /// @notice Addresses blocked from sending or receiving ANX.
    mapping(address => bool) public isBlocked;

    /// @notice Address that receives confiscated tokens (treasury).
    address public confiscationTreasury;

    // ── Events ────────────────────────────────────────────────────────────────

    /// @notice Emitted when an admin burns tokens from any address.
    event AdminBurned(address indexed by, address indexed from, uint256 amount);

    /// @notice Emitted when tokens are confiscated from an address to the treasury.
    event Confiscated(address indexed by, address indexed from, address indexed to, uint256 amount);

    /// @notice Emitted when an address is added to or removed from the blocklist.
    event BlockStatusChanged(address indexed account, bool blocked);

    // ── Errors ────────────────────────────────────────────────────────────────

    error Blocked(address account);
    error CannotBlockZeroAddress();
    error CannotRescueANX();
    error ConfiscationTreasuryNotSet();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address upgrader, address initialSupplyRecipient) external initializer {
        __ERC20_init("Auronex", "ANX");
        __ERC20Burnable_init();
        __ERC20Capped_init(MAX_SUPPLY);
        __ERC20Pausable_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, upgrader);
        _grantRole(ADMIN_BURN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(BLOCKER_ROLE, admin);
        _grantRole(CONFISCATION_ROLE, admin);
        _mint(initialSupplyRecipient, MAX_SUPPLY);
    }

    function decimals() public pure override returns (uint8) {
        return TOKEN_DECIMALS;
    }

    // ── Admin burn ────────────────────────────────────────────────────────────

    /// @notice Burn tokens from any address. Intended for protocol enforcement
    ///         (e.g. claim fee burn, penalty). Emits AdminBurned for auditability.
    function adminBurn(address from, uint256 amount) external onlyRole(ADMIN_BURN_ROLE) {
        _burn(from, amount);
        emit AdminBurned(msg.sender, from, amount);
    }

    // ── Confiscation ──────────────────────────────────────────────────────────

    /// @notice Set the treasury address that receives confiscated tokens.
    function setConfiscationTreasury(address treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury == address(0)) revert CannotBlockZeroAddress();
        confiscationTreasury = treasury;
    }

    /// @notice Confiscate tokens from a fraudster and send them to the treasury.
    ///         Intended for fraud recovery — the treasury can redistribute to the victim.
    ///         Use setBlocked() first to freeze the fraudster before confiscating.
    function confiscate(address from, uint256 amount) external onlyRole(CONFISCATION_ROLE) {
        if (confiscationTreasury == address(0)) revert ConfiscationTreasuryNotSet();
        _confiscating = true;
        _transfer(from, confiscationTreasury, amount);
        _confiscating = false;
        emit Confiscated(msg.sender, from, confiscationTreasury, amount);
    }

    // ── Pause ─────────────────────────────────────────────────────────────────

    /// @notice Pause all token transfers. Use only for emergencies.
    ///         DEX trading halts while paused and resumes on unpause.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ── Blocklist ─────────────────────────────────────────────────────────────

    /// @notice Block or unblock an address from sending or receiving ANX.
    ///         DEX LP addresses should never be blocked.
    function setBlocked(address account, bool blocked) external onlyRole(BLOCKER_ROLE) {
        if (account == address(0)) revert CannotBlockZeroAddress();
        isBlocked[account] = blocked;
        emit BlockStatusChanged(account, blocked);
    }

    // ── Token rescue ──────────────────────────────────────────────────────────

    /// @notice Recover ERC20 tokens accidentally sent to this contract address.
    ///         ANX itself cannot be rescued (use adminBurn for that).
    function rescueERC20(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(this)) revert CannotRescueANX();
        IERC20(token).safeTransfer(to, amount);
    }

    // ── Internal overrides ────────────────────────────────────────────────────

    /// @dev _confiscating is set during confiscate() to allow moving blocked tokens.
    bool private _confiscating;

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20CappedUpgradeable, ERC20PausableUpgradeable)
    {
        if (!_confiscating) {
            if (from != address(0) && isBlocked[from]) revert Blocked(from);
            if (to != address(0) && isBlocked[to]) revert Blocked(to);
        }
        super._update(from, to, value);
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(UPGRADER_ROLE) {
        newImplementation;
    }
    /// @dev Storage gap for upgrade headroom. Consume slots here when adding new variables.
    uint256[50] private __gap;
}