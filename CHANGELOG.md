# Changelog

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
