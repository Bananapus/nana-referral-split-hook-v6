// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";
import {JBSuckerState} from "@bananapus/suckers-v6/src/enums/JBSuckerState.sol";
import {IJBSucker} from "@bananapus/suckers-v6/src/interfaces/IJBSucker.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBClaim} from "@bananapus/suckers-v6/src/structs/JBClaim.sol";

import {IJBReferralSplitHook} from "./interfaces/IJBReferralSplitHook.sol";

/// @notice A split hook on the fee project's reserved-token group that pools incoming fee-project tokens and
/// forwards each referring project's pro-rata share into a configured `IJBDistributor`.
/// @dev Referrers are identified by the `(referralChainId, referralProjectId)` pair recorded in
/// `JBTerminalStore.feeVolumeByReferralOf`. Same-chain referrers are pushed to the local distributor by
/// `pushTo`. Cross-chain referrers are bridged through the fee project's sucker by `bridgeRemote` and
/// atomically settled on the home chain by `claimAndPush` — the leaf's `metadata` field carries
/// `(originChainId, referralProjectId)` so the receiving hook knows exactly which local-twin project the
/// bridged credit is for, all under the merkle proof's authentication.
/// @dev The volume ratio comes from
/// `STORE.feeVolumeByReferralOf(TERMINAL, chainId, projectId) / STORE.totalFeeVolumeOf(TERMINAL)`. The
/// vesting + claim mechanics live downstream in the distributor.
contract JBReferralSplitHook is ERC165, IJBReferralSplitHook {
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // ----------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @inheritdoc IJBReferralSplitHook
    IJBDirectory public immutable override DIRECTORY;

    /// @inheritdoc IJBReferralSplitHook
    IJBDistributor public immutable override DISTRIBUTOR;

    /// @inheritdoc IJBReferralSplitHook
    uint256 public immutable override FEE_PROJECT_ID;

    /// @inheritdoc IJBReferralSplitHook
    IJBTerminalStore public immutable override STORE;

    /// @inheritdoc IJBReferralSplitHook
    IJBSuckerRegistry public immutable override SUCKER_REGISTRY;

    /// @inheritdoc IJBReferralSplitHook
    address public immutable override TERMINAL;

    /// @inheritdoc IJBReferralSplitHook
    IJBTokens public immutable override TOKENS;

    //*********************************************************************//
    // ---------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @inheritdoc IJBReferralSplitHook
    /// @dev Keyed by `(referralChainId, referralProjectId)` where `referralProjectId` is the referrer's
    /// projectId *on `referralChainId`* — projectId spaces are independent per chain, so the same numeric
    /// projectId on two different chains represents two different projects and gets two independent budgets.
    mapping(uint256 referralChainId => mapping(uint256 referralProjectId => uint256)) public override bridgedOutOf;

    /// @inheritdoc IJBReferralSplitHook
    /// @dev Keyed by the referrer's projectId on `block.chainid`. The local high-water mark for same-chain
    /// pushes. Separate from `bridgedOutOf` because the two have different semantics: this slot tracks
    /// distributor forwards, the other tracks bridge outflows. Conflating them under one mapping made the
    /// storage hard to reason about for off-chain indexers.
    mapping(uint256 localReferralProjectId => uint256) public override pushedLocallyOf;

    /// @inheritdoc IJBReferralSplitHook
    /// @dev Indexed by `(sucker, terminalToken, leafIndex)`. `true` means `claimAndPush` has already processed
    /// this leaf — either via the normal `sucker.claim` path or via the front-run path (where an external
    /// `sucker.claim` consumed the leaf before us). Each leaf can only legitimately fund one referrer
    /// settlement, so subsequent calls revert.
    mapping(IJBSucker sucker => mapping(address terminalToken => mapping(uint256 leafIndex => bool)))
        public
        override settledLeafOf;

    /// @inheritdoc IJBReferralSplitHook
    uint256 public override totalDeposited;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory The directory used to authenticate `processSplitWith` and resolve the fee project's
    /// primary terminal on this chain.
    /// @param store The terminal store that publishes the per-referrer fee volume ledger.
    /// @param tokens The tokens registry used to resolve the fee project's and referrers' project tokens.
    /// @param distributor The distributor that receives forwarded per-referrer shares.
    /// @param suckerRegistry The sucker registry used to authenticate suckers passed to `bridgeRemote` and
    /// `claimAndPush`.
    /// @param terminal The terminal whose `JBTerminalStore` volume ledger this hook reads from.
    /// @param feeProjectId The project ID receiving fees (typically project 1).
    constructor(
        IJBDirectory directory,
        IJBTerminalStore store,
        IJBTokens tokens,
        IJBDistributor distributor,
        IJBSuckerRegistry suckerRegistry,
        address terminal,
        uint256 feeProjectId
    ) {
        DIRECTORY = directory;
        STORE = store;
        TOKENS = tokens;
        DISTRIBUTOR = distributor;
        SUCKER_REGISTRY = suckerRegistry;
        TERMINAL = terminal;
        FEE_PROJECT_ID = feeProjectId;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Bridge a cross-chain referrer's accrued pro-rata share through the fee project's sucker.
    /// @dev Permissionless. Cashes out the entitled fee-project tokens via `sucker.prepare`, which (for sucker
    /// holders on omnichain revnets) pays 0% cash-out tax — the bridge is loss-free in fee-project-token
    /// terms. The leaf's `metadata` field is set to `(originChainId, referralProjectId)` so the sibling hook
    /// on `referralChainId` can atomically settle via `claimAndPush`.
    /// @dev Reverts if the sucker isn't a registered, ENABLED sucker of the fee project. Reverts if the
    /// sucker's `peerChainId()` doesn't match `referralChainId`. Skips (without reverting) on the usual
    /// no-volume / caught-up cases. `referralChainId` must not equal `block.chainid` (use `pushTo`).
    /// @dev Slippage: the caller picks `minTokensReclaimed` and the hook passes it through to
    /// `sucker.prepare`. Passing `0` leaves the bonding-curve cash-out exposed to MEV sandwich attacks; the
    /// hook is permissionless so the caller bears that responsibility.
    /// @dev Approvals: `forceApprove(sucker, bridged)` precedes `prepare`; the residual allowance is reset to
    /// zero after the call so an underpulling sucker can't outlive its grant on a later call.
    /// @param referralChainId The referrer's home EIP-155 chain ID. Must NOT equal `block.chainid`.
    /// @param referralProjectId The referring project on that chain.
    /// @param sucker The fee project's sucker pair to use; must bridge to `referralChainId`, be registered,
    /// and be `JBSuckerState.ENABLED`.
    /// @param terminalToken The terminal token to cash out into. Must be mapped on the sucker.
    /// @param minTokensReclaimed The caller's minimum acceptable terminal-token reclaim — slippage bound on
    /// the bonding-curve cash-out leg inside `sucker.prepare`.
    /// @return bridged The number of fee-project tokens cashed out into the sucker (0 on skip).
    function bridgeRemote(
        uint256 referralChainId,
        uint256 referralProjectId,
        IJBSucker sucker,
        address terminalToken,
        uint256 minTokensReclaimed
    )
        external
        override
        returns (uint256 bridged)
    {
        // Sentinel + self-reference + cross-chain-only guards.
        if (referralProjectId == 0 || referralProjectId == FEE_PROJECT_ID) {
            revert JBReferralSplitHook_InvalidReferralProjectId();
        }
        // EIP-155 chain ids are strictly positive; rejecting 0 explicitly stops a caller from constructing a
        // call that would otherwise rely on the downstream `peerChainId()` returning a different value to
        // revert with `SuckerPeerMismatch`. Defense in depth: ban it here so the failure mode is unambiguous.
        if (referralChainId == 0) revert JBReferralSplitHook_ZeroChainId();
        if (referralChainId == block.chainid) {
            revert JBReferralSplitHook_WrongBridgeTarget({
                expectedChainId: referralChainId, actualChainId: block.chainid
            });
        }

        // The sucker must be a registered sucker of the fee project, otherwise an attacker could direct value
        // into a sucker that doesn't lead to the right remote chain (or doesn't lead anywhere at all).
        if (!SUCKER_REGISTRY.isSuckerOf({projectId: FEE_PROJECT_ID, addr: address(sucker)})) {
            revert JBReferralSplitHook_NotASucker({sucker: address(sucker)});
        }

        // F-REF-B: reject deprecated suckers explicitly. `isSuckerOf` returns true for both active AND
        // deprecated entries — the deprecated set retains registration so pending inbound claims can settle
        // on the destination chain. Outbound bridges from a deprecated sucker would revert deep inside
        // `prepare` (after our allowance is set) AND would muddy the ledger if it later races a
        // freshly-deployed replacement. Fail loud at the boundary.
        JBSuckerState state = sucker.state();
        if (state != JBSuckerState.ENABLED) {
            revert JBReferralSplitHook_SuckerNotEnabled({sucker: address(sucker), state: state});
        }

        // Registration alone says the sucker is *some* fee-project sucker — it doesn't say which chain it
        // bridges to. Verify the sucker's peer is on `referralChainId`, otherwise a caller could route a
        // referrer's credit through the wrong omnichain leg (e.g. credit owed to a project on Optimism gets
        // bridged to Base and pushed to whatever local twin shares the bare projectId there).
        uint256 actualPeerChainId = sucker.peerChainId();
        if (actualPeerChainId != referralChainId) {
            revert JBReferralSplitHook_SuckerPeerMismatch({
                expectedPeerChainId: referralChainId, actualPeerChainId: actualPeerChainId
            });
        }

        uint256 alreadyBridged = bridgedOutOf[referralChainId][referralProjectId];
        uint256 deltaToProcess = _pendingDeltaFor({
            referralChainId: referralChainId, referralProjectId: referralProjectId, alreadyProcessed: alreadyBridged
        });
        if (deltaToProcess == 0) return 0;

        // Advance the high-water mark BEFORE the sucker call so reentrancy can't double-bridge.
        // `bridgedOutOf` tracks outbound bridge volume per `(referralChainId, referralProjectId)`; it is
        // INDEPENDENT of `pushedLocallyOf` — each chain bears separate ledgers because projectId spaces are
        // independent per chain (a numeric `42` on Optimism and a numeric `42` on Base are unrelated
        // projects).
        unchecked {
            bridgedOutOf[referralChainId][referralProjectId] = alreadyBridged + deltaToProcess;
        }

        bridged = deltaToProcess;

        // Tag the leaf with `(originChainId, referralProjectId)` so the sibling hook on `referralChainId`
        // knows which local-twin project to settle to when it calls `claimAndPush`. `referralProjectId` here
        // is the projectId AS IT EXISTS on `referralChainId` — the source's `feeVolumeByReferralOf` ledger
        // keys this way too, and the destination's `TOKENS.tokenOf(referralProjectId)` lookup uses the
        // destination's registry. The convention is unambiguous: across the whole pipeline, this field always
        // refers to the projectId on the referrer's home chain.
        bytes32 leafMetadata = packLeafMetadata({originChainId: block.chainid, referralProjectId: referralProjectId});

        // Approve the sucker for exactly `bridged` fee-project tokens. The sucker pulls via `safeTransferFrom`
        // inside `prepare`, then cashes them out via the source terminal (0% tax for sucker holders on
        // omnichain revnets) and adds a leaf to the outbox tree.
        IJBToken feeToken = TOKENS.tokenOf(FEE_PROJECT_ID);
        IERC20 feeERC20 = IERC20(address(feeToken));
        feeERC20.forceApprove({spender: address(sucker), value: bridged});

        // F-REF-2: pass through caller-supplied slippage to bound the bonding-curve cash-out leg. Callers
        // MUST size `minTokensReclaimed` against current pool depth; the hook is permissionless so each
        // caller picks their own MEV/sandwich tolerance.
        // Beneficiary is the sibling hook on the remote chain. We rely on the deploy convention that
        // `JBReferralSplitHook` is CREATE2-deployed at the same address across chains, so `address(this)`
        // here equals the address that will receive the bridged terminal tokens on `referralChainId`.
        sucker.prepare({
            projectTokenCount: bridged,
            beneficiary: _toBytes32(address(this)),
            minTokensReclaimed: minTokensReclaimed,
            token: terminalToken,
            metadata: leafMetadata
        });

        // F-REF-E: reset residual allowance. `prepare` pulls via `safeTransferFrom`; if it underpulls (it
        // shouldn't, but defense-in-depth), a non-zero allowance would otherwise outlive this call.
        feeERC20.forceApprove({spender: address(sucker), value: 0});

        emit BridgedRemote({
            referralChainId: referralChainId,
            referralProjectId: referralProjectId,
            sucker: sucker,
            terminalToken: terminalToken,
            amount: bridged,
            leafMetadata: leafMetadata,
            caller: msg.sender
        });
    }

    /// @notice Burn the accumulated cross-chain referral credit for `(referralChainId, referralProjectId)`
    /// when NO sucker pair for the fee project peers to `referralChainId` — i.e. the credit is unbridgeable.
    /// @dev Permissionless. Burning here means: the entitled fee-project tokens for this referrer pair are
    /// removed from supply, returning the bridged terminal-token value (already in the fee project's balance
    /// from the original protocol-fee flow) to all existing fee-token holders pro-rata. This is the
    /// cross-chain analog of `claimAndPush`'s burn-on-strand path.
    /// @dev F-REF-A: iterates `SUCKER_REGISTRY.allSuckersOf(FEE_PROJECT_ID)` — every sucker the registry has
    /// ever recorded for the fee project, ACTIVE or DEPRECATED. Reverts with `SuckerExistsForChain` if any
    /// such sucker peers to `referralChainId`. Deprecated suckers retain settlement eligibility, so credit
    /// routed through them is NOT stranded; an attacker who tried to permaburn it via the
    /// `removeDeprecatedSucker → burn → new-sucker-deployment` race would be blocked here.
    /// @dev `peerChainId()` is wrapped in `try/catch` so a single fully-broken sucker can't permanently block
    /// burns of unrelated chains' credit. A sucker that can't answer `peerChainId` can't bridge anyway, so
    /// skipping it preserves the "no settlement path" policy.
    /// @dev Reverts on the usual malformed-args cases (`projectId == 0 || projectId == FEE_PROJECT_ID`,
    /// `chainId == 0`, `chainId == block.chainid`). Skips (without reverting) when there's nothing to burn
    /// (no recorded volume, or the high-water mark is already caught up).
    /// @dev Advances `bridgedOutOf` by the burned amount so the burn is idempotent AND so a future sucker
    /// deployment for `referralChainId` can only bridge INCREMENTAL credit accumulated after the burn — the
    /// burned portion stays burned (F-REF-D: burns are permanent by design).
    /// @param referralChainId The referrer's home EIP-155 chain ID. Must NOT equal `block.chainid`. Must NOT
    /// have a sucker pair (active or deprecated) on the fee project.
    /// @param referralProjectId The referring project on that chain.
    /// @return burned The number of fee-project tokens burned (0 on skip).
    function burnUnbridgeableCreditFor(
        uint256 referralChainId,
        uint256 referralProjectId
    )
        external
        override
        returns (uint256 burned)
    {
        // Same malformed-arg guards as `bridgeRemote` — a `chainId == block.chainid` credit isn't a
        // cross-chain case at all (and same-chain credits with no destination ERC-20 are deferred via
        // `pushTo`, not burned here), `chainId == 0` is invalid EIP-155, and
        // `projectId == 0 || projectId == FEE_PROJECT_ID` are sentinel/self-reference cases.
        if (referralProjectId == 0 || referralProjectId == FEE_PROJECT_ID) {
            revert JBReferralSplitHook_InvalidReferralProjectId();
        }
        if (referralChainId == 0) revert JBReferralSplitHook_ZeroChainId();
        if (referralChainId == block.chainid) {
            revert JBReferralSplitHook_WrongBridgeTarget({
                expectedChainId: referralChainId, actualChainId: block.chainid
            });
        }

        // Stranding-vs-bridgeable check: verify that NO sucker (active OR deprecated) for the fee project
        // peers to `referralChainId`. If even one does, the credit is BRIDGEABLE and the caller must use
        // `bridgeRemote` (which routes value to the rightful referrer on `referralChainId`) instead of
        // destroying it.
        //
        // F-REF-A: we iterate `allSuckersOf` rather than `suckersOf` — deprecated suckers retain mint
        // permission so pending claims can settle, and an attacker could otherwise burn bridgeable credit in
        // the window between `removeDeprecatedSucker` and a replacement deployment. We pessimistically
        // include deprecated entries so the burn only proceeds when no settlement path exists at all.
        //
        // The registry's `_suckersOf` keyset is bounded (typically << 10 entries per project), so this loop
        // is gas-bounded in practice.
        address[] memory suckers = SUCKER_REGISTRY.allSuckersOf(FEE_PROJECT_ID);
        uint256 suckerCount = suckers.length;
        for (uint256 i; i < suckerCount;) {
            // Defensive try/catch: a sucker that can't answer `peerChainId` can't bridge anyway. Without
            // this guard, a single fully-broken sucker would permanently block burns for ALL chains.
            // Skipping matches the policy — if the sucker is unable to bridge, its peer chain (whatever it
            // might have been) has no usable route through this sucker.
            try IJBSucker(suckers[i]).peerChainId() returns (uint256 peer) {
                if (peer == referralChainId) {
                    revert JBReferralSplitHook_SuckerExistsForChain({sucker: suckers[i], chainId: referralChainId});
                }
            } catch {
                // Skip: this sucker is unusable.
            }
            unchecked {
                ++i;
            }
        }

        // The entitled delta is computed the same way `bridgeRemote` would — pro-rata against
        // `feeVolumeByReferralOf` over `totalFeeVolumeOf`, minus what was already processed.
        uint256 alreadyProcessed = bridgedOutOf[referralChainId][referralProjectId];
        uint256 deltaToBurn = _pendingDeltaFor({
            referralChainId: referralChainId, referralProjectId: referralProjectId, alreadyProcessed: alreadyProcessed
        });
        if (deltaToBurn == 0) return 0;

        // BURNS ARE PERMANENT BY DESIGN (F-REF-D). `bridgedOutOf` is a unified HWM across bridge AND burn —
        // there is intentionally NO separate `burnedOf` ledger. Rationale: if burned credit could later be
        // "un-burned" when a sucker is deployed for the chain, every existing fee-project token holder would
        // suffer ongoing dilution from credit that has no deliverable settlement path right now. We trade
        // reversibility for clean dilution prevention. See `jb-referral-hook-deferral-vs-stranding`.
        //
        // Advance the HWM BEFORE the burn so a future `bridgeRemote` call (if a sucker is later deployed)
        // can only act on INCREMENTAL credit accumulated after this burn — the burned portion is gone for
        // good. Reentrancy via the controller can't grow `delta` because `totalDeposited` and
        // `feeVolumeByReferralOf` are monotonic.
        unchecked {
            bridgedOutOf[referralChainId][referralProjectId] = alreadyProcessed + deltaToBurn;
        }

        burned = deltaToBurn;

        // Burn the equivalent fee-project tokens from this hook's balance. `holder == msg.sender ==
        // address(this)`, so JBController's permission check passes automatically (callers can always burn
        // their own tokens).
        IJBController(address(DIRECTORY.controllerOf(FEE_PROJECT_ID)))
            .burnTokensOf({holder: address(this), projectId: FEE_PROJECT_ID, tokenCount: burned, memo: ""});

        emit BurnedUnbridgeable({
            referralChainId: referralChainId, referralProjectId: referralProjectId, amount: burned, caller: msg.sender
        });
    }

    /// @notice Atomically claim a bridged credit and push it to the local distributor for the referrer's
    /// local-twin project on this chain.
    /// @dev Permissionless. Validates input shape, beneficiary, and metadata; then either runs the normal
    /// `sucker.claim(...)` path (when the leaf is unexecuted) or the front-run-recovery path (when the leaf
    /// was already consumed by a direct external `sucker.claim` call before us).
    /// @dev FRONT-RUN DEFENSE. `sucker.claim` is permissionless — any third party with a valid merkle proof
    /// can call it, consuming the leaf and minting the fee-project tokens to the leaf's beneficiary (= this
    /// hook). The naive "check the executed bitmap and trust caller's claimData if executed" is exploitable
    /// because the bitmap proves *some* leaf at index `I` was executed, not *which* leaf. To authenticate,
    /// the hook queries `sucker.executedLeafHashOf(token, index)`; if non-zero, the leaf was already
    /// executed, and the hook re-derives the same hash from the caller's claimData via
    /// `keccak256(abi.encodePacked(projectTokenCount, terminalTokenAmount, beneficiary, metadata))`. A
    /// match proves the caller's data corresponds to the actually-executed leaf; fabricated claimData with
    /// the same index but tampered fields produces a different hash and reverts with
    /// `FrontRunLeafMismatch`.
    /// @dev Per-leaf idempotency is enforced by `settledLeafOf[sucker][token][index]`. The flag is set AFTER
    /// any external `sucker.claim` call so stale-proof reverts in the normal path don't leave the leaf
    /// permanently un-settleable — the caller can retry with a fresh proof. Re-settling a successfully
    /// claimed leaf reverts with `LeafAlreadySettled`.
    /// @dev VALUE PRESERVATION (F-REF-C): the sucker's mint/cashout is value-symmetric. On the origin side N
    /// fee-project tokens were burned to extract `terminalTokenAmount` from the fee project's surplus; on
    /// this side, `terminalTokenAmount` is deposited back into the fee project's surplus AND N fee-project
    /// tokens are minted to this hook. Net per-token claim on surplus is unchanged; the referrer receives
    /// fee-project tokens (not raw terminal tokens) but the underlying economic value matches.
    /// @dev BURN-ON-STRAND: if the local twin's `TOKENS.tokenOf(referralProjectId) == address(0)` (no ERC-20
    /// minted yet), the freshly-minted fee-project tokens are burned rather than left in the hook. The leaf
    /// is single-use and is now consumed; holding the supply would permanently dilute existing holders for
    /// no recipient.
    /// @dev No `bridgedOutOf` / `pushedLocallyOf` write here — both ledgers track the *source* side of work
    /// this hook initiated, not destinations of bridges initiated by other chains' hooks.
    /// @param originChainId The chain the credit was originally earned on. Must NOT equal `block.chainid`.
    /// @param referralProjectId The local twin's project ID on this chain.
    /// @param sucker The fee project's sucker pair the claim belongs to.
    /// @param claimData The terminal token, leaf, and merkle proof from the bridge.
    /// @return pushed The number of fee-project tokens forwarded to the local distributor (0 on burn-on-strand).
    function claimAndPush(
        uint256 originChainId,
        uint256 referralProjectId,
        IJBSucker sucker,
        JBClaim calldata claimData
    )
        external
        override
        returns (uint256 pushed)
    {
        if (referralProjectId == 0 || referralProjectId == FEE_PROJECT_ID) {
            revert JBReferralSplitHook_InvalidReferralProjectId();
        }

        // EIP-155 chain ids are strictly positive; the proof's `_inboxOf[token].root` would never
        // legitimately contain a leaf claiming to originate from chain 0, but rejecting up front gives a
        // precise error before any external call.
        if (originChainId == 0) revert JBReferralSplitHook_ZeroChainId();

        // A bridged claim must come from a *different* chain. Self-bridging is impossible (`bridgeRemote`
        // already rejects it), but block it explicitly here so a caller can't construct a synthetic
        // local-chain leaf and route it through this entrypoint to skip the same-chain `pushTo`
        // high-water-mark accounting.
        if (originChainId == block.chainid) revert JBReferralSplitHook_OriginIsLocal(block.chainid);

        // The sucker must be a registered sucker of the fee project — this is how we know the bridged
        // tokens came from a hook on a chain that's part of the same fee-project omnichain identity.
        if (!SUCKER_REGISTRY.isSuckerOf({projectId: FEE_PROJECT_ID, addr: address(sucker)})) {
            revert JBReferralSplitHook_NotASucker({sucker: address(sucker)});
        }

        // The bridged tokens must be addressed to us. The sucker's merkle proof would catch a tampered
        // leaf, but checking the beneficiary explicitly catches a mismatched-claim-data call before we
        // touch state.
        bytes32 expectedBeneficiary = _toBytes32(address(this));
        if (claimData.leaf.beneficiary != expectedBeneficiary) {
            revert JBReferralSplitHook_LeafBeneficiaryMismatch({
                expected: expectedBeneficiary, got: claimData.leaf.beneficiary
            });
        }

        // The merkle proof inside `sucker.claim` will validate `claimData.leaf.metadata`; we enforce that
        // the asserted `(originChainId, referralProjectId)` pair matches the leaf's metadata here so a
        // caller can't substitute the projectId argument and redirect bridged tokens to a different local
        // distributor.
        bytes32 expectedMetadata =
            packLeafMetadata({originChainId: originChainId, referralProjectId: referralProjectId});
        if (claimData.leaf.metadata != expectedMetadata) {
            revert JBReferralSplitHook_LeafMetadataMismatch({expected: expectedMetadata, got: claimData.leaf.metadata});
        }

        // Idempotency: the `settledLeafOf` flag is written AFTER the (potentially-reverting) `sucker.claim`
        // call below, so a stale proof can be retried with a fresh one. But re-settling the same
        // successfully claimed leaf reverts.
        if (settledLeafOf[sucker][claimData.token][claimData.leaf.index]) {
            revert JBReferralSplitHook_LeafAlreadySettled({
                sucker: address(sucker), terminalToken: claimData.token, leafIndex: claimData.leaf.index
            });
        }

        // The sucker's `_handleClaim` deposits `terminalTokenAmount` into the *fee project's* primary
        // terminal (rebuilding its balance after the source-side cash-out) and then mints
        // `projectTokenCount` fee-project tokens to the beneficiary — which is this hook. We don't receive
        // terminal tokens; we receive freshly minted fee-project tokens.
        uint256 feeProjectMinted;
        bytes32 storedHash = sucker.executedLeafHashOf(claimData.token, claimData.leaf.index);

        if (storedHash != bytes32(0)) {
            // Front-run path: leaf already executed by a third party. Tokens already in our balance from
            // that earlier mint. Authenticate caller's claimData by re-deriving the leaf hash; the sucker's
            // `_buildTreeHash` packs the four 32-byte words contiguously and `keccak256`s them, which is
            // byte-identical to `abi.encodePacked(uint256, uint256, bytes32, bytes32)` because all four
            // operands are word-sized (no `abi.encodePacked` padding ambiguity).
            bytes32 expectedHash = keccak256(
                abi.encodePacked(
                    claimData.leaf.projectTokenCount,
                    claimData.leaf.terminalTokenAmount,
                    claimData.leaf.beneficiary,
                    claimData.leaf.metadata
                )
            );
            if (storedHash != expectedHash) {
                revert JBReferralSplitHook_FrontRunLeafMismatch({expected: expectedHash, stored: storedHash});
            }
            feeProjectMinted = claimData.leaf.projectTokenCount;
            emit ClaimedFromFrontRun({
                originChainId: originChainId,
                referralProjectId: referralProjectId,
                leafIndex: claimData.leaf.index,
                feeProjectMinted: feeProjectMinted,
                caller: msg.sender
            });
        } else {
            // Normal path. Snapshot to measure exactly what arrived (rather than trusting the leaf field at
            // face value), then forward to the local distributor.
            IJBToken localFeeToken = TOKENS.tokenOf(FEE_PROJECT_ID);
            uint256 feeProjectBalanceBefore = IERC20(address(localFeeToken)).balanceOf(address(this));
            sucker.claim(claimData);
            feeProjectMinted = IERC20(address(localFeeToken)).balanceOf(address(this)) - feeProjectBalanceBefore;
        }

        // Mark this leaf as settled AFTER any external `sucker.claim` call so a stale-proof revert leaves
        // the flag unset and the caller can retry with a fresh proof.
        settledLeafOf[sucker][claimData.token][claimData.leaf.index] = true;

        // Forward the freshly-minted fee-project tokens to the local distributor for the asserted
        // referrer's local twin (`referralProjectId` is the local twin's projectId on `block.chainid` —
        // independent of any numerically-matching projectId on `originChainId`, since projectId spaces are
        // per-chain).
        IJBToken refToken = TOKENS.tokenOf(referralProjectId);
        if (address(refToken) == address(0)) {
            // BURN-OVER-STRAND: the sucker's `_handleClaim` already deposited the bridged terminal tokens
            // into the fee project's balance AND minted us fee-project tokens. The leaf is now consumed
            // (executed-bitmap set on the sucker), so there's no future settlement that can use these
            // freshly-minted tokens. Holding them in this hook would strand value indefinitely. Burning
            // them here keeps the bridged terminal-token value intact in the fee project's balance but
            // returns the offsetting supply to zero, so every existing fee-project token holder's pro-rata
            // claim on the new surplus grows. `holder == msg.sender == address(this)` so JBController's
            // permission check passes automatically.
            if (feeProjectMinted != 0) {
                IJBController(address(DIRECTORY.controllerOf(FEE_PROJECT_ID)))
                    .burnTokensOf({
                    holder: address(this), projectId: FEE_PROJECT_ID, tokenCount: feeProjectMinted, memo: ""
                });
                emit BurnedOnStrand({
                    originChainId: originChainId,
                    referralProjectId: referralProjectId,
                    feeProjectBurned: feeProjectMinted,
                    caller: msg.sender
                });
            } else {
                emit Skipped({
                    referralChainId: block.chainid,
                    referralProjectId: referralProjectId,
                    reason: "no token",
                    caller: msg.sender
                });
            }
            emit ClaimedRemote({
                originChainId: originChainId,
                referralProjectId: referralProjectId,
                terminalToken: claimData.token,
                terminalReceived: claimData.leaf.terminalTokenAmount,
                feeProjectMinted: feeProjectMinted,
                pushed: 0,
                caller: msg.sender
            });
            return 0;
        }

        pushed = feeProjectMinted;
        if (pushed != 0) {
            _fundDistributor({referralToken: refToken, amount: pushed});
        }

        emit ClaimedRemote({
            originChainId: originChainId,
            referralProjectId: referralProjectId,
            terminalToken: claimData.token,
            terminalReceived: claimData.leaf.terminalTokenAmount,
            feeProjectMinted: feeProjectMinted,
            pushed: pushed,
            caller: msg.sender
        });
    }

    /// @notice Receive a slice of the fee project's reserved-token distribution. Only callable by the fee
    /// project's controller when distributing the fee project's reserved tokens.
    /// @param context The split hook context provided by the calling controller.
    function processSplitWith(JBSplitHookContext calldata context) external payable override {
        // Auth: caller must be the fee project's controller, and the split must belong to the fee project.
        if (context.projectId != FEE_PROJECT_ID) {
            revert JBReferralSplitHook_WrongProject({expected: FEE_PROJECT_ID, got: context.projectId});
        }
        if (address(DIRECTORY.controllerOf(FEE_PROJECT_ID)) != msg.sender) {
            revert JBReferralSplitHook_Unauthorized({projectId: FEE_PROJECT_ID, caller: msg.sender});
        }

        // Verify the token matches the fee project's project token. Reserved-token splits never carry
        // native ETH; we always expect an ERC-20 here.
        IJBToken feeToken = TOKENS.tokenOf(FEE_PROJECT_ID);
        if (address(feeToken) != context.token) {
            revert JBReferralSplitHook_TokenMismatch({expected: address(feeToken), got: context.token});
        }

        // Pull tokens via the allowance the controller granted us immediately before this call.
        IERC20(context.token).safeTransferFrom({from: msg.sender, to: address(this), value: context.amount});
        unchecked {
            totalDeposited += context.amount;
        }

        emit Deposit({amount: context.amount, newTotalDeposited: totalDeposited, caller: msg.sender});
    }

    /// @inheritdoc IJBReferralSplitHook
    function pushTo(uint256 referralChainId, uint256 referralProjectId) external override returns (uint256 pushed) {
        // Reject the two sentinel/self-reference cases on the projectId axis. Chain ID can be anything (the
        // cross-chain skip is handled below).
        if (referralProjectId == 0 || referralProjectId == FEE_PROJECT_ID) {
            revert JBReferralSplitHook_InvalidReferralProjectId();
        }

        // Cross-chain referrers must use `bridgeRemote`. This skip keeps `pushTo` strictly the same-chain
        // path. Note: `referralProjectId` is interpreted as the projectId *on the referrer's home chain* —
        // projectId spaces are independent per chain, so for `referralChainId == block.chainid` this is the
        // local projectId; for any other chain it identifies a project in that chain's registry and we must
        // not attempt a local lookup with it.
        if (referralChainId != block.chainid) {
            emit Skipped({
                referralChainId: referralChainId,
                referralProjectId: referralProjectId,
                reason: "remote",
                caller: msg.sender
            });
            return 0;
        }

        uint256 alreadyPushed = pushedLocallyOf[referralProjectId];
        uint256 deltaToProcess = _pendingDeltaFor({
            referralChainId: referralChainId, referralProjectId: referralProjectId, alreadyProcessed: alreadyPushed
        });
        if (deltaToProcess == 0) return 0;

        // Advance the high-water mark BEFORE the external token transfer so reentrancy can't double-spend.
        unchecked {
            pushedLocallyOf[referralProjectId] = alreadyPushed + deltaToProcess;
        }

        // Resolve the referring project's IVotes token on this chain. Credit-only projects (no ERC-20)
        // cannot receive a push — roll the high-water mark back so the next `pushTo` retries once the
        // referrer tokenizes (the share stays pending in this hook's balance, accumulating with future
        // deposits).
        IJBToken refToken = TOKENS.tokenOf(referralProjectId);
        if (address(refToken) == address(0)) {
            pushedLocallyOf[referralProjectId] = alreadyPushed;
            emit Skipped({
                referralChainId: referralChainId,
                referralProjectId: referralProjectId,
                reason: "no token",
                caller: msg.sender
            });
            return 0;
        }

        pushed = deltaToProcess;
        _fundDistributor({referralToken: refToken, amount: pushed});

        emit Push({
            referralChainId: referralChainId,
            referralProjectId: referralProjectId,
            referralToken: address(refToken),
            amount: pushed,
            caller: msg.sender
        });
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @inheritdoc IJBReferralSplitHook
    function packLeafMetadata(
        uint256 originChainId,
        uint256 referralProjectId
    )
        public
        pure
        override
        returns (bytes32 metadata)
    {
        // Enforce the documented field widths so an out-of-range value can never silently bleed into the
        // other field. EIP-155 chain IDs comfortably fit in uint32 (the largest production chain in 2026 is
        // well under 2^32); juicebox project IDs are sequential `uint256`s but in practice fit in uint48
        // with room to spare, so a uint64 cap here is forgiving and still catches accidents.
        if (originChainId > type(uint32).max) revert JBReferralSplitHook_ChainIdTooLarge(originChainId);
        if (referralProjectId > type(uint64).max) {
            revert JBReferralSplitHook_ReferralProjectIdTooLarge(referralProjectId);
        }

        // Layout: bits [95:64] = originChainId (uint32), bits [63:0] = referralProjectId (uint64).
        // Upper 160 bits remain zero, reserved for future extension.
        metadata = bytes32((originChainId << 64) | referralProjectId);
    }

    /// @notice Indicates whether this contract supports the given interface.
    /// @param interfaceId The interface ID to check.
    /// @return A flag indicating support.
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBSplitHook).interfaceId || interfaceId == type(IJBReferralSplitHook).interfaceId
            || super.supportsInterface(interfaceId);
    }

    //*********************************************************************//
    // -------------------------- private helpers ------------------------ //
    //*********************************************************************//

    /// @notice Approve the distributor and forward `amount` fee-project tokens to it, keyed on the
    /// referrer's IVotes token.
    /// @dev F-REF-E: reset the residual allowance to 0 after the distributor's pull. `forceApprove(amount)`
    /// followed by `fund` is the happy path, but if the distributor ever underpulls (it shouldn't, but
    /// defense-in-depth), a non-zero allowance would otherwise outlive this call and give the distributor a
    /// standing pull-right on subsequent deposits.
    function _fundDistributor(IJBToken referralToken, uint256 amount) private {
        IJBToken feeToken = TOKENS.tokenOf(FEE_PROJECT_ID);
        IERC20 fee = IERC20(address(feeToken));
        fee.forceApprove({spender: address(DISTRIBUTOR), value: amount});
        DISTRIBUTOR.fund({hook: address(referralToken), token: fee, amount: amount});
        fee.forceApprove({spender: address(DISTRIBUTOR), value: 0});
    }

    /// @notice Compute the delta between this referrer's current entitled share and what's already been
    /// processed, and return that delta. Returns 0 (and emits `Skipped`) when there's nothing to do (no
    /// volume on the terminal, no volume for the pair, or already caught up to the current entitlement).
    /// @dev Pure-of-storage with respect to the high-water mark: caller passes `alreadyProcessed` and is
    /// responsible for writing it back. This is what lets the same helper drive both the same-chain push
    /// ledger (`pushedLocallyOf`) and the outbound-bridge ledger (`bridgedOutOf`) without conflating them.
    /// @dev Reentrancy: the caller advances its own slot before any external token transfer; reentrancy via
    /// the sucker or distributor cannot grow `delta` because both `totalDeposited` and
    /// `feeVolumeByReferralOf` are monotonic.
    function _pendingDeltaFor(
        uint256 referralChainId,
        uint256 referralProjectId,
        uint256 alreadyProcessed
    )
        private
        returns (uint256 delta)
    {
        uint256 totalVol = STORE.totalFeeVolumeOf(TERMINAL);
        if (totalVol == 0) {
            emit Skipped({
                referralChainId: referralChainId,
                referralProjectId: referralProjectId,
                reason: "no volume",
                caller: msg.sender
            });
            return 0;
        }

        uint256 refVol = STORE.feeVolumeByReferralOf({
            terminal: TERMINAL, referralChainId: referralChainId, referralProjectId: referralProjectId
        });
        if (refVol == 0) {
            emit Skipped({
                referralChainId: referralChainId,
                referralProjectId: referralProjectId,
                reason: "no volume",
                caller: msg.sender
            });
            return 0;
        }

        uint256 entitled = mulDiv(totalDeposited, refVol, totalVol);
        if (entitled <= alreadyProcessed) {
            emit Skipped({
                referralChainId: referralChainId,
                referralProjectId: referralProjectId,
                reason: "caught up",
                caller: msg.sender
            });
            return 0;
        }

        unchecked {
            delta = entitled - alreadyProcessed;
        }
    }

    /// @notice Left-pad an EVM address into a 32-byte beneficiary identifier for sucker leaves.
    function _toBytes32(address addr) private pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }
}
