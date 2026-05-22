// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";
import {IJBSucker} from "@bananapus/suckers-v6/src/interfaces/IJBSucker.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBClaim} from "@bananapus/suckers-v6/src/structs/JBClaim.sol";

import {IJBReferralSplitHook} from "./interfaces/IJBReferralSplitHook.sol";

/// @notice A split hook on the fee project's reserved-token group that pools incoming fee-project tokens and
/// forwards each referring project's pro-rata share into a configured `IJBDistributor`.
/// @dev Referrers are identified by the `(referralChainId, referralProjectId)` pair recorded in
/// `JBTerminalStore.feeVolumeByReferralOf`. Same-chain referrers are pushed to the local distributor by `pushTo`.
/// Cross-chain referrers are bridged through the fee project's sucker by `bridgeRemote` and atomically settled on
/// the home chain by `claimAndPush` — the leaf's `data` field carries `(originChainId, referralProjectId)` so the
/// receiving hook knows exactly which local-twin project the bridged credit is for, all under the merkle proof's
/// authentication.
/// @dev The volume ratio comes from
/// `STORE.feeVolumeByReferralOf(TERMINAL, chainId, projectId) / STORE.totalFeeVolumeOf(TERMINAL)`. The vesting +
/// claim mechanics live downstream in the distributor.
contract JBReferralSplitHook is ERC165, IJBReferralSplitHook {
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // ----------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @inheritdoc IJBReferralSplitHook
    address public immutable override TERMINAL;

    /// @inheritdoc IJBReferralSplitHook
    IJBTerminalStore public immutable override STORE;

    /// @inheritdoc IJBReferralSplitHook
    IJBDirectory public immutable override DIRECTORY;

    /// @inheritdoc IJBReferralSplitHook
    IJBTokens public immutable override TOKENS;

    /// @inheritdoc IJBReferralSplitHook
    IJBDistributor public immutable override DISTRIBUTOR;

    /// @inheritdoc IJBReferralSplitHook
    IJBSuckerRegistry public immutable override SUCKER_REGISTRY;

    /// @inheritdoc IJBReferralSplitHook
    uint256 public immutable override FEE_PROJECT_ID;

    //*********************************************************************//
    // ---------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @inheritdoc IJBReferralSplitHook
    uint256 public override totalDeposited;

    /// @inheritdoc IJBReferralSplitHook
    /// @dev Nested by `referralChainId` then `referralProjectId` so the high-water mark is unique per
    /// cross-chain pair. The same `projectId` on two different chains tracks two independent push budgets.
    mapping(uint256 referralChainId => mapping(uint256 referralProjectId => uint256)) public override pushedOf;

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
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @inheritdoc IJBReferralSplitHook
    function packLeafData(uint256 originChainId, uint256 referralProjectId)
        public
        pure
        override
        returns (bytes32 data)
    {
        // Pack into a single bytes32. Both fields are bounded by the encoding nana-core uses for the transient
        // referral slot, so this representation is lossless for any value reachable through that pipeline.
        data = bytes32((originChainId << 64) | referralProjectId);
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Receive a slice of the fee project's reserved-token distribution. Only callable by the fee project's
    /// controller when distributing the fee project's reserved tokens.
    /// @param context The split hook context provided by the calling controller.
    function processSplitWith(JBSplitHookContext calldata context) external payable override {
        // Auth: caller must be the fee project's controller, and the split must belong to the fee project.
        if (context.projectId != FEE_PROJECT_ID) {
            revert JBReferralSplitHook_WrongProject({expected: FEE_PROJECT_ID, got: context.projectId});
        }
        if (address(DIRECTORY.controllerOf(FEE_PROJECT_ID)) != msg.sender) {
            revert JBReferralSplitHook_Unauthorized({projectId: FEE_PROJECT_ID, caller: msg.sender});
        }

        // Verify the token matches the fee project's project token. Reserved-token splits never carry native ETH;
        // we always expect an ERC-20 here.
        IJBToken feeToken = TOKENS.tokenOf(FEE_PROJECT_ID);
        if (address(feeToken) != context.token) {
            revert JBReferralSplitHook_TokenMismatch({expected: address(feeToken), got: context.token});
        }

        // Pull tokens via the allowance the controller granted us immediately before this call.
        IERC20(context.token).safeTransferFrom({from: msg.sender, to: address(this), value: context.amount});
        unchecked {
            totalDeposited += context.amount;
        }

        emit Deposit({amount: context.amount, newTotalDeposited: totalDeposited});
    }

    /// @inheritdoc IJBReferralSplitHook
    function pushTo(uint256 referralChainId, uint256 referralProjectId) external override returns (uint256 pushed) {
        // Reject the two sentinel/self-reference cases on the projectId axis. Chain ID can be anything (the
        // cross-chain skip is handled below).
        if (referralProjectId == 0 || referralProjectId == FEE_PROJECT_ID) {
            revert JBReferralSplitHook_InvalidReferralProjectId();
        }

        // Cross-chain referrers must use `bridgeRemote`. This skip keeps `pushTo` strictly the same-chain path.
        if (referralChainId != block.chainid) {
            emit Skipped({referralChainId: referralChainId, referralProjectId: referralProjectId, reason: "remote"});
            return 0;
        }

        uint256 deltaToProcess = _consumePendingFor(referralChainId, referralProjectId);
        if (deltaToProcess == 0) return 0;

        // Resolve the referring project's IVotes token on this chain. Credit-only projects (no ERC-20) cannot
        // receive a push — their share stays pending in this hook until they tokenize.
        IJBToken refToken = TOKENS.tokenOf(referralProjectId);
        if (address(refToken) == address(0)) {
            // We over-advanced `pushedOf` via `_consumePendingFor`; undo so the next push retries.
            pushedOf[referralChainId][referralProjectId] -= deltaToProcess;
            emit Skipped({referralChainId: referralChainId, referralProjectId: referralProjectId, reason: "no token"});
            return 0;
        }

        pushed = deltaToProcess;
        _fundDistributor({referralToken: refToken, amount: pushed});

        emit Push({
            referralChainId: referralChainId,
            referralProjectId: referralProjectId,
            referralToken: address(refToken),
            amount: pushed
        });
    }

    /// @inheritdoc IJBReferralSplitHook
    function bridgeRemote(
        uint256 referralChainId,
        uint256 referralProjectId,
        IJBSucker sucker,
        address terminalToken
    )
        external
        override
        returns (uint256 bridged)
    {
        // Sentinel + self-reference + cross-chain-only guards.
        if (referralProjectId == 0 || referralProjectId == FEE_PROJECT_ID) {
            revert JBReferralSplitHook_InvalidReferralProjectId();
        }
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

        uint256 deltaToProcess = _consumePendingFor(referralChainId, referralProjectId);
        if (deltaToProcess == 0) return 0;

        bridged = deltaToProcess;

        // Tag the leaf with `(originChainId, referralProjectId)` so the sibling hook on `referralChainId` knows
        // which local-twin project to settle to when it calls `claimAndPush`.
        bytes32 leafData = packLeafData({originChainId: block.chainid, referralProjectId: referralProjectId});

        // Approve the sucker for exactly `bridged` fee-project tokens. The sucker pulls via `safeTransferFrom`
        // inside `prepare`, then cashes them out via the source terminal (0% tax for sucker holders on omnichain
        // revnets) and adds a leaf to the outbox tree.
        IJBToken feeToken = TOKENS.tokenOf(FEE_PROJECT_ID);
        IERC20(address(feeToken)).forceApprove({spender: address(sucker), value: bridged});

        // Beneficiary is the sibling hook on the remote chain. We rely on the deploy convention that
        // `JBReferralSplitHook` is CREATE2-deployed at the same address across chains, so `address(this)` here
        // equals the address that will receive the bridged terminal tokens on `referralChainId`.
        sucker.prepare({
            projectTokenCount: bridged,
            beneficiary: _toBytes32(address(this)),
            minTokensReclaimed: 0,
            token: terminalToken,
            data: leafData
        });

        emit BridgedRemote({
            referralChainId: referralChainId,
            referralProjectId: referralProjectId,
            sucker: sucker,
            terminalToken: terminalToken,
            amount: bridged,
            leafData: leafData
        });
    }

    /// @inheritdoc IJBReferralSplitHook
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

        // The sucker must be a registered sucker of the fee project — this is how we know the bridged tokens
        // came from a hook on a chain that's part of the same fee-project omnichain identity.
        if (!SUCKER_REGISTRY.isSuckerOf({projectId: FEE_PROJECT_ID, addr: address(sucker)})) {
            revert JBReferralSplitHook_NotASucker({sucker: address(sucker)});
        }

        // The bridged tokens must be addressed to us. The sucker's merkle proof would catch a tampered leaf,
        // but checking the beneficiary explicitly catches a mismatched-claim-data call before we touch state.
        bytes32 expectedBeneficiary = _toBytes32(address(this));
        if (claimData.leaf.beneficiary != expectedBeneficiary) {
            revert JBReferralSplitHook_LeafBeneficiaryMismatch({
                expected: expectedBeneficiary, got: claimData.leaf.beneficiary
            });
        }

        // The merkle proof inside `sucker.claim` will validate `claimData.leaf.data`; we enforce that the
        // asserted `(originChainId, referralProjectId)` pair matches the leaf's data here so a caller can't
        // substitute the projectId argument and redirect bridged tokens to a different local distributor.
        bytes32 expectedData = packLeafData({originChainId: originChainId, referralProjectId: referralProjectId});
        if (claimData.leaf.data != expectedData) {
            revert JBReferralSplitHook_LeafBeneficiaryMismatch({expected: expectedData, got: claimData.leaf.data});
        }

        // Resolve the local fee project's primary terminal for the bridged terminal token. The sibling chain's
        // omnichain fee project must accept this token; if it doesn't, there's no way for the hook to mint
        // local fee-project tokens, so the claim must abort. Surface a typed error rather than a silent skip
        // since the caller can fix the situation by waiting for the terminal to be registered.
        IJBTerminal feeTerminal = DIRECTORY.primaryTerminalOf({projectId: FEE_PROJECT_ID, token: claimData.token});
        if (address(feeTerminal) == address(0)) {
            revert JBReferralSplitHook_NoFeeTerminal({terminalToken: claimData.token});
        }

        IJBToken localFeeToken = TOKENS.tokenOf(FEE_PROJECT_ID);

        // Phase 1: pull terminal tokens via the sucker. Measure the delta because the sucker's claim semantics
        // can deliver native ETH (when `claimData.token == JBConstants.NATIVE_TOKEN`) or an ERC-20.
        uint256 terminalBalanceBefore = _balanceOf({token: claimData.token, who: address(this)});
        sucker.claim(claimData);
        uint256 terminalReceived = _balanceOf({token: claimData.token, who: address(this)}) - terminalBalanceBefore;

        // Phase 2: pay the local fee project with what we just claimed, beneficiary = this hook. The fee
        // project mints new fee-project tokens to us at the local weight + bonding curve.
        uint256 feeProjectBalanceBefore = IERC20(address(localFeeToken)).balanceOf(address(this));
        if (claimData.token == JBConstants.NATIVE_TOKEN) {
            feeTerminal.pay{value: terminalReceived}({
                projectId: FEE_PROJECT_ID,
                token: claimData.token,
                amount: terminalReceived,
                beneficiary: address(this),
                minReturnedTokens: 0,
                memo: "",
                metadata: ""
            });
        } else {
            IERC20(claimData.token).forceApprove({spender: address(feeTerminal), value: terminalReceived});
            feeTerminal.pay({
                projectId: FEE_PROJECT_ID,
                token: claimData.token,
                amount: terminalReceived,
                beneficiary: address(this),
                minReturnedTokens: 0,
                memo: "",
                metadata: ""
            });
        }
        uint256 feeProjectMinted = IERC20(address(localFeeToken)).balanceOf(address(this)) - feeProjectBalanceBefore;

        // Phase 3: forward the freshly-minted fee-project tokens to the local distributor for the asserted
        // referrer. If the local twin has no `IJBToken` yet, the bridged credit stays in the hook as
        // un-pushed deposit — a future `pushTo` would not re-spend it because we haven't increased
        // `pushedOf[block.chainid][referralProjectId]`.
        IJBToken refToken = TOKENS.tokenOf(referralProjectId);
        if (address(refToken) == address(0)) {
            emit Skipped({referralChainId: block.chainid, referralProjectId: referralProjectId, reason: "no token"});
            emit ClaimedRemote({
                originChainId: originChainId,
                referralProjectId: referralProjectId,
                terminalToken: claimData.token,
                terminalReceived: terminalReceived,
                feeProjectMinted: feeProjectMinted,
                pushed: 0
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
            terminalReceived: terminalReceived,
            feeProjectMinted: feeProjectMinted,
            pushed: pushed
        });
    }

    //*********************************************************************//
    // ---------------------------- ERC-165 ------------------------------ //
    //*********************************************************************//

    /// @notice Indicates whether this contract supports the given interface.
    /// @param interfaceId The interface ID to check.
    /// @return A flag indicating support.
    function supportsInterface(bytes4 interfaceId) public pure override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBSplitHook).interfaceId || interfaceId == type(IJBReferralSplitHook).interfaceId
            || super.supportsInterface(interfaceId);
    }

    //*********************************************************************//
    // -------------------------- private helpers ------------------------ //
    //*********************************************************************//

    /// @notice Compute the delta between this referrer's current entitled share and what's already been processed,
    /// and atomically advance `pushedOf` by that delta. Returns 0 if there's nothing to do (no volume, total at
    /// zero, or caught up).
    /// @dev Reentrancy: callers update state before any external token transfer. If a later phase of `pushTo` or
    /// `bridgeRemote` discovers the recipient is unfundable (e.g. no IJBToken), they unwind by subtracting the
    /// same delta from `pushedOf` so a future call retries.
    function _consumePendingFor(uint256 referralChainId, uint256 referralProjectId) private returns (uint256 delta) {
        uint256 totalVol = STORE.totalFeeVolumeOf(TERMINAL);
        if (totalVol == 0) {
            emit Skipped({referralChainId: referralChainId, referralProjectId: referralProjectId, reason: "no volume"});
            return 0;
        }

        uint256 refVol = STORE.feeVolumeByReferralOf({
            terminal: TERMINAL, referralChainId: referralChainId, referralProjectId: referralProjectId
        });
        if (refVol == 0) {
            emit Skipped({referralChainId: referralChainId, referralProjectId: referralProjectId, reason: "no volume"});
            return 0;
        }

        uint256 entitled = mulDiv(totalDeposited, refVol, totalVol);
        uint256 alreadyPushed = pushedOf[referralChainId][referralProjectId];
        if (entitled <= alreadyPushed) {
            emit Skipped({referralChainId: referralChainId, referralProjectId: referralProjectId, reason: "caught up"});
            return 0;
        }

        unchecked {
            delta = entitled - alreadyPushed;
        }
        // Advance the high-water mark BEFORE the caller does its external work. Reentrancy via the sucker or
        // distributor cannot grow the delta because both `totalDeposited` and `feeVolumeByReferralOf` are
        // monotonic.
        pushedOf[referralChainId][referralProjectId] = entitled;
    }

    /// @notice Approve the distributor and forward `amount` fee-project tokens to it, keyed on the referrer's
    /// IVotes token.
    function _fundDistributor(IJBToken referralToken, uint256 amount) private {
        IJBToken feeToken = TOKENS.tokenOf(FEE_PROJECT_ID);
        IERC20(address(feeToken)).forceApprove({spender: address(DISTRIBUTOR), value: amount});
        DISTRIBUTOR.fund({hook: address(referralToken), token: IERC20(address(feeToken)), amount: amount});
    }

    /// @notice Token-balance probe that handles the native-token sentinel uniformly with ERC-20 tokens.
    function _balanceOf(address token, address who) private view returns (uint256) {
        if (token == JBConstants.NATIVE_TOKEN) return who.balance;
        return IERC20(token).balanceOf(who);
    }

    /// @notice Left-pad an EVM address into a 32-byte beneficiary identifier for sucker leaves.
    function _toBytes32(address addr) private pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    /// @notice Accept native ETH from sucker claims (when the bridged terminal token is native).
    receive() external payable {}
}
