# Skills

Quick-reference facts that an AI agent working on this repo should keep loaded.

## Architecture Facts

- One contract: `JBReferralSplitHook`. Implements `IJBSplitHook`. Single token (the fee project's project token).
- Inputs: reserved-token splits from the fee project. Volume oracle from `JBTerminalStore`. Token lookup from `JBTokens`.
- Output: per-referrer `fund(...)` calls into a configured `IJBDistributor` (typically `JBTokenDistributor` for IVotes).
- Constructor-set immutables: `TERMINAL`, `STORE`, `DIRECTORY`, `TOKENS`, `DISTRIBUTOR`, `FEE_PROJECT_ID`.

## Key Methods

- `processSplitWith(JBSplitHookContext)` — auth-gated on `DIRECTORY.controllerOf(FEE_PROJECT_ID)`. Pulls `context.amount` via `safeTransferFrom`. Bumps `totalDeposited`.
- `pushTo(uint256 referralProjectId) external returns (uint256 pushed)` — permissionless. Computes `entitled = mulDiv(totalDeposited, refVol, totalVol)`. Forwards `entitled - pushedOf[refId]` to the distributor. Skips if referrer has no token.

## Gotchas

- `pushedOf[refId]` is a high-water mark, not a snapshot. Pro-rata math is not coherent across late-arriving referrers — see `RISKS.md`.
- The hook reads `STORE.feeVolumeByReferralOf(TERMINAL, refId)`. If multiple terminals exist, each needs its own hook instance.
- `pushTo(0)` and `pushTo(FEE_PROJECT_ID)` revert.
- Credit-only referrers (no `IJBToken`) cause `pushTo` to no-op silently — their share stays pending.
- Fee-on-transfer tokens on the deposit path are unsupported (we trust `context.amount`, not balance delta).

## Common Tasks

- "Wire a new fee project terminal": deploy a new hook instance with the new terminal address.
- "Pause distributions": fee project owner queues a ruleset omitting this hook from reserved splits. Existing balances remain claimable.
- "Diagnose a stuck referrer": check `TOKENS.tokenOf(refId)` — `address(0)` means they need to issue an ERC-20.

## Integration Points

- Upstream: `nana-core-v6` (volume ledger).
- Downstream: `nana-distributor-v6` (vesting + claim).
- Sibling: any IJBSplitHook receiver on the fee project's reserved splits (e.g., `JBTokenDistributor` directly, for non-referral carve-outs).

## What This Repo Does NOT Do

- Record fee volume — that's `JBTerminalStore`.
- Vest tokens — that's `JBTokenDistributor`.
- Decide referrer eligibility — anyone with a non-zero `feeVolumeByReferralOf` is eligible.
- Compute per-referrer Merkle proofs — pure on-chain pro-rata. A v2 Merkle variant is hypothetical.
