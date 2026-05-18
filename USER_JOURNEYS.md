# User Journeys

## Fee Project Owner: Wire The Hook Into Reserved Splits

1. Deploy `JBReferralSplitHook` (one per `TERMINAL` you want to attribute through).
2. Configure a new ruleset for the fee project whose reserved-token splits include this hook:
   - `groupId = 1` (reserved tokens)
   - `hook = address(JBReferralSplitHook)`
   - `percent` = the carve-out for the referral program (e.g., 30% of reserved tokens)
3. Queue the ruleset. Once it takes effect, every `sendReservedTokensToSplitsOf(FEE_PROJECT_ID)` call routes the carve-out into the hook.

## Frontend Operator: Drive Per-Referrer Pushes

1. Index `JBTerminalStore.ReferralCredit(terminal, refId, amount, newTotal)` events to identify active referrers.
2. After each `sendReservedTokensToSplitsOf` execution (observable via `JBController` events), call `JBReferralSplitHook.pushTo(refId)` for each known referrer.
3. The push is permissionless and pays its own gas. Most operators batch a few per transaction.

## Referring Project's Holder: Claim Vested Rewards

1. Wait for someone to call `pushTo(referralProjectId)` for your project (or call it yourself).
2. The push forwards your project's share into `JBTokenDistributor` keyed to your project's IVotes token.
3. On the next vesting round, your holdings are snapshotted via `IVotes.getPastVotes` and you can claim your pro-rata share via `JBTokenDistributor.collectVestedRewards(...)`.

## Referring Project Without An Issued Token

If you've referred fee-paying activity but your project has only credits (no ERC-20), `pushTo` will skip silently. Your share accumulates in `feeVolumeByReferralOf` and in this hook's `totalDeposited` pool. When you issue your project's ERC-20 (`JBController.deployERC20For(...)`), a subsequent `pushTo` will release your accumulated share at that point.

## Auditor / Indexer: Verify A Push

1. Read `JBTerminalStore.totalFeeVolumeOf(terminal)` and `JBTerminalStore.feeVolumeByReferralOf(terminal, refId)`.
2. Read `JBReferralSplitHook.totalDeposited()` and `JBReferralSplitHook.pushedOf(refId)`.
3. The next `pushTo(refId)` will move `mulDiv(totalDeposited, refVol, totalVol) - pushedOf[refId]` (clamped at 0) into the distributor.
