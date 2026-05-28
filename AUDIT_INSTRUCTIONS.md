# Audit Instructions

This repo is a single 470-line split hook plus its interface. Audit it as a router with high-stakes pro-rata math, cross-chain settlement, and three burn-vs-defer-vs-revert decision points that absolutely cannot strand value.

## Audit Objective

There is a billion dollars of well-meaning projects' money flowing through the Juicebox protocol fee. This hook decides how the fee project's reserved-token allocation gets divided between active referrers and existing fee-token holders. Your job is to hack it before anyone else — whoever hacks it first saves/steals the money, and you are obsessed with being this winner, while also being a steward of the protocol and wanting it to keep growing safely.

Suggestions of where to look:

- misallocate shares because the pro-rata math is wrong (rounding, overflow, ordering of `totalDeposited` reads vs. writes)
- spoof a sucker leaf into routing value to the wrong referrer (forge a leaf with metadata pointing at YOUR project)
- exploit reentrancy through the controller's `mintTokensOf`, the sucker's `prepare`/`claim`, or the distributor's `fund` to double-process a referrer's share
- get `burnUnbridgeableCreditFor` to burn a bridgeable referrer's credit (grief vector — must be impossible)
- get `claimAndPush` to forward to a malicious IJBToken that re-enters and drains the hook
- find a path where the leaf is consumed but no fee-project value flows to either a referrer, a burn, OR a recoverable park (true stranding)

## Scope

In scope:

- `src/JBReferralSplitHook.sol`
- `src/interfaces/IJBReferralSplitHook.sol`

Out of scope (but heavily referenced):

- `JBTerminalStore.feeVolumeByReferralOf` — the volume ledger. Audited in `nana-core-v6`.
- `JBSucker.claim` / `JBSucker.prepare` / `JBSuckerRegistry.suckersOf` — the bridge plumbing. Audited in `nana-suckers-v6`.
- `JBTokenDistributor.fund` — the destination. Audited in `nana-distributor-v6`.
- `JBController.mintTokensOf` and `burnTokensOf` — minted and burned via callbacks from the sucker and this hook respectively. Audited in `nana-core-v6`.

## Start Here

1. `src/interfaces/IJBReferralSplitHook.sol` — read the NatSpec on every function and event. The naming convention for `referralProjectId` (always the projectId on the referrer's HOME chain, never numerically aliased across chains) is the most load-bearing convention in the file.
2. `src/JBReferralSplitHook.sol`, `processSplitWith` and `pushTo` — same-chain happy path. Confirm the HWM rollback on the "no token" branch.
3. `bridgeRemote` — cross-chain outbound. Confirm the peer-chain check is load-bearing and that `bridgedOutOf` advances BEFORE the external `sucker.prepare`.
4. `claimAndPush` — cross-chain inbound. The leaf is consumed inside `sucker.claim` BEFORE the park-or-forward decision. Trace what happens in every error branch. `pokeDeferredClaim` is the deferred-release path that drains a parked entry once the referrer tokenizes.
5. `burnUnbridgeableCreditFor` — iterates the registry. Confirm the grief-resistance check is correct (no false negatives, no race-condition where a sucker is added between the check and the burn).
6. Private helpers — `_pendingDeltaFor` is pure-of-storage with respect to the HWM (the caller writes back). `_fundDistributor` does `forceApprove`/`fund` against an arbitrary referrer-supplied IVotes address — verify there's no way to inject a malicious token here.

## Security Model

The hook trusts:
- `DIRECTORY.controllerOf(FEE_PROJECT_ID)` to be honest about who can deposit.
- `STORE.feeVolumeByReferralOf` and `STORE.totalFeeVolumeOf` to record volume credits exactly once per fee payment, normalized to NATIVE_TOKEN units (18 dec) by the store.
- `SUCKER_REGISTRY.isSuckerOf` and the sucker's own `peerChainId()` to identify which destination a bridge leg reaches.
- The sucker's merkle proof + the leaf's `metadata` field to authenticate claims from remote chains.
- `TOKENS.tokenOf(refProjectId)` to return either the project's actual IVotes ERC-20 or `address(0)` — never a malicious shim.

The hook does NOT trust:
- The caller of `bridgeRemote` / `claimAndPush` / `burnUnbridgeableCreditFor`. All three are permissionless and validated entirely from state.
- The terminal-token address inside `JBClaim`. The leaf's `terminalTokenAmount` only authenticates the SAME `(amount, beneficiary, metadata)` tuple the sender committed to — the destination side's `_handleClaim` is what actually moves value, not the hook.

## Critical Invariants

1. **No stranding.** For every entrypoint and every error/skip branch, fee-project tokens in the hook must either flow to a distributor, get burned, or remain claimable via deferral with HWM rolled back. There must be no path where a leaf is consumed AND no recipient gets value.
2. **Pro-rata math is monotonic and bounded.** For all `(chainId, projectId)`, `pushedLocallyOf(...) + bridgedOutOf(...)` ≤ `totalDeposited * sum(refVol) / totalFeeVolume` modulo a small mulDiv rounding tail. Across all referrers, the sum of pushed/bridged/burned is bounded by `totalDeposited`.
3. **Leaf single-use.** Once `claimAndPush` runs (sucker's executed bitmap is set), the same leaf can never be replayed — whether forwarding or parking.
4. **Cross-chain ID independence.** A numeric projectId of `42` on chain 10 and the same `42` on chain 137 produce two INDEPENDENT slots in `bridgedOutOf` and refer to two unrelated projects.
5. **Grief-resistance on `burnUnbridgeableCreditFor`.** The function must revert when ANY registered sucker peers to the asserted chain. There is no off-chain "intent" — the check is purely on-chain.
6. **No write-before-external-call window.** All HWM updates happen BEFORE the external sucker / distributor / controller call. Reentrancy cannot grow `delta` because `totalDeposited` and `feeVolumeByReferralOf` are both monotonic and not reduced by any callback path.

## Adversarial Scenarios To Consider

- Forge a `JBClaim` and try to route it through `claimAndPush` — the merkle proof + leaf metadata mismatch checks should make this impossible.
- Deploy a malicious IJBToken with a re-entrant `approve` or `transferFrom`, point a referrer's `tokenOf` at it, then trigger a `pushTo` or `claimAndPush` — should not allow draining the hook beyond the HWM's worth.
- Front-run a legitimate `bridgeRemote` with a `burnUnbridgeableCreditFor` for the same `(chainId, projectId)` — should revert because a sucker exists.
- Set up a sucker whose `peerChainId()` is mutable post-deployment (mock for adversarial testing) and check whether `burnUnbridgeableCreditFor` can be tricked into burning bridgeable credit.
- Test `claimAndPush` when `TOKENS.tokenOf(referralProjectId)` returns `address(0)` — the park path should populate `parkedAmountOf` and `parkedReferralProjectIdOf` exactly once per leaf, and `pokeDeferredClaim` should release the parked amount once the referrer tokenizes. A second `claimAndPush` for the same leaf must revert with `LeafAlreadySettled`.
- Pass `referralProjectId = type(uint48).max`. The fee record in `nana-core-v6` uses `uint48`, so this is the max representable. Verify no overflow or weirdness in `_pendingDeltaFor`'s mulDiv.

## Reference Reading

- `RISKS.md` — risk register with explicit accepted behaviors
- `ARCHITECTURE.md` — module-level dataflow including the cross-chain path
- `USER_JOURNEYS.md` — five end-to-end flows from real callers' perspectives
- `nana-core-v6/src/JBMultiTerminal.sol` — fee-paying entry points and the transient referral slot.
- `nana-core-v6/src/JBTerminalStore.sol` — `feeVolumeByReferralOf`, `totalFeeVolumeOf`, `_normalizeToNativeTokenUnits`.
- `nana-suckers-v6/src/JBSucker.sol` — `claim`, `prepare`, `_handleClaim`, merkle proof validation.
- `nana-distributor-v6/src/JBTokenDistributor.sol` — `fund` and the IVotes-keyed pro-rata math.

## Verification

- `npm install`
- `forge build --deny notes`
- `forge test --deny notes`

The cross-chain end-to-end test suite lives in `deploy-all-v6/test/fork/ReferralRewardCrossChainFork.t.sol` (28 tests, 4 096-run fuzz on the pro-rata math). Audit it as part of this repo's coverage.
