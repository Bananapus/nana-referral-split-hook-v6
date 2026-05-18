# Risks

Single-purpose router. The hook owns very little state, but the system around it has assumptions worth surfacing.

## Runtime Risks

### Late-entrant share skew

`entitled = totalDeposited * refVolume / totalFeeVolume` is computed at push time, not at deposit time. If a new referrer drives a large share of volume **after** an earlier referrer has pushed, the earlier referrer's `entitled` can drop below `pushedOf`. The hook clamps at zero (no claw-back), and the residual tokens stay in the hook permanently — they are not redistributed.

**Severity**: low. Only matters when referrer composition shifts dramatically and volume distributions are imbalanced. Mitigation is an upstream Merkle-snapshot model (deferred).

### Volume-oracle drift

The hook trusts `JBTerminalStore.feeVolumeByReferralOf[TERMINAL][refId]` and `totalFeeVolumeOf[TERMINAL]` as the volume ledger. If `nana-core-v6` ever introduces a write path that updates one without the other, pro-rata math breaks.

**Severity**: medium. Surface to watch when reviewing `nana-core-v6` PRs that touch the volume ledger.

### Single-terminal attribution

The hook is bound to a single `TERMINAL` address. Fee volume that flows through any other terminal is invisible to it. Multi-terminal deployments require either multiple hook instances or a future multi-terminal-aware variant.

**Severity**: low for current deployment (single canonical fee terminal). Operationally critical if that changes.

### Credit-only referrers cannot claim

If a referring project has only issued credits (no `IJBToken` ERC-20), `pushTo(referralProjectId)` is a no-op. Their share stays pending in the hook indefinitely; it becomes claimable retroactively if/when the project tokenizes.

**Severity**: design. Documented behavior, not a bug.

## Admin Risks

### Constructor-set immutables

`TERMINAL`, `STORE`, `DIRECTORY`, `TOKENS`, `DISTRIBUTOR`, and `FEE_PROJECT_ID` are constructor-set immutables. A misconfigured constructor produces a permanently-broken hook; redeployment is the only fix.

### No pause / no owner

The hook has no admin and no upgrade path. This is intentional — once wired into the fee project's splits, it should behave deterministically. If the system needs to be stopped, the fee project's owner removes it from the splits in the next ruleset.

## Deployment Risks

- The hook depends on a deployed `JBTokenDistributor` instance. The deploy script reads its address from env; double-check before broadcasting.
- The hook must be referenced as a split with the correct `groupId == 1` (reserved tokens). A misconfigured split (wrong groupId, wrong percentage) routes tokens incorrectly.

## Integration Risks

- `JBTokenDistributor.fund(hook, token, amount)` pulls via `transferFrom`. This hook calls `forceApprove(DISTRIBUTOR, pushed)` immediately before. If the distributor changes its pull semantics, the call site must be updated.
- The fee project's project token must be a standard ERC-20 (JBERC20 satisfies this). Fee-on-transfer tokens are not supported on the deposit path because `processSplitWith` records `context.amount`, not `balanceOf` delta.
