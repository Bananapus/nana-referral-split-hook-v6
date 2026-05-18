# Architecture

## Purpose

`nana-referral-split-hook-v6` is a single-purpose router. It sits on the fee project's reserved-token splits, pools incoming fee-project tokens, and forwards each referrer's pro-rata share to `JBTokenDistributor` for vesting/claim by the referrer's IVotes holders.

## System Overview

```
nana-core-v6                       nana-referral-split-hook-v6                  nana-distributor-v6
JBMultiTerminal      ── fee in ─►  JBTerminalStore
JBController         ── reserved tokens ─►  JBReferralSplitHook ── pushTo ──►   JBTokenDistributor
                                                                                ── claim ──► referring project's IVotes holders
```

The hook owns no economic policy. The volume ratio comes from `JBTerminalStore`; the vesting rules come from `JBTokenDistributor`; the deposit cadence comes from whoever calls `sendReservedTokensToSplitsOf` on the fee project.

## Core Invariants

- `pushedOf[referralProjectId]` is monotonically non-decreasing.
- `sum(pushedOf[*]) <= totalDeposited` (the hook never forwards more than it has received).
- Forwarding is one-way: tokens that leave via `pushTo` are not retrievable by this contract.
- `processSplitWith` only accepts calls from the fee project's controller (`JBDirectory.controllerOf(FEE_PROJECT_ID)`).

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `JBReferralSplitHook` | `IJBSplitHook` receiver, pro-rata math, forwarding | Single contract |
| `IJBReferralSplitHook` | External surface (events, errors, view + mutator getters) | Interface only |

## Trust Boundaries

- The hook trusts `JBTerminalStore` as a volume oracle. If `totalFeeVolumeOf` and `feeVolumeByReferralOf` diverge from reality (e.g., terminal write bug), the hook over- or under-distributes.
- The hook trusts `JBDirectory.controllerOf(FEE_PROJECT_ID)` to be honest about which contract is allowed to mint the fee project's reserved tokens. A compromised directory is out of scope.
- The hook trusts `JBTokens.tokenOf(referralProjectId)` to return the correct IVotes ERC-20 for the referring project. A project that has not issued a token is skipped, not blocked.
- The hook does not trust the caller of `pushTo` beyond what storage permits — `pushTo` is permissionless.

## Critical Flows

### Receive Reserved Tokens

```text
fee project owner (or keeper) calls JBController.sendReservedTokensToSplitsOf(FEE_PROJECT_ID)
  -> JBController._sendReservedTokensToSplitGroupOf
    -> forceApprove(this hook, splitTokenCount)
    -> this.processSplitWith(context)
      -> safeTransferFrom(controller, this, amount)
      -> totalDeposited += amount
      -> emit Deposit
```

### Forward a Referrer's Share

```text
anyone calls JBReferralSplitHook.pushTo(referralProjectId)
  -> read totalFeeVolumeOf + feeVolumeByReferralOf from JBTerminalStore
  -> entitled = totalDeposited * refVol / totalVol
  -> if entitled > pushedOf[referralProjectId]:
       pushed = entitled - pushedOf[referralProjectId]
       pushedOf[referralProjectId] = entitled
       resolve referralProjectId's IJBToken
       forceApprove(distributor, pushed)
       JBTokenDistributor.fund(refToken, feeProjectToken, pushed)
       emit Push
  -> if entitled <= pushedOf or referrer has no token: no-op
```

## Accounting Model

- This repo owns `totalDeposited` (an integer count of tokens received from the fee project's splits) and `pushedOf[referralProjectId]` (per-referrer high-water marks of forwarded amounts).
- It does not own the volume ledger (lives in `JBTerminalStore`) or the vesting schedule (lives in `JBTokenDistributor`).
- The entitled-versus-pushed model is a high-water mark, not a snapshot ledger. See `RISKS.md` for the late-entrant skew this introduces.

## Security Model

- A malicious controller could call `processSplitWith` directly with arbitrary `context.amount` if the auth check is bypassed. The auth check (`DIRECTORY.controllerOf(FEE_PROJECT_ID) == msg.sender`) prevents this from any caller other than the canonical controller.
- A malicious referrer cannot inflate their share — the hook reads `JBTerminalStore.feeVolumeByReferralOf` which is keyed by the writing terminal, and an attacker can only pollute their own bucket (per `nana-core-v6` design).
- A referrer with a malicious project token could try to abuse the distributor's `fund()` path. The distributor is responsible for handling that — this hook just forwards.

## Safe Change Guide

- Any change to the volume oracle's denomination (e.g., `nana-core-v6` switching `feeVolumeByReferralOf` from fee-token units to fee-project-token units) requires reviewing the math in `pushTo` and the `RISKS.md` section on cross-token comparability.
- Any change to the distributor's `fund(address hook, IERC20 token, uint256 amount)` signature requires updating this hook's call site.
- If new fee-paying entry points appear in `JBMultiTerminal` (beyond `cashOutTokensOf`/`sendPayoutsOf`/`useAllowanceOf`), no change is needed here — the hook only reads cumulative state.

## Canonical Checks

- token-receipt path:
  `test/JBReferralSplitHook.t.sol`
- push math:
  `test/JBReferralSplitHook.t.sol`

## Source Map

- `src/JBReferralSplitHook.sol`
- `src/interfaces/IJBReferralSplitHook.sol`
