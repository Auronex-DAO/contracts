# Security Posture - Auronex Contracts

**Last Updated:** May 26, 2026  
**Solidity Version:** 0.8.34  
**Network Focus:** BNB Mainnet (Chain ID 56)

---

## Summary

Auronex uses upgradeable proxy contracts with role-based access control.  
The primary security objective is minimizing governance and upgrade abuse risk while preserving operational recoverability.

Core controls:

- multisig-governed privileged operations,
- explicit role separation,
- auditable Safe proposal workflow,
- public runbooks and verification artifacts.

---

## Current Security Model

### 1. Upgradeability and Privilege Model

- Contracts are upgradeable (UUPS pattern).
- Sensitive permissions are managed through `AccessControl`.
- Critical roles include:
  - `DEFAULT_ADMIN_ROLE`
  - `UPGRADER_ROLE`
  - operational roles (e.g., `SETTLER_ROLE`, oracle/admin roles) where required.

### 2. Governance Hardening Direction

Operational policy is to avoid single-key privileged control and execute privileged changes through multisig governance flow.

Implemented tooling:

- `apps/anx-contracts/scripts/propose-proxy-risk-mitigation.ts`
- package entrypoint: `propose-proxy-risk-mitigation:mainnet`

This utility prepares/submits a single Safe MultiSend proposal that, per core proxy, performs:

1. `grantRole(DEFAULT_ADMIN_ROLE, ADMIN_MULTISIG)`
2. `grantRole(UPGRADER_ROLE, ADMIN_MULTISIG)`
3. `revokeRole(UPGRADER_ROLE, DEPLOYER_ADDRESS)`
4. `revokeRole(DEFAULT_ADMIN_ROLE, DEPLOYER_ADDRESS)`

Reference runbook:

- `/docs/proxy-risk-mitigation.md`

---

## Threat Areas and Controls

### A. Upgrade Abuse Risk

**Risk:** Malicious/unsafe implementation upgrade.  
**Controls:**

- multisig approval path for privileged operations,
- explicit role-holder visibility,
- public on-chain audit trail via Safe and chain explorers.

### B. Privileged Role Concentration

**Risk:** Single actor can alter protocol behavior.  
**Controls:**

- migrate admin/upgrader rights away from EOA to multisig,
- least-privilege role assignment,
- revoke stale/unneeded elevated roles.

### C. Operational Execution Errors

**Risk:** Incorrect admin transaction payloads.  
**Controls:**

- script-driven calldata generation,
- dry-run-first workflow,
- post-execution verification checklist.

---

## Verification Checklist (Reviewer/Operator)

For each core proxy:

1. `hasRole(DEFAULT_ADMIN_ROLE, ADMIN_MULTISIG) == true`
2. `hasRole(UPGRADER_ROLE, ADMIN_MULTISIG) == true`
3. `hasRole(DEFAULT_ADMIN_ROLE, DEPLOYER_ADDRESS) == false`
4. `hasRole(UPGRADER_ROLE, DEPLOYER_ADDRESS) == false`

Additionally:

1. Proxy and implementation contracts are source-verified.
2. Safe proposal and execution transactions are publicly linked.
3. ANX proxy/token address continuity is preserved.

---

## Public Security Artifacts

- Risk reclassification dossier: `/docs/anx-risk-reclassification-packet.md`
- PDF dossier: `/docs/anx-risk-reclassification-packet.pdf`
- Governance hardening runbook: `/docs/proxy-risk-mitigation.md`
- Migration utility: `apps/anx-contracts/scripts/propose-proxy-risk-mitigation.ts`

---

## Residual Risks

No governance setup has zero risk. Remaining risks include:

- multisig signer compromise,
- governance process failure,
- delayed detection/response.

Mitigation strategy:

- signer operational security,
- strict change-management discipline,
- routine role/state verification and public traceability.

---

## Planned Hardening

1. Enforce formal timelock controls for upgrade path (target 24-72h delay window).
2. Continue role minimization across non-essential privileges.
3. Maintain updated public disclosures for governance and security posture.
