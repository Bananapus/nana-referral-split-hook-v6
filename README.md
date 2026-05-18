# Juicebox Referral Split Hook

`@bananapus/referral-split-hook-v6` is a split hook that routes the fee project's reserved-token pool to referring projects' IVotes holders, in proportion to attributed fee volume.

Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md)
User journeys: [USER_JOURNEYS.md](./USER_JOURNEYS.md)
Skills: [SKILLS.md](./SKILLS.md)
Risks: [RISKS.md](./RISKS.md)
Administration: [ADMINISTRATION.md](./ADMINISTRATION.md)
Audit instructions: [AUDIT_INSTRUCTIONS.md](./AUDIT_INSTRUCTIONS.md)

## Overview

When a project pays a protocol fee, the caller can attribute that fee to a **referral project** via `JBMultiTerminal.{cashOutTokensOf, sendPayoutsOf, useAllowanceOf}(..., referralProjectId)`. `JBTerminalStore` records the per-terminal, per-referrer fee volume in `feeVolumeByReferralOf` and a denominator in `totalFeeVolumeOf`.

This repo wires that volume ledger into the fee project's reserved-token split distribution:

1. The fee project lists `JBReferralSplitHook` as one of its reserved-token splits.
2. When the fee project calls `sendReservedTokensToSplitsOf`, the hook receives its allocation of project tokens and books them into `totalDeposited`.
3. Anyone can call `JBReferralSplitHook.pushTo(referralProjectId)` to forward that referrer's pro-rata share into `JBTokenDistributor.fund(...)`, keyed to the referring project's IVotes token.
4. Holders of the referring project's token claim the pro-rata stream over the configured vesting rounds.

The hook never custodies value beyond the brief window between receipt and forwarding, and it never decides who is a "valid" referrer — it just resolves the volume ratio published by `JBTerminalStore` and forwards.

## Mental Model

1. fees attribute to referrers as they happen — recorded in `JBTerminalStore`
2. reserved tokens accumulate on the fee project and periodically distribute via splits
3. one of those splits is this hook — it pools the tokens
4. a permissionless `pushTo` call hands a referrer's share to `JBTokenDistributor`
5. the referring project's IVotes holders claim from the distributor on the next round

Use this repo when the problem is "distribute fee-project tokens to referrers' holders". Do not use it for the upstream volume attribution (that lives in `nana-core-v6` PR 148) or for the actual vesting/claim mechanics (that lives in `nana-distributor-v6`).

## Key Contracts

| Contract | Role |
| --- | --- |
| `JBReferralSplitHook` | `IJBSplitHook` receiver for the fee project's reserved-token splits. Pools deposits and forwards per-referrer shares to `JBTokenDistributor`. |

## Read These Files First

1. `src/interfaces/IJBReferralSplitHook.sol`
2. `src/JBReferralSplitHook.sol`
3. `test/JBReferralSplitHook.t.sol`

## Integration Traps

- The hook depends on `JBTerminalStore.totalFeeVolumeOf` and `feeVolumeByReferralOf`, both keyed by the **terminal that originated the fee-paying call**. If your deployment uses multiple `JBMultiTerminal` instances, you need one hook (or a multi-terminal-aware variant) per terminal you want to attribute through.
- Referring projects without an issued `IJBToken` (credit-only projects) cannot receive a push — their share stays pending in the hook until they tokenize.
- The pro-rata math is monotonic-but-not-snapshot-coherent. If a late-arriving referrer drives volume after early referrers have pushed, the early pushers' `entitled` can drop below `pushedOf`. The hook clamps at zero; the residual stays unredistributable. See `RISKS.md`.
- The hook is single-token (the fee project's project token). It assumes a JBERC20-shape token (or any ERC-20 supporting `approve`).

## Where State Lives

- per-referrer cumulative pushed: `pushedOf`
- cumulative deposits received: `totalDeposited`
- volume ledger: read-only, from `JBTerminalStore` in `nana-core-v6`
- vesting state: lives in `JBTokenDistributor` in `nana-distributor-v6` once `pushTo` forwards

## High-Signal Tests

1. `test/JBReferralSplitHook.t.sol`

## Install

```bash
npm install @bananapus/referral-split-hook-v6
```

> ⚠️ This repo requires `@bananapus/core-v6` with the volume ledger introduced in [PR 148](https://github.com/Bananapus/nana-core-v6/pull/148) (`totalFeeVolumeOf`, `feeVolumeByReferralOf`, `ReferralCredit`). Until that PR ships in a published `nana-core-v6` release, `forge build` will fail against the currently published `0.0.54`. Bump the `@bananapus/core-v6` dep in `package.json` once available.

## Development

```bash
npm install
forge build --deny notes
forge test --deny notes
```

Useful scripts:

- `npm run test:fork`
- `npm run deploy:mainnets`
- `npm run deploy:testnets`

## Repository Layout

```text
src/
  JBReferralSplitHook.sol
  interfaces/
    IJBReferralSplitHook.sol
test/
  JBReferralSplitHook.t.sol
script/
  Deploy.s.sol
```

## Risks And Notes

- the hook trusts `JBTerminalStore` as a volume oracle — any operational issue with the originating terminal's attribution shape (held-fee struct packing, cross-terminal staticcall fallback) flows through here
- `pushTo` is permissionless; expect frontends and keepers to call it regularly

## For AI Agents

- This repo is a thin router. Volume attribution lives upstream in `nana-core-v6`; vesting + claim lives downstream in `nana-distributor-v6`.
- If you find yourself adding accounting logic here, it likely belongs in one of those two repos instead.
