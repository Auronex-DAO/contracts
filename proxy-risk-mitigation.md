# Proxy Risk Mitigation (ANX Mainnet)

This runbook reduces scanner risk from single-key upgrade/admin control while keeping existing proxy addresses unchanged.

## Outcome

- Proxy addresses stay the same.
- `DEFAULT_ADMIN_ROLE` and `UPGRADER_ROLE` migrate from deployer EOA to `ADMIN_MULTISIG`.
- A single Safe multisend proposal performs the full migration batch.

## Preconditions

- `ADMIN_MULTISIG` is deployed and signer threshold is configured.
- Safe proposer key and tx-service API key are available.
- `apps/anx-contracts/deployments/bnbMainnet.json` is current.

## Dry-run

From `apps/anx-contracts`:

```bash
bun run propose-proxy-risk-mitigation:mainnet
```

This prints:

- mode (`dry-run`),
- number of proxy contracts targeted,
- number of role actions (`grant`, `revoke`),
- `from` and `to` role holders.

## Execute (submit Safe proposal)

Required env:

- `ADMIN_MULTISIG`
- `SAFE_PROPOSER_PRIVATE_KEY`
- `SAFE_TRANSACTION_SERVICE_API_KEY`
- `BNB_MAINNET_RPC_URL` (or `RPC_URL`)
- optional: `SAFE_TX_SERVICE_URL`

Run:

```bash
bun run propose-proxy-risk-mitigation:mainnet --execute
```

The script proposes one Safe tx that batches, for each core proxy:

1. `grantRole(DEFAULT_ADMIN_ROLE, ADMIN_MULTISIG)`
2. `grantRole(UPGRADER_ROLE, ADMIN_MULTISIG)`
3. `revokeRole(UPGRADER_ROLE, DEPLOYER_ADDRESS)`
4. `revokeRole(DEFAULT_ADMIN_ROLE, DEPLOYER_ADDRESS)`

## Post-execution checks

For each target proxy:

1. `hasRole(DEFAULT_ADMIN_ROLE, ADMIN_MULTISIG) == true`
2. `hasRole(UPGRADER_ROLE, ADMIN_MULTISIG) == true`
3. `hasRole(DEFAULT_ADMIN_ROLE, DEPLOYER_ADDRESS) == false`
4. `hasRole(UPGRADER_ROLE, DEPLOYER_ADDRESS) == false`

## Next hardening step

After role migration, move upgrade execution behind a timelock process (24h-72h) so scanner trust assumptions improve further.
