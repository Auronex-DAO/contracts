# What is Auronex

Auronex is a gold-backed DeFi protocol on BNB Chain. Stake XAUM to earn ANX rewards,
morph ANX into AUGR backed by physical gold reserves, and participate in a ranked referral
ecosystem — bridging real-world gold assets with on-chain yield.

# The Platform

ANX is the core utility token in the Auronex ecosystem. It functions as the main rewards,
settlement, and progression asset that connects staking, claiming, restaking, and
metamorphosis into AUGR. Users can enter the system through approved package flows,
stake with XAUM or ANX depending on the product path, and earn reward-origin ANX
through network activity and protocol incentives.

Within the platform, ANX has several roles. It is used for reward distribution, fixed-fee
settlement in some staking and claim paths, treasury and burn-linked economic controls, and
conversion into longer-term ecosystem outcomes such as AUGR. Claimed ANX is not treated
as a purely free-floating reward token in every case; some flows split it between wallet liquidity
and reserved metamorphosis allocation, while other flows direct it fully into metamorphosis,
depending on the claim route.

ANX also supports user progression decisions. Holders may restake it, keep eligible wallet
balances, or commit it into the ANX-to-AUGR vault, where it is economically burned as part
of the path toward matured AUGR issuance. In practice, ANX is designed less as a passive
token and more as the ecosystem’s operating asset: it carries reward value, drives user
advancement, and links day-to-day participation with the protocol’s longer-term gold-backed
redemption narrative.

More at [Auronex App](https://auronex.app)

# Auronex Smart Contracts

The Solidity smart contracts powering the Auronex protocol.

## Overview

Auronex (ANX) is an ERC20 token built on OpenZeppelin with advanced administrative controls for protocol governance and fraud recovery.

## Contracts

| Contract | Description |
|----------|-------------|
| `Auronex.sol` | Main ERC20 token with tax hooks, blocklist, and admin controls |
| `AuronexProxy.sol` | UUPS proxy contract for upgradeability |
| `AUGR.sol` | The protocol's gold-backed token |
| `AUGRProxy.sol` | UUPS proxy contract for upgradeability |
| `AnxTaxHook.sol` | Tax hook implementation for dynamic tax mechanics |
| `AnxTaxHookProxy.sol` | UUPS proxy for the tax hook |

## AUGR — Gold-Backed Token

AUGR is the protocol's gold-backed token, physically backed by physical gold reserves. Users morph (convert) ANX into AUGR through the ANX-to-AUGR vault, where ANX is economically burned as part of the issuance process.

### Metamorphosis

Users commit ANX to the metamorphosis vault, which:
1. Burns the committed ANX
2. Issues matured AUGR backed by gold reserves
3. Links participation to real-world asset redemption

## Token Specifications

- **Name**: Auronex
- **Symbol**: ANX
- **Decimals**: 8
- **Max Supply**: 42,000,000 ANX

## Features

- **Capped Supply**: Maximum supply enforced at contract level
- **Pausable**: Emergency pause mechanism halts all transfers
- **Blocklist**: Admin-controlled address blocking
- **Admin Burn**: Designated role can burn tokens from any address
- **Confiscation**: Fraud recovery mechanism to move tokens to treasury
- **UUPS Upgradeable**: Proxy-based upgrade architecture

## Roles

| Role | Purpose |
|------|---------|
| `DEFAULT_ADMIN_ROLE` | Overall contract administration |
| `UPGRADER_ROLE` | Authorize implementation upgrades |
| `ADMIN_BURN_ROLE` | Burn tokens from any address |
| `PAUSER_ROLE` | Pause/unpause token transfers |
| `BLOCKER_ROLE` | Add/remove addresses from blocklist |
| `CONFISCATION_ROLE` | Confiscate tokens for fraud recovery |

## Security

- Built on OpenZeppelin v5 upgradeable contracts
- UUPS proxy pattern for safe upgradeability
- Constructor-based initializer disabling
- Blocklist enforcement in transfer validation

## Development

```bash
# Install dependencies
npm install

# Compile contracts
npx hardhat compile

# Run tests
npx hardhat test

# Deploy (requires .env configuration)
npx hardhat deploy
```

## License

MIT
