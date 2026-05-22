# Changelog

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
