# Juicebox Referral Split Hook

`@bananapus/referral-split-hook-v6` is a split hook that routes the fee project's reserved-token pool to referring projects' IVotes holders, in proportion to attributed fee volume. Same-chain referrers are pushed to a local `JBTokenDistributor`; cross-chain referrers are bridged through the fee project's sucker and settled atomically on their home chain. Credit on chains with no sucker pair is burned to the fee-project surplus rather than left to dilute existing holders.

## Documentation

- [ARCHITECTURE.md](./ARCHITECTURE.md) — module-level dataflow including the cross-chain path
- [USER_JOURNEYS.md](./USER_JOURNEYS.md) — five end-to-end flows from real callers' perspectives
- [INVARIANTS.md](./INVARIANTS.md) — operational invariants enumerated per-contract
- [RISKS.md](./RISKS.md) — risk register and the burn-vs-defer-vs-revert design contract
- [ADMINISTRATION.md](./ADMINISTRATION.md) — control posture, roles, recovery
- [AUDIT_INSTRUCTIONS.md](./AUDIT_INSTRUCTIONS.md) — where to look, what must hold
- [SKILLS.md](./SKILLS.md) — quick-reference facts for AI agents working in this repo
- [STYLE_GUIDE.md](./STYLE_GUIDE.md) — repo-internal style ref
- [CHANGELOG.md](./CHANGELOG.md) — version history

## Overview

When a project pays a protocol fee, the caller can attribute that fee to a **referral project** via `JBMultiTerminal.{cashOutTokensOf, sendPayoutsOf, useAllowanceOf}(..., referralProjectId)`. The `referralProjectId` parameter is encoded as `(referralChainId << 48) | bareProjectId` so cross-chain referrers can be credited from any source chain. `JBTerminalStore` records the per-terminal, per-(chainId, projectId) fee volume in `feeVolumeByReferralOf` and a denominator in `totalFeeVolumeOf`, normalizing all amounts to NATIVE_TOKEN 18-decimal units so multi-currency fee projects mix correctly.

This repo wires that volume ledger into the fee project's reserved-token split distribution:

1. The fee project lists `JBReferralSplitHook` as one of its reserved-token splits.
2. When the fee project calls `sendReservedTokensToSplitsOf`, the hook receives its allocation of project tokens and books them into `totalDeposited`.
3. Routing depends on where the referrer lives:
   - **Same-chain referrer**: anyone calls `pushTo(localChainId, refId)` to forward the entitled delta into `JBTokenDistributor.fund(refToken, feeToken, amount)`.
   - **Cross-chain referrer with a sucker pair**: anyone calls `bridgeRemote(remoteChainId, refId, sucker, terminalToken)` to cash out the entitled fee-project tokens through the sucker. The destination-side hook (same CREATE2 address) settles via `claimAndPush(originChainId, refId, sucker, claimData)`, which mints fee-project tokens on the destination chain and forwards to the local distributor.
   - **Cross-chain referrer with NO sucker pair**: anyone calls `burnUnbridgeableCreditFor(remoteChainId, refId)` to burn the entitled fee-project tokens. The bridged terminal-token value (already in the fee project's balance from the original protocol-fee flow) accrues pro-rata to all existing fee-token holders.
4. Holders of the referring project's token claim their pro-rata stream over the distributor's configured vesting rounds.

The hook never custodies value beyond the brief window between receipt and forwarding. It never decides who is a "valid" referrer — it just resolves the volume ratio published by `JBTerminalStore` and routes.

## Mental Model

1. Fees attribute to referrers as they happen — recorded in `JBTerminalStore` keyed by `(terminal, chainId, projectId)`, normalized to NATIVE units.
2. Reserved tokens accumulate on the fee project and periodically distribute via splits.
3. One of those splits is this hook — it pools the tokens into `totalDeposited`.
4. A permissionless `pushTo` / `bridgeRemote` / `burnUnbridgeableCreditFor` call moves a referrer's pro-rata share to its destination — local distributor, remote sucker outbox, or burn.
5. Cross-chain bridges settle on the destination chain via `claimAndPush`, which either forwards to the destination's local distributor or burns to the destination fee-project's surplus.
6. The referring project's IVotes holders claim from the distributor on the next vesting round.

Use this repo when the problem is "distribute fee-project tokens to referrers' holders, including cross-chain". Do not use it for the upstream volume attribution (that lives in `nana-core-v6`) or for the actual vesting/claim mechanics (that lives in `nana-distributor-v6`).

## Key Contracts

| Contract | Role |
| --- | --- |
| `JBReferralSplitHook` | `IJBSplitHook` receiver for the fee project's reserved-token splits. Pools deposits, then routes per-referrer shares to (a) the local distributor, (b) the fee project's sucker outbox, or (c) the burn path. |

## Read These Files First

1. `src/interfaces/IJBReferralSplitHook.sol` — every entrypoint with full NatSpec
2. `src/JBReferralSplitHook.sol` — the contract
3. `test/JBReferralSplitHook.t.sol` — unit tests
4. `deploy-all-v6/test/fork/ReferralRewardCrossChainFork.t.sol` — full cross-chain E2E

## Integration Traps

- **`referralProjectId` is keyed to the referrer's HOME chain.** Across `pushTo`, `bridgeRemote`, `claimAndPush`, and `burnUnbridgeableCreditFor`, this field ALWAYS refers to the projectId on the referrer's home chain — never to a numerically-matching projectId on some other chain. Projectid spaces are per-chain; project `42` on Optimism is unrelated to project `42` on Base.
- **Suckers need `MINT_TOKENS` permission.** The `JBSuckerRegistry.deploySuckersFor` flow grants `DEPLOY_SUCKERS` and `MAP_SUCKER_TOKEN` but NOT `MINT_TOKENS`. Without that grant, `claimAndPush` reverts inside `sucker.claim` → `mintTokensOf`. Grant explicitly via `JBPermissions.setPermissionsFor`.
- **CREATE2 same-address-across-chains is load-bearing.** `claimAndPush` validates that `leaf.beneficiary == address(this)` on the destination side. If the hook lives at a different address on the destination chain, every cross-chain claim reverts.
- **Multi-terminal deployments need multiple hooks.** `TERMINAL` is constructor-set immutable. Fee volume on any other terminal is invisible to this hook.
- **Pro-rata is monotonic-but-not-snapshot-coherent.** A late-arriving referrer who drives a lot of volume can reduce an earlier referrer's `entitled` below their HWM. The hook clamps at zero; the residual stays in the pool. See `RISKS.md` § 2 and § 7.4.
- **Burn-over-strand is the policy.** When a leaf can't reach a recipient, the hook burns rather than holds. Cross-chain credit on a chain with no sucker → use `burnUnbridgeableCreditFor`. `claimAndPush` to a chain whose local twin has no IVotes token → automatic burn inside the call. See [RISKS.md § 7](./RISKS.md) for the matrix.

## Where State Lives

- Per-referrer same-chain HWM: `pushedLocallyOf[refProjectId]`
- Per-referrer cross-chain HWM (unified across bridge AND burn): `bridgedOutOf[chainId][refProjectId]`
- Cumulative deposits received: `totalDeposited`
- Volume ledger: read-only, from `JBTerminalStore` in `nana-core-v6` (normalized to NATIVE 18-dec)
- Vesting state: lives in `JBTokenDistributor` in `nana-distributor-v6` once `pushTo`/`claimAndPush` forwards
- Sucker outboxes / inboxes: live in `nana-suckers-v6`

## High-Signal Tests

1. `test/JBReferralSplitHook.t.sol` — unit tests for every revert path and storage update
2. `deploy-all-v6/test/fork/ReferralRewardCrossChainFork.t.sol` — 28 cross-chain E2E tests + 4 096-run fuzz on the pro-rata math, covering same-chain push, cross-chain bridge, cross-chain claim with different IDs, USDC fee flow, burn-on-strand, burn-unbridgeable, and shared-HWM invariants

## Install

```bash
npm install @bananapus/referral-split-hook-v6
```

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

- The hook trusts `JBTerminalStore` as a volume oracle. Any operational issue with the originating terminal's attribution flows through here.
- `pushTo`, `bridgeRemote`, `claimAndPush`, and `burnUnbridgeableCreditFor` are all permissionless. Frontends and keepers are expected to call them regularly.
- Burned credit is permanently irrecoverable for the would-be referrer. The policy chooses certainty over preserving every cent for an off-chain decision.

## For AI Agents

- This repo is a thin router. Volume attribution lives upstream in `nana-core-v6`; vesting + claim lives downstream in `nana-distributor-v6`; bridge plumbing lives in `nana-suckers-v6`.
- If you find yourself adding accounting logic here, it likely belongs in one of those repos instead.
- The deferral-vs-stranding decision matrix in [RISKS.md § 7](./RISKS.md) is the design contract. Every new entrypoint must match it.
