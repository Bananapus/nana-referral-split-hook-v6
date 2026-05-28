# Skills

Quick-reference facts that an AI agent working on this repo should keep loaded.

## Architecture Facts

- One contract: `JBReferralSplitHook`. Implements `IJBSplitHook` and `IJBReferralSplitHook`. Single token (the fee project's project token).
- Inputs: reserved-token splits from the fee project. Volume oracle from `JBTerminalStore`. Token lookup from `JBTokens`. Bridge plumbing from `JBSuckerRegistry` + `JBSucker`.
- Output: per-referrer `fund(...)` calls into a configured `IJBDistributor` (typically `JBTokenDistributor` for IVotes), `sucker.prepare` calls for cross-chain bridge legs, or `JBController.burnTokensOf` for unbridgeable / no-twin paths.
- Constructor-set immutables: `DIRECTORY`, `STORE`, `TOKENS`, `DISTRIBUTOR`, `SUCKER_REGISTRY`, `TERMINAL`, `FEE_PROJECT_ID`.

## Key Methods

- `processSplitWith(JBSplitHookContext)` — auth-gated on `DIRECTORY.controllerOf(FEE_PROJECT_ID)`. Pulls `context.amount` via `safeTransferFrom`. Bumps `totalDeposited`.
- `pushTo(uint256 referralChainId, uint256 referralProjectId) returns (uint256 pushed)` — permissionless. Same-chain settlement. Skips on cross-chain input, no volume, caught up, or no IVotes ERC-20 (HWM rolled back — deferral).
- `bridgeRemote(uint256 referralChainId, uint256 referralProjectId, IJBSucker sucker, address terminalToken, uint256 minTokensReclaimed) returns (uint256 bridged)` — permissionless. Cross-chain outbound. Requires registered + ENABLED sucker whose `peerChainId() == referralChainId`. Writes leaf metadata `packLeafMetadata(block.chainid, referralProjectId)`.
- `claimAndPush(uint256 originChainId, uint256 referralProjectId, IJBSucker sucker, JBClaim claimData) returns (uint256 pushed)` — permissionless. Cross-chain inbound. Authenticates the leaf via `sucker.executedLeafHashOf` (front-run defense) or measures balance delta on normal `sucker.claim` path. Burns on missing local twin.
- `burnUnbridgeableCreditFor(uint256 referralChainId, uint256 referralProjectId) returns (uint256 burned)` — permissionless. Iterates `SUCKER_REGISTRY.allSuckersOf(FEE_PROJECT_ID)` (DEPRECATED included); reverts `SuckerExistsForChain` if any peers to `referralChainId`. Otherwise advances `bridgedOutOf` (shared HWM with `bridgeRemote`) and burns via `JBController.burnTokensOf`.

## Storage

- `totalDeposited` — cumulative `processSplitWith` deposits, monotonic.
- `pushedLocallyOf[refProjectId]` — same-chain HWM, monotonic.
- `bridgedOutOf[chainId][refProjectId]` — cross-chain HWM, UNIFIED across `bridgeRemote` AND `burnUnbridgeableCreditFor` (no separate `burnedOf` slot). Monotonic.
- `settledLeafOf[sucker][token][index]` — per-leaf single-settlement flag for `claimAndPush`, set AFTER any external call.

## Gotchas

- `pushedLocallyOf` / `bridgedOutOf` are high-water marks, not snapshots. Pro-rata math is not coherent across late-arriving referrers — see `RISKS.md` § 2.
- The hook reads `STORE.feeVolumeByReferralOf(TERMINAL, chainId, refId)`. If multiple terminals exist, each needs its own hook instance.
- `referralProjectId == 0` or `== FEE_PROJECT_ID` reverts on every settle-side entrypoint.
- `referralChainId == 0` reverts on `bridgeRemote`, `claimAndPush`, and `burnUnbridgeableCreditFor` (`ZeroChainId`).
- Credit-only referrers (no `IJBToken`) cause `pushTo` to roll back the HWM and emit `Skipped("no token")` — their share stays pending until they tokenize.
- Fee-on-transfer tokens on the deposit path are unsupported (we trust `context.amount`, not balance delta).
- CREATE2 same-address-across-chains is load-bearing: `claimAndPush` checks `leaf.beneficiary == address(this)`.
- Suckers need `MINT_TOKENS` permission on the fee project for `claimAndPush` to settle — the registry's `deploySuckersFor` does NOT grant this.
- `burnUnbridgeableCreditFor` iterates `allSuckersOf` (including DEPRECATED), not `suckersOf` — deprecated suckers still settle pending inbound claims, so credit routed through them is bridgeable.

## Design Contract: Burn-vs-Defer-vs-Revert

| Scenario | Policy |
| --- | --- |
| `pushTo` same-chain, no ERC-20 | DEFER (roll back HWM, recoverable when project tokenizes) |
| `bridgeRemote`, no sucker for chain | REVERT (caller should use `burnUnbridgeableCreditFor` instead) |
| `bridgeRemote`, deprecated sucker | REVERT (`SuckerNotEnabled`) |
| `burnUnbridgeableCreditFor`, sucker exists | REVERT (`SuckerExistsForChain` — grief prevention) |
| `burnUnbridgeableCreditFor`, no sucker | BURN |
| `claimAndPush`, missing local twin | BURN (leaf already consumed, no recipient) |
| Any malformed args | REVERT |

PR Bananapus/nana-referral-split-hook-v6#11 ("park-and-retry / `pokeDeferredClaim`") was CLOSED. Burn-on-strand is the official design — there is no `pokeDeferredClaim`, no `parkedOf`, no `tryReclaimFromBurn` entrypoint. See the `jb-referral-hook-deferral-vs-stranding` skill for the codified design contract.

## Front-Run Defense

`sucker.claim` is permissionless. `claimAndPush` defends by querying `sucker.executedLeafHashOf(token, index)`; if non-zero, the leaf was already executed and the hook re-derives `keccak256(abi.encodePacked(projectTokenCount, terminalTokenAmount, beneficiary, metadata))` to authenticate the caller's `claimData`. See `RISKS.md` Section 8 and the `jb-sucker-claim-front-run-defense` skill.

## Common Tasks

- "Wire a new fee project terminal": deploy a new hook instance with the new terminal address (`TERMINAL` is immutable).
- "Pause distributions": fee project owner queues a ruleset omitting this hook from reserved splits. Existing balances remain claimable.
- "Diagnose a stuck same-chain referrer": check `TOKENS.tokenOf(refId)` — `address(0)` means they need to issue an ERC-20.
- "Diagnose a stuck cross-chain claim": check `SUCKER_REGISTRY.isSuckerOf(FEE_PROJECT_ID, sucker)`, `sucker.state()`, `sucker.peerChainId()`, and the sucker's `MINT_TOKENS` permission on the fee project.

## Integration Points

- Upstream: `nana-core-v6` (volume ledger, controller, terminal store).
- Downstream: `nana-distributor-v6` (vesting + claim).
- Sibling: `nana-suckers-v6` (bridge plumbing — registry + per-bridge suckers).

## What This Repo Does NOT Do

- Record fee volume — that's `JBTerminalStore`.
- Vest tokens — that's `JBTokenDistributor`.
- Decide referrer eligibility — anyone with a non-zero `feeVolumeByReferralOf` is eligible.
- Deploy or configure suckers — that's `JBSuckerRegistry` (operator-driven).
- Compute per-referrer Merkle proofs — pure on-chain pro-rata.
