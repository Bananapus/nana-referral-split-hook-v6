# Architecture

## Purpose

`nana-referral-split-hook-v6` is a single-purpose router. It sits on the fee project's reserved-token splits, pools incoming fee-project tokens, and routes each referrer's pro-rata share to its destination: a local `JBTokenDistributor` for same-chain referrers, the fee project's sucker outbox for cross-chain referrers, or the burn path for credit on chains with no sucker pair.

## System Overview

```
nana-core-v6                       nana-referral-split-hook-v6                      nana-distributor-v6 / nana-suckers-v6
JBMultiTerminal      ── fee in ─►  JBTerminalStore (normalized to NATIVE 18-dec)
JBController         ── reserved tokens ─►  JBReferralSplitHook
                                              ├─ pushTo (same-chain) ───────────►  JBTokenDistributor.fund
                                              ├─ bridgeRemote (cross-chain) ────►  JBSucker.prepare → outbox leaf
                                              ├─ claimAndPush (cross-chain in) ─►  JBSucker.claim → mintTokensOf + addToBalance, then forward OR park (pending tokenization)
                                              ├─ pokeDeferredClaim ─────────────►  JBTokenDistributor.fund (release a parked deferred claim)
                                              └─ burnUnbridgeableCreditFor ─────►  JBController.burnTokensOf (no sucker for chain)
```

The hook owns no economic policy. The volume ratio comes from `JBTerminalStore`; the vesting rules come from `JBTokenDistributor`; the deposit cadence comes from whoever calls `sendReservedTokensToSplitsOf` on the fee project; the bridge mechanics come from `JBSucker`.

## Core Invariants

- `totalDeposited` is monotonically non-decreasing — only `processSplitWith` writes, only the controller can call it.
- `pushedLocallyOf[refProjectId]` is monotonically non-decreasing.
- `bridgedOutOf[chainId][refProjectId]` is monotonically non-decreasing. It is the UNIFIED ledger across `bridgeRemote` AND `burnUnbridgeableCreditFor` — there is no separate `burnedOutOf` slot.
- `sum(pushedLocallyOf[*]) + sum(bridgedOutOf[*][*]) <= totalDeposited` modulo a small mulDiv rounding tail.
- `processSplitWith` only accepts calls from `JBDirectory.controllerOf(FEE_PROJECT_ID)`.
- A sucker leaf consumed by `claimAndPush` is single-use forever.

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `JBReferralSplitHook` | `IJBSplitHook` receiver, pro-rata math, routing (push / bridge / claim / burn) | Single contract, no abstract base |
| `IJBReferralSplitHook` | External surface (events, errors, view + mutator getters, entrypoints) | Interface only — errors and events both live here so test callers don't need to import the implementation |

## Trust Boundaries

- The hook trusts `JBTerminalStore` as a volume oracle. `totalFeeVolumeOf` and `feeVolumeByReferralOf` are read-only inputs; if upstream diverges from reality (e.g., a terminal write bug), the hook over- or under-distributes.
- The hook trusts `JBDirectory.controllerOf(FEE_PROJECT_ID)` to identify the legal caller of `processSplitWith`.
- The hook trusts `JBTokens.tokenOf(...)` to return the correct IVotes ERC-20 for any project — or `address(0)` for un-tokenized projects.
- The hook trusts `JBSuckerRegistry.suckersOf(FEE_PROJECT_ID)` and each sucker's `peerChainId()` for cross-chain routing decisions.
- The hook trusts the sucker's merkle proof + `metadata` field to authenticate cross-chain claims. Forging a leaf is the sucker's problem, not the hook's.
- The hook does NOT trust the caller of any settle-side entrypoint (`pushTo`, `bridgeRemote`, `claimAndPush`, `burnUnbridgeableCreditFor`). All four are permissionless.

## Critical Flows

### Receive Reserved Tokens

```text
fee project owner (or keeper) calls JBController.sendReservedTokensToSplitsOf(FEE_PROJECT_ID)
  -> JBController._sendReservedTokensToSplitGroupOf
    -> mint reserved fee-project tokens to the controller
    -> approve(this hook, splitTokenCount)
    -> this.processSplitWith(context)
      -> auth check: msg.sender == DIRECTORY.controllerOf(FEE_PROJECT_ID) && context.projectId == FEE_PROJECT_ID
      -> safeTransferFrom(controller, this, amount)
      -> totalDeposited += amount
      -> emit Deposit
```

### Same-Chain Forward (pushTo)

```text
anyone calls JBReferralSplitHook.pushTo(referralChainId == block.chainid, refProjectId)
  -> _pendingDeltaFor reads totalFeeVolumeOf + feeVolumeByReferralOf from JBTerminalStore
  -> entitled = mulDiv(totalDeposited, refVol, totalVol)
  -> if entitled > pushedLocallyOf[refProjectId]:
       advance HWM
       resolve refProjectId's IJBToken
       if no token: roll back HWM, emit Skipped (deferral — recoverable when project tokenizes)
       else: forceApprove(distributor, delta); DISTRIBUTOR.fund(refToken, feeToken, delta); emit Push
  -> if entitled <= pushedLocallyOf: emit Skipped("caught up")
```

### Cross-Chain Bridge (bridgeRemote)

```text
anyone calls JBReferralSplitHook.bridgeRemote(remoteChainId, refProjectId, sucker, terminalToken)
  -> reject if refProjectId == 0 || refProjectId == FEE_PROJECT_ID
  -> reject if remoteChainId == 0 || remoteChainId == block.chainid
  -> verify SUCKER_REGISTRY.isSuckerOf(FEE_PROJECT_ID, sucker)
  -> verify sucker.peerChainId() == remoteChainId
  -> compute delta = entitled - bridgedOutOf[remoteChainId][refProjectId]
  -> advance bridgedOutOf BEFORE external call
  -> approve(sucker, delta)
  -> sucker.prepare({
       projectTokenCount: delta,
       beneficiary: bytes32(address(this)),       // CREATE2 same-address convention
       minTokensReclaimed: 0,
       token: terminalToken,
       metadata: packLeafMetadata(block.chainid, refProjectId)
     })
  -> emit BridgedRemote
```

### Cross-Chain Claim (claimAndPush)

```text
anyone calls JBReferralSplitHook.claimAndPush(originChainId, refProjectId, sucker, claimData)
  -> reject if refProjectId == 0 || refProjectId == FEE_PROJECT_ID
  -> reject if originChainId == 0 || originChainId == block.chainid
  -> verify SUCKER_REGISTRY.isSuckerOf(FEE_PROJECT_ID, sucker)
  -> verify claimData.leaf.beneficiary == bytes32(address(this))
  -> verify claimData.leaf.metadata == packLeafMetadata(originChainId, refProjectId)
  -> snapshot fee-project balance of self
  -> sucker.claim(claimData)
       -> sucker validates merkle proof, sets executed bitmap, mints fee-project tokens to self, addToBalance for terminal tokens
  -> feeProjectMinted = balanceAfter - balanceBefore
  -> resolve refProjectId's IJBToken on this chain
  -> if no token: park feeProjectMinted under keccak256(abi.encode(sucker, terminalToken, leafIndex)); emit ParkedOnStrand (anyone can release later via pokeDeferredClaim)
  -> else: forceApprove(distributor, feeProjectMinted); DISTRIBUTOR.fund(refToken, feeToken, feeProjectMinted); emit ClaimedRemote
```

### Poke Deferred Claim (pokeDeferredClaim)

```text
anyone calls JBReferralSplitHook.pokeDeferredClaim(sucker, terminalToken, leafIndex)
  -> strandedKey = keccak256(abi.encode(sucker, terminalToken, leafIndex))
  -> amount = parkedAmountOf[strandedKey] (revert NothingParked if zero)
  -> refProjectId = parkedReferralProjectIdOf[strandedKey]
  -> resolve refProjectId's IJBToken on this chain (revert StillStranded if address(0))
  -> delete parkedAmountOf[strandedKey]; delete parkedReferralProjectIdOf[strandedKey] (clear-before-call)
  -> forceApprove(distributor, amount); DISTRIBUTOR.fund(refToken, feeToken, amount); emit PokedDeferredClaim
```

### Burn Unbridgeable Credit (burnUnbridgeableCreditFor)

```text
anyone calls JBReferralSplitHook.burnUnbridgeableCreditFor(remoteChainId, refProjectId)
  -> reject if refProjectId == 0 || refProjectId == FEE_PROJECT_ID
  -> reject if remoteChainId == 0 || remoteChainId == block.chainid
  -> iterate SUCKER_REGISTRY.suckersOf(FEE_PROJECT_ID)
       -> if any peerChainId() == remoteChainId: revert SuckerExistsForChain (must use bridgeRemote)
  -> compute delta = entitled - bridgedOutOf[remoteChainId][refProjectId]
  -> advance bridgedOutOf (shared HWM with bridgeRemote)
  -> burnTokensOf(self, FEE_PROJECT_ID, delta)
  -> emit BurnedUnbridgeable
```

## Accounting Model

- The hook owns `totalDeposited`, `pushedLocallyOf[refId]`, and `bridgedOutOf[chainId][refId]`. All three are monotonic high-water marks.
- The hook does NOT own the volume ledger (`JBTerminalStore.feeVolumeByReferralOf`), the vesting state (`JBTokenDistributor`), or the bridge state (`JBSucker._outboxOf` / `_inboxOf`).
- The entitled-versus-pushed model is a high-water mark, not a snapshot. Late-arriving referrers can shrink earlier referrers' `entitled` below their HWM — the hook clamps at zero and the residual stays unredistributable in the pool. See `RISKS.md` § 2.

## Security Model

- A malicious controller could call `processSplitWith` directly with arbitrary `context.amount`. The auth check (`DIRECTORY.controllerOf(FEE_PROJECT_ID) == msg.sender`) prevents this from any caller other than the canonical controller.
- A malicious referrer cannot inflate their share — `feeVolumeByReferralOf` is keyed by the writing terminal, and an attacker can only pollute their own bucket (per `nana-core-v6` design).
- A referrer with a malicious project token could try to abuse the distributor's `fund` path. The distributor is responsible for handling that — this hook just forwards.
- A forged leaf cannot reach `claimAndPush` because the sucker's merkle proof + `_inboxOf` root validation rejects it; the hook's `leaf.beneficiary == address(this)` and `leaf.metadata == pack(origin, refId)` checks add belt-and-braces guards before the external call.
- A grief attempt against `burnUnbridgeableCreditFor` (trying to burn a bridgeable referrer's credit) reverts because the function iterates the registry and rejects if any sucker peers to the asserted chain.

## Safe Change Guide

- Any change to the volume oracle's denomination requires reviewing `_pendingDeltaFor` in this hook. The store currently normalizes to NATIVE 18-dec; if that changes, the math here must be updated.
- Any change to `JBTokenDistributor.fund(address, IERC20, uint256)` requires updating this hook's call site.
- Any change to `JBSucker.prepare`/`claim` or to the merkle leaf hashing requires re-validating the cross-chain path end-to-end.
- New fee-paying entry points in `JBMultiTerminal` require no change here — the hook only reads cumulative state.
- Reordering of HWM advance vs. external call would break reentrancy safety. Always: advance HWM BEFORE the external call.

## Canonical Checks

- Unit tests for entrypoint reverts and storage updates:
  `test/JBReferralSplitHook.t.sol`
- Cross-chain end-to-end (28 tests + 4 096-run fuzz):
  `../deploy-all-v6/test/fork/ReferralRewardCrossChainFork.t.sol`

## Source Map

- `src/JBReferralSplitHook.sol`
- `src/interfaces/IJBReferralSplitHook.sol`
