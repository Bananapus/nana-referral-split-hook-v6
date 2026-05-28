# Invariants of `nana-referral-split-hook-v6`

Scope: the single production contract in `src/` — `JBReferralSplitHook` — plus its `IJBReferralSplitHook` interface in `src/interfaces/`. The hook sits on the fee project's reserved-token split group, pools incoming fee-project tokens via the controller's `processSplitWith` call, and forwards each referring project's pro-rata share to its rightful destination: a local `JBTokenDistributor` (same-chain referrer), the fee project's sucker outbox (cross-chain referrer), or the burn path (credit on a chain with no sucker pair, or a destination chain with no local twin ERC-20).

This file is the per-repo scoped invariants doc. The protocol-wide guarantees for the seven deployed revnets live in [`../INVARIANTS.md`](../INVARIANTS.md); section C.24 there summarizes this repo from the protocol's perspective. The cross-cutting "burn-on-strand vs deferral" design contract lives in `RISKS.md` Section 7; this file enumerates the operational invariants that implement that contract.

---

# Section A — Guarantees to Referrers

The hook has exactly one population of "users": referring projects (and through them, the holders of those projects' IVotes tokens). There is no payer-side or holder-side cash-out surface here — the hook never custodies value beyond the brief window between `processSplitWith` deposit and forwarding.

## A.1 Pro-rata entitlement

- **A.1.1 Single-source-of-truth math.** Every entitlement computation goes through the same private helper, `_pendingDeltaFor`, which computes `entitled = mulDiv(totalDeposited, refVol, totalVol)` using `STORE.totalFeeVolumeOf(TERMINAL)` and `STORE.feeVolumeByReferralOf(TERMINAL, chainId, projectId)` (`src/JBReferralSplitHook.sol:809–855`). `pushTo`, `bridgeRemote`, and `burnUnbridgeableCreditFor` all reuse this helper — there is no second copy of the formula that could drift.
- **A.1.2 Volume ledger is read-only.** The hook NEVER writes to `JBTerminalStore.feeVolumeByReferralOf` or `totalFeeVolumeOf`. Attribution happens upstream in `JBMultiTerminal`; this hook only consumes the ratio. A controller swap or terminal swap on the fee project does not retroactively re-attribute past credit.
- **A.1.3 Monotonic high-water marks.** `pushedLocallyOf[refProjectId]`, `bridgedOutOf[chainId][refProjectId]`, and `totalDeposited` are append-only. The hook clamps `delta = entitled - alreadyProcessed` at zero — no claw-back is ever performed even if a late-arriving referrer's volume drops an earlier referrer's `entitled` below their HWM (see A.4.2).
- **A.1.4 Pro-rata sum bound.** For every `(chainId, refId)` triple, `pushedLocallyOf[refId] + bridgedOutOf[chainId][refId] ≤ totalDeposited × refVol/totalVol` at the moment of write, modulo a small mulDiv rounding tail (at most 1 wei per active referrer in the worst case). The sum across all referrers can never exceed `totalDeposited`.
- **A.1.5 Per-chain projectId independence.** Across `pushTo`, `bridgeRemote`, `claimAndPush`, `burnUnbridgeableCreditFor`, and the `bridgedOutOf` storage slot, `referralProjectId` ALWAYS refers to the projectId on the referrer's home chain (`referralChainId`). A numeric `42` on Optimism and a numeric `42` on Base get two independent budget slots (`src/JBReferralSplitHook.sol:150–153` storage NatSpec).

## A.2 Same-chain push (`pushTo`)

- **A.2.1 Deferral for credit-only referrers.** If `TOKENS.tokenOf(referralProjectId) == address(0)` (no IVotes ERC-20 deployed yet), `pushTo` rolls the HWM back to its pre-call value and emits `Skipped("no token")` (`src/JBReferralSplitHook.sol:722–732`). The share stays claimable when the referrer tokenizes. This is **same-chain deferral**, the only deferral path; cross-chain analogs burn instead (Section A.3.5).
- **A.2.2 Cross-chain inputs skip rather than route.** If `referralChainId != block.chainid`, `pushTo` emits `Skipped("remote")` and returns 0 without touching state (`src/JBReferralSplitHook.sol:697–705`). Cross-chain referrers must use `bridgeRemote`.
- **A.2.3 Sentinel rejection.** `referralProjectId == 0` or `referralProjectId == FEE_PROJECT_ID` reverts `JBReferralSplitHook_InvalidReferralProjectId` before any storage read (`src/JBReferralSplitHook.sol:688–690`). Self-attribution to the fee project itself is structurally impossible.
- **A.2.4 HWM-before-external-call ordering.** `pushedLocallyOf[refId] = alreadyPushed + deltaToProcess` runs BEFORE the distributor's `fund` call (`src/JBReferralSplitHook.sol:713–716`). A reentrant push from inside the distributor sees the advanced HWM and either skips (`caught up`) or only acts on the incremental delta — no double-spend.
- **A.2.5 Allowance reset after pull.** `_fundDistributor` calls `forceApprove(DISTRIBUTOR, amount)` BEFORE the pull and `forceApprove(DISTRIBUTOR, 0)` AFTER (`src/JBReferralSplitHook.sol:792–798`). An underpulling distributor cannot leave a standing allowance against subsequent deposits.

## A.3 Cross-chain outbound (`bridgeRemote`)

- **A.3.1 Sucker-registration check.** `SUCKER_REGISTRY.isSuckerOf({projectId: FEE_PROJECT_ID, addr: address(sucker)})` must be true (`src/JBReferralSplitHook.sol:257–259`). An attacker cannot route value through an arbitrary contract; only registered fee-project suckers are accepted.
- **A.3.2 ENABLED-state check.** `sucker.state() == JBSuckerState.ENABLED` is enforced (`src/JBReferralSplitHook.sol:266–269`). Deprecated suckers (DEPRECATION_PENDING / SENDING_DISABLED / DEPRECATED) retain registration so pending inbound claims can settle, but they MUST NOT accept new outbound bridges. Without this check, an outbound `prepare` on a deprecated sucker would revert deep inside the sucker (after the hook had set its allowance) AND would muddy the ledger if it later races a freshly-deployed replacement.
- **A.3.3 Peer chain match.** `sucker.peerChainId() == referralChainId` is enforced (`src/JBReferralSplitHook.sol:275–280`). Routing through a sucker whose peer is on a different chain would land credit at the wrong destination's local-twin.
- **A.3.4 HWM-before-prepare ordering.** `bridgedOutOf[referralChainId][referralProjectId] = alreadyBridged + deltaToProcess` runs BEFORE `sucker.prepare` (`src/JBReferralSplitHook.sol:293–326`). Reentrancy via the sucker's internal terminal cash-out cannot double-bridge.
- **A.3.5 Caller-chosen slippage.** `minTokensReclaimed` is a caller parameter passed through to `sucker.prepare` (`src/JBReferralSplitHook.sol:230–326`). Because `bridgeRemote` is permissionless, the hook cannot pick a safe slippage value unilaterally — each caller picks their own MEV/sandwich tolerance against current pool depth. Passing 0 is allowed but leaves the bonding-curve cash-out leg fully exposed.
- **A.3.6 Allowance reset after prepare.** `forceApprove(sucker, bridged)` precedes the `prepare` call; `forceApprove(sucker, 0)` follows (`src/JBReferralSplitHook.sol:312, 330`). Defense-in-depth: a non-pulling sucker cannot leave a standing allowance.
- **A.3.7 Sentinel + same-chain + zero-chain rejection.** `referralProjectId ∈ {0, FEE_PROJECT_ID}` reverts `InvalidReferralProjectId`; `referralChainId == 0` reverts `ZeroChainId`; `referralChainId == block.chainid` reverts `WrongBridgeTarget` (`src/JBReferralSplitHook.sol:242–253`).
- **A.3.8 Leaf metadata binding.** The hook writes `packLeafMetadata(originChainId: block.chainid, referralProjectId)` into the sucker leaf's `metadata` field (`src/JBReferralSplitHook.sol:305`). The destination side re-derives the same value and rejects any mismatch (Section A.4.4). This is what binds the leaf to a specific `(originChainId, referralProjectId)` pair — substituting either field on the destination side fails the equality check.
- **A.3.9 Cross-chain hook same-address assumption.** `beneficiary` on the sucker leaf is `address(this)` (`src/JBReferralSplitHook.sol:322`). The deploy convention is that `JBReferralSplitHook` is CREATE2-deployed at the same address across chains, so `address(this)` here equals the address that will receive the bridged terminal tokens on the destination chain. A non-deterministic deployment breaks every cross-chain claim.

## A.4 Cross-chain inbound (`claimAndPush`)

- **A.4.1 Origin-chain rejection.** `originChainId == block.chainid` reverts `OriginIsLocal` (`src/JBReferralSplitHook.sol:513`). Bridged claims must come from a different chain; same-chain settlement happens via `pushTo`. Without this, a caller could construct a synthetic local-chain leaf and route it through `claimAndPush` to skip the same-chain HWM accounting.
- **A.4.2 Sucker-registration check.** `SUCKER_REGISTRY.isSuckerOf` is enforced (`src/JBReferralSplitHook.sol:517–519`). Unlike `bridgeRemote`, `claimAndPush` does NOT additionally require `state == ENABLED` — settling a leaf that came from a now-deprecated sucker is exactly the legitimate "drain pending claims after deprecation" use case.
- **A.4.3 Beneficiary check.** `claimData.leaf.beneficiary == _toBytes32(address(this))` is enforced (`src/JBReferralSplitHook.sol:524–529`). The sucker's merkle proof would catch a tampered leaf, but checking the beneficiary explicitly catches a mismatched-claim-data call before the hook touches state.
- **A.4.4 Metadata check.** `claimData.leaf.metadata == packLeafMetadata(originChainId, referralProjectId)` is enforced (`src/JBReferralSplitHook.sol:535–539`). A caller cannot substitute the `referralProjectId` argument and redirect bridged tokens to a different local distributor — the asserted pair must match the leaf's committed pair.
- **A.4.5 Front-run defense (per-leaf hash authentication).** `sucker.claim` is permissionless; any third party with a valid merkle proof can call it directly and consume the leaf before this hook's call lands. The naive "check the executed bitmap and trust caller's claimData" is exploitable because the bitmap proves *some* leaf at index I was executed, not *which* leaf. The defense queries `sucker.executedLeafHashOf(token, index)`; if non-zero, the leaf was already executed, and the hook re-derives the same hash via `keccak256(abi.encodePacked(projectTokenCount, terminalTokenAmount, beneficiary, metadata))` and compares (`src/JBReferralSplitHook.sol:555–573`). A match authenticates that the caller's claimData corresponds to the actually-executed leaf; fabricated claimData with the same index but tampered fields produces a different hash and reverts `JBReferralSplitHook_FrontRunLeafMismatch`. See `RISKS.md` Section 8 for the threat model. The `abi.encodePacked` form is byte-identical to the sucker's `_buildTreeHash` because all four operands are word-sized (no `abi.encodePacked` padding ambiguity) — codified in the `jb-sucker-claim-front-run-defense` skill.
- **A.4.6 Per-leaf single-settlement.** `settledLeafOf[sucker][token][index]` is checked BEFORE any external call and written AFTER (`src/JBReferralSplitHook.sol:544–548, 591–593`). A stale-proof revert in the normal path leaves the flag unset and the caller can retry with a fresh proof. Re-settling a successfully claimed leaf reverts `LeafAlreadySettled`.
- **A.4.7 Balance-delta accounting on normal path.** When the leaf is unexecuted, the hook snapshots `feeProjectBalanceBefore = balanceOf(this)`, calls `sucker.claim`, then computes `feeProjectMinted = balanceAfter - balanceBefore` (`src/JBReferralSplitHook.sol:585–588`). The leaf field is not trusted at face value — only the realized balance change is forwarded.
- **A.4.8 Burn-on-strand for missing local twin.** When `TOKENS.tokenOf(referralProjectId) == address(0)` on the destination chain, `feeProjectMinted` is burned via the fee project's controller (`src/JBReferralSplitHook.sol:599–638`). The leaf is single-use and now consumed; holding the supply would permanently dilute every existing fee-token holder for no recipient. The bridged terminal-token value (already deposited into the fee project's surplus by the sucker's `_handleClaim`) therefore accrues pro-rata to existing holders.
- **A.4.9 No destination-side HWM.** `claimAndPush` writes neither `bridgedOutOf` nor `pushedLocallyOf` — both ledgers track the SOURCE side of work this hook initiated, not destinations of bridges initiated by other chains' hooks (`src/JBReferralSplitHook.sol:483–484` NatSpec). The destination side only tracks per-leaf single-settlement (A.4.6).

## A.5 Cross-chain burn (`burnUnbridgeableCreditFor`)

- **A.5.1 Stranding test iterates the FULL sucker set.** `SUCKER_REGISTRY.allSuckersOf(FEE_PROJECT_ID)` is iterated (`src/JBReferralSplitHook.sol:401`), including DEPRECATED entries — not just `suckersOf` which filters them out. Deprecated suckers retain settlement eligibility for in-flight claims, so credit routed through them is bridgeable, not stranded. Without this defense, an attacker could exploit the window between `removeDeprecatedSucker(chainX)` and a replacement deployment to permaburn bridgeable credit.
- **A.5.2 Defensive `try/catch` on `peerChainId()`.** A single fully-broken sucker that reverts on `peerChainId()` is skipped rather than blocking all burns (`src/JBReferralSplitHook.sol:408–414`). A sucker unable to answer `peerChainId` can't bridge anyway, so its chain has no usable route through this sucker — skipping matches the "no settlement path" policy.
- **A.5.3 Reverts if ANY sucker peers to the target chain.** `JBReferralSplitHook_SuckerExistsForChain` is raised on the first match (`src/JBReferralSplitHook.sol:409–411`). The caller must use `bridgeRemote` instead.
- **A.5.4 HWM-before-burn ordering.** `bridgedOutOf[referralChainId][referralProjectId] = alreadyProcessed + deltaToBurn` runs BEFORE `burnTokensOf` (`src/JBReferralSplitHook.sol:438–448`). Reentrancy via the controller cannot grow `delta` because both `totalDeposited` and `feeVolumeByReferralOf` are monotonic.
- **A.5.5 Burns are permanent by design (F-REF-D).** `bridgedOutOf` is a UNIFIED ledger across `bridgeRemote` AND `burnUnbridgeableCreditFor` — there is no separate `burnedOf` slot. A future sucker deployment for the burned chain can only act on INCREMENTAL credit accumulated AFTER the burn — the burned portion stays burned. This trades reversibility for clean dilution prevention; PR Bananapus/nana-referral-split-hook-v6#11 (park-and-retry) was CLOSED — burn-on-strand is the official design. See the `jb-referral-hook-deferral-vs-stranding` skill for the design contract.
- **A.5.6 Same-chain / zero-chain / sentinel rejection.** Mirrors `bridgeRemote`'s guard set (`src/JBReferralSplitHook.sol:379–387`).
- **A.5.7 Sucker iteration is bounded.** The registry's `_suckersOf` keyset for the fee project is typically well under 10 entries (one per active destination chain), so the O(N) external-call iteration is gas-bounded in practice.

---

# Section B — Operator Surface

**There is no operator surface.** `JBReferralSplitHook` has no `Ownable`, no admin role, no pause, no upgrade hook, no fee setting, no per-project configuration, no role assignment after deploy.

All seven constructor immutables — `DIRECTORY`, `STORE`, `TOKENS`, `DISTRIBUTOR`, `SUCKER_REGISTRY`, `TERMINAL`, `FEE_PROJECT_ID` — are wired at construction time and cannot be changed (`src/JBReferralSplitHook.sol:124–143, 187–203`). A wrong value at deploy produces a permanently mis-routed hook; recovery requires re-deploying and updating the fee project's split table to point at the new address (the volume ledger lives on `JBTerminalStore`, not here, so historical credit is preserved across re-deployments — see `ADMINISTRATION.md` "Recovery" section).

The fee project's owner is required upstream to:

1. Queue a ruleset whose reserved-token group includes `{percent: X, hook: thisHook, projectId: 0, beneficiary: address(0)}` so the controller routes the carve-out through `processSplitWith`.
2. Grant the fee project's suckers `MINT_TOKENS` permission so `sucker.claim` can mint destination fee-project tokens to the hook on the destination side (the registry's `deploySuckersFor` grants `DEPLOY_SUCKERS` and `MAP_SUCKER_TOKEN` but NOT `MINT_TOKENS`).

Neither of those is an action the hook itself performs or authorizes — they are pre-conditions on the fee project's ruleset configuration.

---

# Section C — Per-Contract Operation Inventory

`JBReferralSplitHook` is the only contract in this repo.

## C.1 `JBReferralSplitHook` — `src/JBReferralSplitHook.sol`

### Controller-only deposit

- **`processSplitWith(JBSplitHookContext calldata context) external payable`** (`src/JBReferralSplitHook.sol:659–682`) — fee project's controller only. Validates `context.projectId == FEE_PROJECT_ID`, `msg.sender == DIRECTORY.controllerOf(FEE_PROJECT_ID)`, and `context.token == TOKENS.tokenOf(FEE_PROJECT_ID)`. Pulls `context.amount` via `safeTransferFrom(controller, this, amount)` and adds to `totalDeposited`. Reverts: `WrongProject`, `Unauthorized`, `TokenMismatch`. Emits `Deposit`.
  - **Invariants:** A.1.2 (read-only volume ledger), A.1.3 (monotonic `totalDeposited`).
  - **Cannot:** be called by anyone except the fee project's current controller; accept native ETH (reverts on `TokenMismatch` since the reserved-token split is always the fee project's ERC-20).

### Permissionless settle-side entrypoints

- **`pushTo(uint256 referralChainId, uint256 referralProjectId) external → uint256 pushed`** (`src/JBReferralSplitHook.sol:685–744`) — anyone. Reverts: `InvalidReferralProjectId`. Skips (emits `Skipped` and returns 0): cross-chain input, no volume, caught up, no local IJBToken. On success: advances `pushedLocallyOf`, force-approves the distributor, calls `DISTRIBUTOR.fund`, resets approval. Emits `Push`.
  - **Invariants:** A.1.1, A.1.3, A.1.5, A.2.1–A.2.5.

- **`bridgeRemote(uint256 referralChainId, uint256 referralProjectId, IJBSucker sucker, address terminalToken, uint256 minTokensReclaimed) external → uint256 bridged`** (`src/JBReferralSplitHook.sol:230–341`) — anyone. Reverts: `InvalidReferralProjectId`, `ZeroChainId`, `WrongBridgeTarget`, `NotASucker`, `SuckerNotEnabled`, `SuckerPeerMismatch`. Skips (returns 0): no volume, caught up. On success: advances `bridgedOutOf`, force-approves the sucker, calls `sucker.prepare` with leaf metadata `packLeafMetadata(block.chainid, referralProjectId)`, resets approval. Emits `BridgedRemote`.
  - **Invariants:** A.1.1, A.1.3, A.1.5, A.3.1–A.3.9.

- **`burnUnbridgeableCreditFor(uint256 referralChainId, uint256 referralProjectId) external → uint256 burned`** (`src/JBReferralSplitHook.sol:367–453`) — anyone. Reverts: `InvalidReferralProjectId`, `ZeroChainId`, `WrongBridgeTarget`, `SuckerExistsForChain`. Skips (returns 0): no volume, caught up. On success: advances `bridgedOutOf` by `deltaToBurn`, calls `JBController.burnTokensOf({holder: address(this), ..., tokenCount: burned})`. Emits `BurnedUnbridgeable`.
  - **Invariants:** A.1.1, A.1.3, A.1.5, A.5.1–A.5.7.

- **`claimAndPush(uint256 originChainId, uint256 referralProjectId, IJBSucker sucker, JBClaim calldata claimData) external → uint256 pushed`** (`src/JBReferralSplitHook.sol:490–654`) — anyone. Reverts: `InvalidReferralProjectId`, `ZeroChainId`, `OriginIsLocal`, `NotASucker`, `LeafBeneficiaryMismatch`, `LeafMetadataMismatch`, `LeafAlreadySettled`, `FrontRunLeafMismatch`. Skips (emits `Skipped` and returns 0): no local IJBToken for `referralProjectId` (burns instead — A.4.8). On success: either runs `sucker.claim` (normal path) or authenticates against `executedLeafHashOf` (front-run path), measures `feeProjectMinted` by balance delta on normal path or trusts `claimData.leaf.projectTokenCount` on front-run path, sets `settledLeafOf` AFTER the external call, then either burns (no local twin) or forwards via `_fundDistributor`. Emits `ClaimedRemote` always; additionally emits `ClaimedFromFrontRun` on front-run path or `BurnedOnStrand` on burn path.
  - **Invariants:** A.1.5, A.4.1–A.4.9.

### Views (permissionless)

- **`bridgedOutOf(uint256 referralChainId, uint256 referralProjectId) → uint256`** — public mapping getter for the cross-chain HWM (unified across `bridgeRemote` AND `burnUnbridgeableCreditFor`).
- **`pushedLocallyOf(uint256 localReferralProjectId) → uint256`** — public mapping getter for the same-chain HWM.
- **`settledLeafOf(IJBSucker sucker, address terminalToken, uint256 leafIndex) → bool`** — public mapping getter for per-leaf single-settlement.
- **`totalDeposited() → uint256`** — public state getter, cumulative `processSplitWith` deposits.
- **`packLeafMetadata(uint256 originChainId, uint256 referralProjectId) public pure → bytes32`** (`src/JBReferralSplitHook.sol:751–772`) — encodes `(originChainId, referralProjectId)` into the 32-byte leaf metadata. Reverts `ChainIdTooLarge` if `originChainId > type(uint32).max`, `ReferralProjectIdTooLarge` if `referralProjectId > type(uint64).max`. Layout: bits [95:64] = `originChainId` (uint32), bits [63:0] = `referralProjectId` (uint64). Upper 160 bits reserved.
- **`supportsInterface(bytes4 interfaceId) → bool`** — ERC-165 for `IJBSplitHook`, `IJBReferralSplitHook`, and inherited.
- **Immutable getters**: `DIRECTORY`, `DISTRIBUTOR`, `FEE_PROJECT_ID`, `STORE`, `SUCKER_REGISTRY`, `TERMINAL`, `TOKENS` — all public immutables.

### Private helpers (not part of external surface)

- **`_fundDistributor(IJBToken referralToken, uint256 amount) private`** (`src/JBReferralSplitHook.sol:792–798`) — `forceApprove(distributor, amount)` → `DISTRIBUTOR.fund(refToken, feeToken, amount)` → `forceApprove(distributor, 0)`. Used by both `pushTo` and `claimAndPush`.
- **`_pendingDeltaFor(uint256 referralChainId, uint256 referralProjectId, uint256 alreadyProcessed) private → uint256 delta`** (`src/JBReferralSplitHook.sol:809–855`) — the single mulDiv formula. Caller passes its own HWM slot value and writes the new value itself; this lets the same helper drive `pushedLocallyOf` and `bridgedOutOf` without conflating them. Emits `Skipped` on every no-op path (`no volume`, `caught up`).
- **`_toBytes32(address addr) private pure → bytes32`** (`src/JBReferralSplitHook.sol:858–860`) — left-pad an EVM address into a 32-byte beneficiary identifier for sucker leaves.

---

# Section D — Cross-Cutting Invariants

- **D.1 HWM-before-external-call ordering everywhere.** `pushTo` (`src/JBReferralSplitHook.sol:713–716`), `bridgeRemote` (`293–326`), `burnUnbridgeableCreditFor` (`438–448`), and `claimAndPush` for the `settledLeafOf` flag (`591–593`) all advance their write BEFORE invoking the external contract. This is the repo's reentrancy discipline — there is no `ReentrancyGuard` import.
- **D.2 Single-source-of-truth pro-rata math.** `_pendingDeltaFor` is the only place `mulDiv(totalDeposited, refVol, totalVol)` is computed. `pushTo`, `bridgeRemote`, and `burnUnbridgeableCreditFor` all reuse it (Section A.1.1). Adding a fourth settlement path requires reusing this helper too.
- **D.3 Burn-over-strand policy.** Whenever a leaf or credit can never reach a recipient, the hook burns the fee-project tokens rather than holding them. Two paths: cross-chain inbound with no local twin (A.4.8) and cross-chain outbound with no sucker pair (A.5.5). Same-chain credit-only referrers DEFER instead (A.2.1) because the local recipient might tokenize later. This matrix is the design contract — see `jb-referral-hook-deferral-vs-stranding` and `RISKS.md` Section 7.
- **D.4 Burns are permanent across the protocol's lifetime.** Once `bridgedOutOf` advances past a burned amount, no future sucker deployment, governance write, or operator action can un-burn it. The choice is dilution prevention over reversibility. PR #11 (park-and-retry / deferred-claim) was CLOSED — confirmed by the source having no `pokeDeferredClaim` function, no `parkedOf` state, and no `tryReclaimFromBurn`-style entrypoint.
- **D.5 Deprecated suckers are accepted INBOUND but rejected OUTBOUND.** `bridgeRemote` requires `state == ENABLED` (A.3.2); `claimAndPush` does not (A.4.2); `burnUnbridgeableCreditFor` iterates `allSuckersOf` including deprecated entries (A.5.1). This asymmetry reflects the lifecycle: deprecation means "stop accepting new bridges, keep settling pending ones." All three entrypoints implement the matching half.
- **D.6 Per-chain projectId independence.** A numeric `42` on Optimism and a numeric `42` on Base get separate slots in `bridgedOutOf` (A.1.5). Across `pushTo`, `bridgeRemote`, `claimAndPush`, `burnUnbridgeableCreditFor`, and `packLeafMetadata`, the field is always interpreted as the projectId on the referrer's home chain.
- **D.7 Front-run defense via per-leaf hash.** `JBSucker.executedLeafHashOf` is the storage primitive (committed by the sucker on every executed leaf); `claimAndPush` is the consumer that authenticates against it (A.4.5). The pattern is reusable for any other downstream contract that consumes bridged sucker leaves and wants to be safe against permissionless `sucker.claim` front-runs — see the `jb-sucker-claim-front-run-defense` skill.
- **D.8 Allowance reset after every external pull.** Both `bridgeRemote` (`src/JBReferralSplitHook.sol:330`) and `_fundDistributor` (`797`) reset their `forceApprove` to zero after the spender's pull. F-REF-E: defense-in-depth against an underpulling spender leaving a standing allowance.
- **D.9 Sentinel + zero-chain + self-reference rejection everywhere.** `referralProjectId ∈ {0, FEE_PROJECT_ID}`, `referralChainId == 0`, and `referralChainId == block.chainid` (where contextually wrong) revert with distinct named errors across `pushTo`, `bridgeRemote`, `burnUnbridgeableCreditFor`, and `claimAndPush`. No silent accept-and-skip on malformed inputs.
- **D.10 No protocol-level admin, no `Ownable`, no pause.** Section B applies. The only way to "shut down" the hook is for the fee project owner to remove the split from the reserved-token group; the hook's `processSplitWith` will then stop receiving deposits, but existing deposits remain settleable indefinitely via the four permissionless entrypoints.

---

# Section E — Centralization Caveats

**None at the hook layer.** The hook has no owner, no admin, no upgrade hook, no fee setting.

Upstream centralization that affects this hook indirectly:

- **Fee project's controller.** `processSplitWith` accepts deposits only from `DIRECTORY.controllerOf(FEE_PROJECT_ID)`. A controller swap on the fee project (via `JBDirectory.setControllerOf`) moves the deposit authority. In the production V6 deploy, the fee project is project 1 (NANA), owned by `REVOwner`; the controller is `JBController` and is not swappable without REVOwner's cooperation. See `../INVARIANTS.md` Section B.2 ("No control over project ownership") for the broader posture.
- **Sucker registry.** `bridgeRemote` and `claimAndPush` trust `SUCKER_REGISTRY.isSuckerOf` and `SUCKER_REGISTRY.allSuckersOf`. The registry is `Ownable` and owned by `_CRITICAL_INFRA_OWNER` (NANA ops Safe) post-deploy. A compromised registry could allowlist a malicious sucker deployer, who could then deploy a sucker that returns arbitrary `peerChainId` / `state` values and grief routing. See `nana-suckers-v6/INVARIANTS.md` for the registry's own invariants.
- **Distributor.** `pushTo` and `claimAndPush` call `DISTRIBUTOR.fund(refToken, feeToken, amount)`. The distributor's vesting policy lives in `nana-distributor-v6`; the hook does not enforce or rely on any particular vesting cadence.
- **Per-revnet operators.** None of the operator surface in any individual revnet affects this hook. Operators of referrer projects (or the fee project) can rotate splits / buyback / suckers within their own revnet, but they cannot alter `feeVolumeByReferralOf`, `totalDeposited`, or any of this hook's storage.

---

# Section F — Key Code References

| Invariant | File:lines |
|---|---|
| A.1.1, D.2 (single-source-of-truth pro-rata math) | `src/JBReferralSplitHook.sol:809–855` |
| A.1.3 (monotonic HWMs / append-only storage) | `src/JBReferralSplitHook.sol:149–172` |
| A.1.5, D.6 (per-chain projectId independence) | `src/JBReferralSplitHook.sol:150–153, 156–160` |
| A.2.1 (same-chain deferral on no-token) | `src/JBReferralSplitHook.sol:722–732` |
| A.2.2 (cross-chain input skip) | `src/JBReferralSplitHook.sol:697–705` |
| A.2.3, A.3.7, A.5.6, D.9 (sentinel + zero-chain + self-reference rejection) | `src/JBReferralSplitHook.sol:242–253, 379–387, 500–513, 688–690` |
| A.2.4, D.1 (HWM-before-fund in `pushTo`) | `src/JBReferralSplitHook.sol:713–716` |
| A.2.5, A.3.6, D.8 (allowance reset after pull) | `src/JBReferralSplitHook.sol:312, 330, 792–798` |
| A.3.1, A.4.2 (sucker-registration check) | `src/JBReferralSplitHook.sol:257–259, 517–519` |
| A.3.2, D.5 (ENABLED-state check on `bridgeRemote`) | `src/JBReferralSplitHook.sol:266–269` |
| A.3.3 (peer chain match) | `src/JBReferralSplitHook.sol:275–280` |
| A.3.4, D.1 (HWM-before-prepare in `bridgeRemote`) | `src/JBReferralSplitHook.sol:293–326` |
| A.3.8 (leaf metadata binding) | `src/JBReferralSplitHook.sol:305, 751–772` |
| A.3.9 (CREATE2 same-address assumption) | `src/JBReferralSplitHook.sol:317–326` |
| A.4.1 (origin-chain rejection) | `src/JBReferralSplitHook.sol:513` |
| A.4.3 (beneficiary check) | `src/JBReferralSplitHook.sol:524–529` |
| A.4.4 (metadata check) | `src/JBReferralSplitHook.sol:535–539` |
| A.4.5, D.7 (front-run defense via `executedLeafHashOf`) | `src/JBReferralSplitHook.sol:555–573` |
| A.4.6 (per-leaf single-settlement) | `src/JBReferralSplitHook.sol:544–548, 591–593` |
| A.4.7 (balance-delta on normal claim path) | `src/JBReferralSplitHook.sol:585–588` |
| A.4.8, D.3 (burn-on-strand for missing local twin) | `src/JBReferralSplitHook.sol:599–638` |
| A.4.9 (no destination-side HWM write) | `src/JBReferralSplitHook.sol:483–484` (NatSpec) |
| A.5.1, D.5 (iterate `allSuckersOf` for burn-check) | `src/JBReferralSplitHook.sol:401` |
| A.5.2 (defensive `try/catch` on `peerChainId`) | `src/JBReferralSplitHook.sol:408–414` |
| A.5.3 (revert on any peer match) | `src/JBReferralSplitHook.sol:409–411` |
| A.5.4, D.1 (HWM-before-burn) | `src/JBReferralSplitHook.sol:438–448` |
| A.5.5, D.4 (burns permanent / unified `bridgedOutOf` HWM) | `src/JBReferralSplitHook.sol:428–437` |
| B (constructor immutables, no admin) | `src/JBReferralSplitHook.sol:124–143, 187–203` |
| C.1 controller-only `processSplitWith` | `src/JBReferralSplitHook.sol:659–682` |
| C.1 `packLeafMetadata` field widths | `src/JBReferralSplitHook.sol:751–772` |

---

# Doc audit notes

Audit pass over the nine top-level docs:

- **README.md** — current; mental model and key-state summary match the contract. The top-of-file "Documentation" section enumerates every sibling doc.
- **ARCHITECTURE.md** — current; the four routing destinations (push / bridge / claim / burn) align with the source. Fixed: the `burnUnbridgeableCreditFor` flow correctly references `allSuckersOf` (the contract iterates the full set including DEPRECATED entries, not just `suckersOf`).
- **RISKS.md** — current; Section 7 ("Accepted Behaviors") is the canonical deferral-vs-stranding contract that this INVARIANTS.md implements operationally, and Section 8 ("Front-Run Protection For `claimAndPush`") is the threat-model rationale for Section A.4.5 here. Fixed: 7.1 no longer reads as implying a future "deferred design" recycle path (there is none — burn-on-strand is the only recovery for cross-chain dust; same-chain dust waits on referrer tokenization).
- **USER_JOURNEYS.md** — current; trust-boundary and journey-2 preconditions reference `allSuckersOf` to match the contract.
- **ADMINISTRATION.md** — current; the no-admin / no-pause / no-upgrade posture matches Section B.
- **AUDIT_INSTRUCTIONS.md** — current; out-of-scope list references `isSuckerOf` / `allSuckersOf` to match the contract's actual registry surface.
- **SKILLS.md** — refreshed; now reflects the full entrypoint set (`bridgeRemote`, `claimAndPush`, `burnUnbridgeableCreditFor`), the seven constructor immutables, the burn-vs-defer-vs-revert matrix, and the front-run defense. The codified skills (`jb-referral-hook-deferral-vs-stranding`, `jb-sucker-claim-front-run-defense`) remain the canonical pattern docs.
- **CHANGELOG.md** — current; historical 0.0.4 entry preserves the original `suckersOf` wording from that release (the code later changed to `allSuckersOf` as part of the F-REF-* harden sweep; current behavior is documented in ARCHITECTURE.md and SKILLS.md).
- **STYLE_GUIDE.md** — repo-internal style ref, unaffected.

PR Bananapus/nana-referral-split-hook-v6#11 ("park-and-retry / `pokeDeferredClaim`") was CLOSED — confirmed by absence of `pokeDeferredClaim`, `parkedOf`, or any deferred-claim entrypoint in `src/JBReferralSplitHook.sol`. Burn-on-strand (`claimAndPush` burning on missing local twin, `burnUnbridgeableCreditFor` for unbridgeable cross-chain credit) is the official design — no doc implies otherwise.
