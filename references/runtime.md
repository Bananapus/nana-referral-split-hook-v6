# Runtime Reference

Quick lookup for off-chain consumers (indexers, frontends, keepers) integrating against this hook.

## Events

### `Deposit(uint256 amount, uint256 newTotalDeposited)`

Emitted on every `processSplitWith` invocation when the fee project distributes reserved tokens through this hook.

- `amount` — tokens received in this call.
- `newTotalDeposited` — cumulative deposits after this call. Equals `hook.totalDeposited()` read in the same block.

### `Push(uint256 indexed referralProjectId, address indexed referralToken, uint256 amount)`

Emitted when a referrer's accrued share is forwarded into the distributor. Indexed by both the project ID and the resolved token address — handy for filtering by either.

### `Skipped(uint256 indexed referralProjectId, bytes32 reason)`

Emitted when `pushTo` no-ops. Reason codes:

- `"no volume"` — `feeVolumeByReferralOf` or `totalFeeVolumeOf` is zero.
- `"caught up"` — `pushedOf >= entitled`.
- `"no token"` — referring project has no `IJBToken`.

## Driving Pushes From An Indexer

1. Subscribe to `JBTerminalStore.ReferralCredit(address indexed terminal, uint256 indexed referralProjectId, uint256 amount, uint256 newTotal)` events from the configured `TERMINAL`.
2. Maintain a set of referring project IDs that have non-zero `feeVolumeByReferralOf`.
3. Subscribe to `JBController.SendReservedTokensToSplits` events for `FEE_PROJECT_ID`.
4. After each reserved-tokens distribution, call `hook.pushTo(referralProjectId)` for each known referrer. Filter out:
   - referrers whose project has no `IJBToken`
   - referrers whose `pushedOf` already matches `entitled`

## Computing A Referrer's Pending Push Off-Chain

```javascript
const totalDeposited = await hook.totalDeposited();
const totalVol = await store.totalFeeVolumeOf(terminal);
const refVol = await store.feeVolumeByReferralOf(terminal, referralProjectId);
const entitled = (totalDeposited * refVol) / totalVol;
const pushed = await hook.pushedOf(referralProjectId);
const pending = entitled > pushed ? entitled - pushed : 0n;
```

## Reading Per-Referrer Vesting Status

After a `Push`, the distributor's per-`(hook, token)` pool grows by `amount`. The referring project's IVotes holders can then call the distributor's claim path (see `nana-distributor-v6/references/runtime.md`).
