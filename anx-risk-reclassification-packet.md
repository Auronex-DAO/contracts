# ANX Risk Reclassification Dossier

## 1. Executive Summary

ANX on BNB Smart Chain has been flagged as high risk primarily due to upgradeable-contract architecture and third-party risk labeling. This dossier provides a full evidence package, governance disclosures, and technical verification checklist for risk reclassification reviews by scanners, exchanges, and data aggregators.

This document is intended for:

- token risk engines,
- exchange listing/risk teams,
- analytics platforms,
- community due-diligence reviewers.

## 2. Scope and Objective

### Objective

Request reclassification from generic "high risk" treatment to a governance-aware classification that reflects the project’s current upgrade/admin controls.

### Scope

- ANX proxy and implementation architecture,
- privilege model and role governance,
- operational controls,
- evidence and verifier workflow.

## 3. Token Identity

- Token name: Auronex
- Ticker: ANX
- Network: BNB Smart Chain (Chain ID 56)
- Token proxy address: `0xc3ab9c26bc44776f3fc770afd90a27cfb826965c`

## 4. Current External Risk Labels

### Observed cautions

- "Contract Upgradeable"
- "Risk Flagged"

### Interpretation

An upgradeable label by itself indicates changeability, not necessarily maliciousness. The principal risk determinant is who controls upgrades, how those rights are constrained, and how transparently changes are communicated and executed.

## 5. Root Cause Analysis of the "High Risk" Outcome

The high-risk profile is usually driven by one or more of the following scanner heuristics:

1. Upgradeability present.
2. Privileged role concentration (single EOA or opaque governance).
3. Incomplete or unclear verification/disclosure artifacts.
4. Inability for automated systems to infer hard governance constraints.

## 6. Governance and Security Control Model

### 6.1 Upgradeability model

ANX uses an upgradeable proxy architecture. Proxy use is disclosed and intentional for maintenance and controlled iteration.

### 6.2 Administrative control hardening

Administrative and upgrade privileges are migrated from single-key operation to multisig governance flow.

### 6.3 Role governance intent

- retain only operationally necessary privileged roles,
- remove or revoke unused elevated permissions,
- make role holders and authority boundaries publicly auditable.

### 6.4 Upgrade process constraints

Project policy is to execute privileged changes through multisig governance and auditable transaction trails, with additional delay controls recommended as the next hardening phase.

## 7. Technical Mitigation Package

### 7.1 Implemented migration utility

Repository utility (mainnet):

- Script: `apps/anx-contracts/scripts/propose-proxy-risk-mitigation.ts`
- Entrypoint: `propose-proxy-risk-mitigation:mainnet`

Behavior:

1. Reads `deployments/bnbMainnet.json`.
2. Enumerates core proxy contracts in scope.
3. For each proxy, generates actions in order:
   1. `grantRole(DEFAULT_ADMIN_ROLE, ADMIN_MULTISIG)`
   2. `grantRole(UPGRADER_ROLE, ADMIN_MULTISIG)`
   3. `revokeRole(UPGRADER_ROLE, DEPLOYER_ADDRESS)`
   4. `revokeRole(DEFAULT_ADMIN_ROLE, DEPLOYER_ADDRESS)`
4. Batches actions into one Safe MultiSend proposal.
5. Runs dry by default; submits only with `--execute`.

Important invariant:

- No token proxy address changes.
- No token migration required.
- No user balance migration required.

### 7.2 Operator runbook

- Runbook path: `docs/proxy-risk-mitigation.md`

Runbook includes:

- preconditions,
- dry-run flow,
- execute flow,
- post-execution validation checks.

## 8. Reviewer Verification Procedure

A third-party reviewer can validate risk reduction by checking:

1. ANX proxy address continuity (unchanged token address).
2. `DEFAULT_ADMIN_ROLE` holder is multisig.
3. `UPGRADER_ROLE` holder is multisig.
4. prior EOA no longer holds those roles.
5. proxy and implementation contracts are source-verified.
6. role-migration transactions are publicly visible and consistent with stated sequence.

## 9. Evidence Checklist

Provide links for each item before submission:

1. ANX proxy contract page (BscScan): `https://bscscan.com/address/0xc3ab9c26bc44776f3fc770afd90a27cfb826965c`
2. ANX implementation contract page (BscScan): `https://bscscan.com/address/0x99f152f899ae95a99f0d5cd21fd9786633198b76`
3. Admin multisig page (BscScan and/or Safe): `https://bscscan.com/address/0x9A7059CcFC3d36E32bceF9a1eaca80f22f6fb857` and `https://app.safe.global/transactions/queue?safe=bnb:0x9A7059CcFC3d36E32bceF9a1eaca80f22f6fb857`
4. Role migration transaction(s): `https://app.safe.global/transactions/queue?safe=bnb:0x9A7059CcFC3d36E32bceF9a1eaca80f22f6fb857`
5. Governance/process runbook: `https://github.com/1ofdafew/auronex/blob/main/docs/proxy-risk-mitigation.md`
6. Security review or audit report: `https://github.com/1ofdafew/auronex/blob/main/apps/anx-contracts/SECURITY.md`
7. Public risk/trust disclosure page: `https://github.com/1ofdafew/auronex/blob/main/docs/anx-risk-reclassification-packet.md`

## 10. Platform Submission Statement (Canonical)

ANX uses an upgradeable architecture with governance hardening controls. Upgrade/admin rights are handled through multisig governance instead of single-key authority. Contract verification and role migration actions are publicly auditable. The ANX proxy address remains unchanged, and no holder migration is required. We request reclassification based on current control architecture and verifiable governance evidence.

## 11. Why Upgradeable Does Not Automatically Mean Malicious

Upgradeability is a technical mechanism. Risk level depends on governance safeguards, not on mechanism presence alone. A transparent, multisig-governed, auditable upgrade path with constrained privileges is materially different from single-key or opaque upgrade control.

## 12. Residual Risk Disclosure

No governance system has zero risk. Residual risks include:

- multisig signer compromise risk,
- process failure risk,
- monitoring/response lag risk.

Mitigation posture:

- signer operational security,
- explicit change-management procedure,
- role minimization and continuous verification,
- public auditability of privileged actions.

## 13. Planned Hardening Roadmap

1. Add formal timelock enforcement (24-72h) for upgrade path.
2. Continue least-privilege role tightening.
3. Expand public attestation artifacts (automated role snapshots / governance dashboards).
4. Periodic external security review of governance and upgrade workflows.

## 14. Contact and Disclosure

- Project: Auronex
- Security contact: `hello@auronex.app`
- Technical contact: `hello@auronex.app`
- Disclosure channel: `https://github.com/1ofdafew/auronex/issues`

## 15. Appendix A: Script and Test Artifacts

- `apps/anx-contracts/scripts/propose-proxy-risk-mitigation.ts`
- `apps/anx-contracts/scripts/propose-proxy-risk-mitigation.test.ts`
- `apps/anx-contracts/test/ScriptCoverage.ts`
- `docs/proxy-risk-mitigation.md`

## 16. Appendix B: Address Continuity Note

The ANX token contract that users interact with is the proxy address. Governance hardening changes role holders and control paths, not the token proxy address itself.
