# Changelog

## 0.0.5

Park-and-retry deferred claim instead of burn-on-strand. When `claimAndPush` settles a leaf whose local twin has no `IJBToken` yet, the freshly-minted fee-project tokens are now PARKED in the hook keyed by `(sucker, terminalToken, leafIndex)` instead of being burned. Anyone can later call `pokeDeferredClaim(sucker, terminalToken, leafIndex)` to release the parked amount to the local distributor once the referrer tokenizes via `JBController.deployERC20For`.

### Behavior changes

- **`claimAndPush` now parks on missing local twin instead of burning.** Previously the freshly-minted fee-project tokens were burned (D6 in `EFFICIENCY_LESSONS.md`); the leaf bitmap was already set, so the referrer's credit was lost forever even if they later tokenized. The new behavior preserves the credit indefinitely by parking it under a leaf-identity key.

### New storage

- `mapping(bytes32 strandedKey => uint256 amount) parkedAmountOf` — keyed by `keccak256(abi.encode(sucker, terminalToken, leafIndex))`.
- `mapping(bytes32 strandedKey => uint256 referralProjectId) parkedReferralProjectIdOf` — mirrors `parkedAmountOf` so the poker can re-derive the destination without trusting calldata.

### New entrypoints

- **`pokeDeferredClaim(sucker, terminalToken, leafIndex) → pushed`** — permissionless. Looks up the parked amount, re-derives the referral project from storage, resolves the referrer's `IJBToken`, and funds the local distributor. Clears the park BEFORE the external call.

### New errors

- `JBReferralSplitHook_NothingParked(strandedKey)` — nothing parked at the supplied key (never parked, or already poked).
- `JBReferralSplitHook_StillStranded(referralProjectId)` — referrer still has no `IJBToken`; the park stays put.

### New events

- `ParkedOnStrand(originChainId, referralProjectId, sucker, terminalToken, leafIndex, feeProjectParked, caller)` — emitted by `claimAndPush` when the local twin has no `IJBToken`.
- `PokedDeferredClaim(strandedKey, referralProjectId, amount, caller)` — emitted on successful deferred release.

### Deprecations

- `BurnedOnStrand` event is no longer emitted by `claimAndPush`. Retained in the interface ABI for one major release so historical event logs remain decodable.

### Trade-off

- No permissionless burn-after-N-days escape hatch. If the referrer never tokenizes, the parked amount sits indefinitely (recoverable; not stranded). A governance-gated sweep can be added later if long-stale parks need cleanup — deliberately not adding a permissionless burn-timer here to avoid re-introducing the brittleness this fix removes. See `RISKS.md` § 7.3.

## 0.0.4

Cross-chain settlement, burn-over-strand policy, defense-in-depth validation. Breaking ABI (new entrypoints, new errors, new events; rewritten `claimAndPush` semantics on the missing-twin path).

### New entrypoints

- **`burnUnbridgeableCreditFor(referralChainId, referralProjectId)`** — permissionless burn for cross-chain referral credits on chains with no sucker pair. Iterates `SUCKER_REGISTRY.suckersOf(FEE_PROJECT_ID)` and reverts with `JBReferralSplitHook_SuckerExistsForChain` if any registered sucker peers to `referralChainId` (preventing grief against bridgeable referrers). Otherwise advances `bridgedOutOf` (shared HWM with `bridgeRemote`) and burns the entitled fee-project tokens via `JBController.burnTokensOf`. The bridged terminal-token value already in the fee project's balance accrues pro-rata to existing fee-token holders.

### Behavior changes

- **`claimAndPush` now burns on missing local twin instead of stranding.** When `TOKENS.tokenOf(referralProjectId) == 0` on the destination chain, the freshly-minted fee-project tokens from `sucker.claim` are burned via `JBController.burnTokensOf`. Previously they sat in the hook's balance forever (the leaf is single-use, so they could never be forwarded). The bridged terminal-token value still lands in the fee project's balance — burning the offsetting supply turns it into pro-rata surplus for existing fee-token holders.

### Defense-in-depth

- **`bridgeRemote` and `claimAndPush` reject `chainId == 0`** with `JBReferralSplitHook_ZeroChainId`. EIP-155 chain IDs are strictly positive; downstream sucker checks would catch this anyway, but failing here gives a clearer error and removes load-bearing dependence on downstream behavior.

### New errors

- `JBReferralSplitHook_ZeroChainId` — emitted when `chainId == 0` is passed to `bridgeRemote`, `claimAndPush`, or `burnUnbridgeableCreditFor`.
- `JBReferralSplitHook_SuckerExistsForChain(sucker, chainId)` — emitted when `burnUnbridgeableCreditFor` is called for a chain that has a registered sucker (use `bridgeRemote` instead).

### New events

- `BurnedOnStrand(originChainId, referralProjectId, feeProjectBurned)` — emitted by `claimAndPush` when the local twin's IJBToken doesn't exist and the freshly-minted fee-project tokens are burned.
- `BurnedUnbridgeable(referralChainId, referralProjectId, amount)` — emitted by `burnUnbridgeableCreditFor` when an unbridgeable credit is burned.

### Design rule (the burn-over-strand matrix)

| Scenario | Policy |
| --- | --- |
| `pushTo` same-chain, no ERC-20 | Defer (roll back HWM, recoverable when project tokenizes) |
| `bridgeRemote`, no sucker for chain | Revert (caller error or wrong-chain assertion); caller should use `burnUnbridgeableCreditFor` |
| `burnUnbridgeableCreditFor`, sucker exists | Revert (grief prevention) |
| `burnUnbridgeableCreditFor`, no sucker | Burn |
| `claimAndPush`, missing local twin | Burn (leaf already consumed, no recipient) |
| Any malformed args | Revert |

### Imports

- Adds `IJBController` import for `burnTokensOf`. `holder == msg.sender == hook` makes the burn self-authorized; no `BURN_TOKENS` permission grant is needed.

### Tests

The cross-chain end-to-end test suite (in `deploy-all-v6/test/fork/ReferralRewardCrossChainFork.t.sol`) grew from 19 to 28 tests, including the new burn paths (`test_claimAndPush_localTwinHasNoToken_burnsToFeeProjectSurplus`, `test_unbridgeableChain_burnsUnbridgeableCredit`, `test_burnUnbridgeable_revertsWhenSuckerExists`, `test_burnUnbridgeable_thenLaterSuckerDeployment_bridgesIncrementalOnly`), USDC mixed-currency tests (`test_usdc_sameChain_endToEnd`, `test_usdc_mixedCurrency_volumeLedgerStaysCoherent`), and chainId=0 input-validation tests. Hook's own unit tests (16) unchanged.

## 0.0.3

Storage and naming clarifications. Breaking ABI.

### Storage

- **`pushedOf` split into two semantically distinct mappings**:
  - `pushedLocallyOf(uint256 localReferralProjectId)` — high-water mark for same-chain pushes to the local distributor.
  - `bridgedOutOf(uint256 referralChainId, uint256 referralProjectId)` — high-water mark for outbound bridges.
  The previous single nested mapping was reused for both meanings; off-chain indexers had to disambiguate by checking whether the chainId key equalled `block.chainid`. The two are now clearly separate slots.

### Documentation

- **Cross-chain projectId convention spelled out at the interface natspec.** `referralProjectId` everywhere in this hook — and in the source-side `JBTerminalStore.feeVolumeByReferralOf` ledger — refers to the projectId on the referrer's home chain (`referralChainId`), never the source chain. Projectid spaces are per-chain; the hook never assumes numeric equivalence across chains. Callers tagging a cross-chain referrer must pass the referrer's projectId on the referrer's chain.

### Internal

- `_consumePendingFor` renamed to `_pendingDeltaFor` and no longer writes to storage. Callers pass `alreadyProcessed` and write back to their own slot (`pushedLocallyOf` or `bridgedOutOf`). This decoupling is what lets the same math drive both ledgers without conflating them.

## 0.0.2

Production hardening for the cross-chain bridge path. No on-chain deployments yet, so changes are breaking-permissible.

### Bug fixes

- **`claimAndPush` now measures the right token.** `JBSucker._handleClaim` deposits the bridged *terminal* tokens into the destination fee project's primary terminal and mints destination *fee-project* tokens to the beneficiary. The previous implementation snapshotted terminal-token balance (always 0 for the hook) and then attempted a second `feeTerminal.pay(0)` — silently no-op'd every claim. Now the hook snapshots its fee-project-token balance around `sucker.claim` and forwards the delta to the distributor.

### Security

- **Sucker peer-chain validation.** `bridgeRemote` now reads `sucker.peerChainId()` and reverts with `JBReferralSplitHook_SuckerPeerMismatch` when the registered sucker bridges to a chain other than `referralChainId`. Previously a caller could route a referrer's credit through any registered fee-project sucker, mis-routing it to the wrong omnichain leg.
- **Local-origin rejection in `claimAndPush`.** Explicit revert with `JBReferralSplitHook_OriginIsLocal` when `originChainId == block.chainid`. Prevents a hand-crafted "local" leaf from sneaking through the cross-chain path and bypassing same-chain `pushTo` high-water-mark accounting.
- **`packLeafMetadata` bounds.** Reverts with `JBReferralSplitHook_ChainIdTooLarge` when `originChainId > type(uint32).max` and `JBReferralSplitHook_ReferralProjectIdTooLarge` when `referralProjectId > type(uint64).max`, eliminating the silent-overflow risk in the leaf-metadata encoding.

### API

- **Split error semantics.** `JBReferralSplitHook_LeafBeneficiaryMismatch` is now used exclusively for beneficiary mismatches; metadata mismatches surface `JBReferralSplitHook_LeafMetadataMismatch`.
- **`receive() external payable` removed.** With the `claimAndPush` rewrite the hook never expects a native inflow (the sucker pays the fee project's terminal, not the hook). Closing the receive surface removes the balance-inflation footgun.
- **Unused imports/helpers dropped** (`IJBTerminal`, `JBConstants`, `_balanceOf`) along with the now-irrelevant `JBReferralSplitHook_NoFeeTerminal` error.

### Tests

16 unit tests passing, covering: construction, ERC-165 advertising, `pushTo` invalid-arg + remote-skip + no-volume paths, `bridgeRemote` invalid-arg + same-chain + unregistered-sucker + new peer-mismatch path, `claimAndPush` unregistered-sucker + metadata-mismatch + new local-origin path, `packLeafMetadata` round-trip + new overflow guards.

## 0.0.1

Initial scaffold of `JBReferralSplitHook`.

### Features

- **JBReferralSplitHook**: `IJBSplitHook` receiver for the fee project's reserved-token splits. Pools deposited fee-project tokens and forwards per-referrer pro-rata shares to a configured `IJBDistributor`.
- Permissionless `pushTo(referralProjectId)` for forwarding individual referrers' accrued shares.
- High-water-mark accounting via `pushedOf[referralProjectId]`.
- ERC-165 support advertising `IJBSplitHook`.

### Dependency Notes

- Requires `@bananapus/core-v6` with `IJBTerminalStore.totalFeeVolumeOf` and `IJBTerminalStore.feeVolumeByReferralOf` — pending the release of [`nana-core-v6` PR 148](https://github.com/Bananapus/nana-core-v6/pull/148). Until then, `forge build` will fail with `Member "totalFeeVolumeOf" not found` against the currently published `0.0.54`. Bump the `@bananapus/core-v6` dep in `package.json` once that PR's published version is available.

### Known Limitations

- Pro-rata math is high-water-mark, not snapshot-coherent. See `RISKS.md` for late-entrant skew.
- Single-terminal binding via constructor-set `TERMINAL`. Multi-terminal deployments require multiple hook instances.
- Credit-only referrers (no `IJBToken`) cause `pushTo` to no-op until they tokenize.
