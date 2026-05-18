# Audit Instructions

## Scope

In scope:

- `src/JBReferralSplitHook.sol`
- `src/interfaces/IJBReferralSplitHook.sol`

Out of scope (covered by their own repos):

- `JBTerminalStore` volume-ledger correctness — `nana-core-v6` PR 148.
- `JBTokenDistributor` vesting and claim mechanics — `nana-distributor-v6`.
- `JBController.sendReservedTokensToSplitsOf` and the split-hook invocation pipeline — `nana-core-v6`.

## Key Properties To Verify

1. **Auth gate**: `processSplitWith` reverts unless `msg.sender == DIRECTORY.controllerOf(FEE_PROJECT_ID)` and `context.projectId == FEE_PROJECT_ID`.
2. **Token gate**: `processSplitWith` reverts unless `context.token == address(TOKENS.tokenOf(FEE_PROJECT_ID))`.
3. **Pull semantics**: `processSplitWith` pulls exactly `context.amount` via `safeTransferFrom` and credits `totalDeposited` by the same value.
4. **Pro-rata math**: in `pushTo`, `entitled == mulDiv(totalDeposited, refVol, totalVol)`.
5. **High-water-mark monotonicity**: `pushedOf[refId]` is non-decreasing across all reachable execution paths.
6. **Push amount**: forwarded amount equals `entitled - pushedOf[refId]` when positive; otherwise the call is a no-op.
7. **Distributor approval**: `forceApprove(DISTRIBUTOR, pushed)` is granted only for the exact `pushed` amount and consumed by the immediately-following `fund` call.
8. **No-token fallback**: when `TOKENS.tokenOf(referralProjectId)` returns the zero address, `pushTo` is a no-op (no state change, no token movement).
9. **Self-reference**: `pushTo(0)` and `pushTo(FEE_PROJECT_ID)` revert.
10. **Reentrancy**: state writes in `processSplitWith` and `pushTo` happen before external calls; reentrancy via the distributor or token cannot double-spend.

## Adversarial Scenarios To Consider

- Malicious referring project token whose `transferFrom` (called by the distributor) reverts or returns false. Behavior: the `fund` call reverts, the `pushTo` reverts, `pushedOf` is rolled back. Verify the rollback.
- Referrer with a tier-shifted IVotes implementation that returns inflated voting power. Out of scope — distributor's problem.
- Caller spoofing `JBDirectory` to bypass the auth check. Out of scope — directory trust is a system-level assumption.
- Frontend passing `referralProjectId = type(uint48).max`. The fee record in `nana-core-v6` uses `uint48`, so this is the max representable. Verify no overflow or weirdness in the pro-rata math.

## Reference Reading

- `nana-core-v6/src/JBMultiTerminal.sol` — fee-paying entry points and the transient referral slot.
- `nana-core-v6/src/JBTerminalStore.sol` — `feeVolumeByReferralOf`, `totalFeeVolumeOf`, `recordPaymentFrom` auto-credit.
- `nana-distributor-v6/src/JBDistributor.sol` — `fund(address, IERC20, uint256)`.
- `nana-distributor-v6/src/JBTokenDistributor.sol` — the IVotes-keyed concrete distributor most likely to be wired here.
