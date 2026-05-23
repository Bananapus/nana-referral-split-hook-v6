# Referral Split Hook Risk Register

This file covers `JBReferralSplitHook` — a single split-hook contract that fans the fee project's reserved-token allocation out to active referrers (same-chain push, cross-chain bridge, and unbridgeable burn paths).

## How To Use This File

- Read `Priority Risks` first. Those are the failure modes with the highest payout-integrity impact.
- Treat the deferral-vs-stranding decision matrix in `Section 7` as the design contract — every entrypoint must match it.
- Use `Invariants to verify` as the minimum test envelope before routing live splits through the hook.

## Priority Risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Mis-routed share via spoofed leaf or wrong sucker peer | Funds bound for one referrer land at another — or in an attacker-controlled distributor key. | Sucker registry check + `peerChainId()` match + leaf `metadata` exact-equality with `(originChainId, refProjectId)`. |
| P0 | Stranding: leaf consumed without a recipient or a burn | Bridged value silently locked in the hook, diluting every fee-token holder forever. | Burn-over-strand policy in `claimAndPush`; permissionless `burnUnbridgeableCreditFor` for cross-chain pools. |
| P1 | Pro-rata math overflow or rounding skew | A referrer gets more (or less) than `mulDiv(totalDeposited, refVol, totalVol)`. | mulDiv used everywhere; `_pendingDeltaFor` is the single source of truth; HWMs are monotonic. |
| P1 | Late-entrant skew across rounds | New referrer drives volume after an earlier one pushed; the earlier one's `entitled` can drop below their HWM and the residual stays in the hook. | Documented as accepted behavior; severity is bounded by the actual volume ratio change. |
| P1 | Mis-wired sucker permissions | `claimAndPush` reverts because the sucker lacks `MINT_TOKENS`; leaf stays unconsumed in the inbox, recoverable by granting and retrying. | Documented as a deployment checklist step. |

## 1. Trust Assumptions

- **`JBDirectory.controllerOf(FEE_PROJECT_ID)` is honest.** It identifies the single legal caller of `processSplitWith`. A controller swap on the fee project moves the deposit authority.
- **`JBTerminalStore.feeVolumeByReferralOf` and `totalFeeVolumeOf` are atomic and currency-normalized.** The store normalizes USDC/USD/etc. fees to NATIVE_TOKEN 18-decimal units; the hook does not re-normalize.
- **`JBSuckerRegistry.suckersOf(feeProjectId)` is authoritative.** The grief-resistance check on `burnUnbridgeableCreditFor` iterates this list.
- **`IJBSucker.peerChainId()` returns the actual peer chain.** The hook does not cross-verify against any other source.
- **The sucker's merkle proof + leaf hashing matches the source-side `_buildTreeHash` exactly.** Otherwise legitimate claims revert and forged claims could pass.
- **The referrer-supplied IVotes token (`TOKENS.tokenOf(refProjectId)`) is not malicious.** A referrer who lies about their token routes their OWN share — but their `transferFrom` can re-enter the hook if the distributor's `fund` triggers it.

## 2. Economic Risks

- **Late-entrant share skew.** `entitled = totalDeposited * refVolume / totalFeeVolume` is computed at push time, not at deposit time. If a new referrer drives a large share of volume **after** an earlier referrer has pushed, the earlier referrer's `entitled` can drop below `pushedLocallyOf`. The hook clamps at zero (no claw-back); the residual tokens stay in the hook permanently. Severity is low because total `mulDiv` allocations sum to ≤ `totalDeposited` regardless.
- **Pro-rata sum bound.** Across all `(chainId, projectId)` pairs, the sum of `pushedLocallyOf + bridgedOutOf` must never exceed `totalDeposited` modulo a small mulDiv rounding tail (one wei per active referrer in the worst case).
- **Burn dilutes by design.** `claimAndPush` burning fresh supply on a missing local twin, and `burnUnbridgeableCreditFor` burning unspendable cross-chain credit, both convert otherwise-stranded value into pro-rata surplus for existing fee-token holders.
- **Late sucker deploy can't reach burned credit.** Once `burnUnbridgeableCreditFor` advances `bridgedOutOf`, a sucker deployed later for that chain can only bridge INCREMENTAL credit — the burned portion is permanently gone for the would-be referrer.

## 3. Access Control And Caller Risks

- **`processSplitWith`** is gated by the controller. Caller mismatch reverts before any state change.
- **`pushTo`, `bridgeRemote`, `claimAndPush`, `burnUnbridgeableCreditFor`** are permissionless. Correctness is enforced by on-chain state checks, not access control.
- **Constructor immutables.** `TERMINAL`, `STORE`, `DIRECTORY`, `TOKENS`, `DISTRIBUTOR`, `SUCKER_REGISTRY`, `FEE_PROJECT_ID` are immutable. A wrong value at deploy produces a permanently mis-routed hook.
- **No admin / no pause / no upgrade.** Recovery requires re-deploying and re-wiring the fee project's split table.

## 4. DoS And Liveness Risks

- **A reverting referrer IVotes token blocks that referrer's push.** `forceApprove(distributor, amount)` or `DISTRIBUTOR.fund(refToken, ...)` reverting cascades up. The hook's HWM is rolled back via the natural revert; other referrers continue working.
- **Missing sucker `MINT_TOKENS` permission blocks all cross-chain claims for that sucker.** Leaves remain in the inbox; grant permission and retry.
- **Sucker iteration in `burnUnbridgeableCreditFor`.** O(N) external calls where N is the fee project's sucker count. N is bounded in practice (one per active destination chain).
- **The fee project's reserved-token distribution is the only way to grow `totalDeposited`.** If the fee project's controller stops calling `sendReservedTokensToSplitsOf`, the hook stops receiving deposits — but already-deposited shares remain claimable.

## 5. Integration Risks

- **Single-terminal attribution.** The hook is bound to a single `TERMINAL` address. Volume on other terminals is invisible. Multi-terminal deployments need multiple hooks (or a future multi-terminal variant).
- **CREATE2-deterministic peer assumption.** Cross-chain settlement relies on the convention that the hook lives at the SAME address on every chain (so the leaf's `beneficiary = address(this)` matches both sides). A non-deterministic deployment breaks `claimAndPush`.
- **`bridgedOutOf` is a unified HWM across `bridgeRemote` AND `burnUnbridgeableCreditFor`.** Don't add a separate `burnedOutOf` ledger — that would let burns and bridges double-count the same volume.
- **Mixed-currency fee projects work because the store normalizes.** `JBTerminalStore._normalizeToNativeTokenUnits` converts USDC, USD, and other-currency fees into NATIVE_TOKEN 18-dec units in the volume ledger before the hook ever reads it.
- **Fee-on-transfer tokens are unsupported on deposit.** `processSplitWith` records `context.amount`, not a `balanceOf` delta. A fee-on-transfer fee-project token would silently under-fund the hook.
- **A referrer with no ERC-20 yet defers on same-chain.** `pushTo` rolls back the HWM. The share is recoverable when the referrer tokenizes. This is documented behavior, not a bug.

## 6. Invariants To Verify

- `totalDeposited` is monotonic (only `processSplitWith` writes, only the controller can call it).
- `pushedLocallyOf[refId]` is monotonic.
- `bridgedOutOf[chainId][refId]` is monotonic.
- For all `(chainId, refId)`, `pushedLocallyOf[refId] + bridgedOutOf[chainId][refId] <= totalDeposited * (refVol_chain_id + refVol_local) / totalVol` modulo mulDiv rounding.
- `claimAndPush` consumes the leaf exactly once. Re-entry reverts on `_executedFor` bitmap.
- `burnUnbridgeableCreditFor` reverts when ANY registered sucker peers to the asserted chain.
- For all entrypoints: the HWM write happens BEFORE any external call.
- A single-chain numeric collision (project 42 on chain 10 vs. project 42 on chain 137) produces two independent slots in `bridgedOutOf`.

## 7. Accepted Behaviors

### 7.1 Same-chain credit-only referrer defers indefinitely

If a referring project has only issued credits (no `IJBToken` ERC-20), `pushTo(localChainId, refProjectId)` is a no-op. The HWM is rolled back so the share stays claimable when the project tokenizes. If they never tokenize, the share sits in the hook indefinitely — this is deferral, not stranding (recoverable). Operators who want to recycle this dust would need a separate governance write-off (deferred design).

### 7.2 Cross-chain credit on a chain with no sucker is burned

The cross-chain analog of 7.1 is NOT deferral — it's stranding. Anyone calls `burnUnbridgeableCreditFor(chainId, projectId)`; the hook confirms no sucker peers to `chainId`, computes the entitled delta, advances `bridgedOutOf`, and burns the equivalent fee-project tokens. The bridged terminal-token value (already in the fee project's balance from the original protocol-fee flow) now accrues pro-rata to existing fee-token holders.

### 7.3 `claimAndPush` burns on missing local twin

When the sucker leaf settles but the local twin's `TOKENS.tokenOf(refProjectId)` is `address(0)`, the freshly-minted fee-project tokens are burned rather than left in the hook. The leaf is single-use and is now consumed; holding the supply would permanently dilute existing holders for no recipient.

### 7.4 Late-entrant share skew is bounded

When a new referrer joins after earlier referrers have pushed, the earlier referrers' `entitled` can drop below their HWM. The hook does not claw back the difference. The total mulDiv allocation across all referrers remains bounded by `totalDeposited`, so the residual stays in the hook (not redistributed to other referrers — it dilutes nobody and benefits nobody).

### 7.5 Single-terminal attribution

The hook tracks volume only for its constructor-set `TERMINAL`. Multi-terminal fee setups are not supported within a single hook instance.

### 7.6 Burned credit cannot be unburned by future infrastructure

Once `burnUnbridgeableCreditFor` advances `bridgedOutOf`, a sucker deployed later for that chain can only bridge INCREMENTAL credit. The burned portion is irrecoverable for the originally-credited referrer. This is the cost of preventing indefinite dilution; the policy chooses certainty over preserving every cent for an off-chain decision.
