// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";

import {IJBReferralSplitHook} from "./interfaces/IJBReferralSplitHook.sol";

/// @notice A split hook on the fee project's reserved-token group that pools incoming fee-project tokens and
/// forwards each referring project's pro-rata share into a configured `IJBDistributor`.
/// @dev The volume ratio comes from `JBTerminalStore.feeVolumeByReferralOf` / `totalFeeVolumeOf` keyed by the
/// configured `TERMINAL`. The vesting + claim mechanics live downstream in the distributor.
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
    uint256 public immutable override FEE_PROJECT_ID;

    //*********************************************************************//
    // ---------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @inheritdoc IJBReferralSplitHook
    uint256 public override totalDeposited;

    /// @inheritdoc IJBReferralSplitHook
    mapping(uint256 referralProjectId => uint256) public override pushedOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory The directory used to authenticate the controller call to `processSplitWith`.
    /// @param store The terminal store that publishes the per-referrer fee volume ledger.
    /// @param tokens The tokens registry used to resolve the fee project's and referrers' project tokens.
    /// @param distributor The distributor that receives forwarded per-referrer shares.
    /// @param terminal The terminal whose `JBTerminalStore` volume ledger this hook reads from.
    /// @param feeProjectId The project ID receiving fees (typically project 1).
    constructor(
        IJBDirectory directory,
        IJBTerminalStore store,
        IJBTokens tokens,
        IJBDistributor distributor,
        address terminal,
        uint256 feeProjectId
    ) {
        DIRECTORY = directory;
        STORE = store;
        TOKENS = tokens;
        DISTRIBUTOR = distributor;
        TERMINAL = terminal;
        FEE_PROJECT_ID = feeProjectId;
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
    function pushTo(uint256 referralProjectId) external override returns (uint256 pushed) {
        if (referralProjectId == 0 || referralProjectId == FEE_PROJECT_ID) {
            revert JBReferralSplitHook_InvalidReferralProjectId();
        }

        uint256 totalVol = STORE.totalFeeVolumeOf(TERMINAL);
        if (totalVol == 0) {
            emit Skipped({referralProjectId: referralProjectId, reason: "no volume"});
            return 0;
        }

        uint256 refVol = STORE.feeVolumeByReferralOf(TERMINAL, referralProjectId);
        if (refVol == 0) {
            emit Skipped({referralProjectId: referralProjectId, reason: "no volume"});
            return 0;
        }

        uint256 entitled = mulDiv(totalDeposited, refVol, totalVol);
        uint256 alreadyPushed = pushedOf[referralProjectId];
        if (entitled <= alreadyPushed) {
            emit Skipped({referralProjectId: referralProjectId, reason: "caught up"});
            return 0;
        }

        // Resolve the referring project's IVotes token. Credit-only projects (no ERC-20) cannot receive a push —
        // their share stays pending in this hook until they tokenize.
        IJBToken refToken = TOKENS.tokenOf(referralProjectId);
        if (address(refToken) == address(0)) {
            emit Skipped({referralProjectId: referralProjectId, reason: "no token"});
            return 0;
        }

        unchecked {
            pushed = entitled - alreadyPushed;
        }

        // Update the high-water mark BEFORE the external call. Reentrancy via the distributor or the fee-project
        // token cannot increase `pushed` because both `totalDeposited` and `feeVolumeByReferralOf` are monotonic;
        // re-entering would just compute a smaller delta and revert at the SafeERC20 layer if it tried to over-pull.
        pushedOf[referralProjectId] = entitled;

        IJBToken feeToken = TOKENS.tokenOf(FEE_PROJECT_ID);
        IERC20(address(feeToken)).forceApprove({spender: address(DISTRIBUTOR), value: pushed});
        DISTRIBUTOR.fund({hook: address(refToken), token: IERC20(address(feeToken)), amount: pushed});

        emit Push({referralProjectId: referralProjectId, referralToken: address(refToken), amount: pushed});
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
}
