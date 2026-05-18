// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";

/// @notice A split hook that pools the fee project's reserved-token allocation and forwards each referring project's
/// pro-rata share to an `IJBDistributor` (typically `JBTokenDistributor`) so the referring project's IVotes holders
/// can claim it.
/// @dev See `ARCHITECTURE.md` for the system context and `RISKS.md` for the late-entrant skew of the high-water-mark
/// pro-rata math.
interface IJBReferralSplitHook is IJBSplitHook {
    //*********************************************************************//
    // ------------------------------ events ------------------------------ //
    //*********************************************************************//

    /// @notice Emitted when reserved tokens are received from the fee project's split distribution.
    /// @param amount The number of tokens received in this `processSplitWith` call.
    /// @param newTotalDeposited The new value of `totalDeposited` after this deposit.
    event Deposit(uint256 amount, uint256 newTotalDeposited);

    /// @notice Emitted when a referring project's accrued share is forwarded to the distributor.
    /// @param referralProjectId The referring project credited.
    /// @param referralToken The referring project's IVotes token (the distributor `hook` key).
    /// @param amount The number of fee-project tokens forwarded.
    event Push(uint256 indexed referralProjectId, address indexed referralToken, uint256 amount);

    /// @notice Emitted when `pushTo` no-ops for an observable reason.
    /// @param referralProjectId The referring project whose push was skipped.
    /// @param reason A short, indexed code (e.g. `"no token"`, `"no volume"`, `"caught up"`).
    event Skipped(uint256 indexed referralProjectId, bytes32 reason);

    //*********************************************************************//
    // ------------------------------ errors ------------------------------ //
    //*********************************************************************//

    error JBReferralSplitHook_Unauthorized(uint256 projectId, address caller);
    error JBReferralSplitHook_WrongProject(uint256 expected, uint256 got);
    error JBReferralSplitHook_TokenMismatch(address expected, address got);
    error JBReferralSplitHook_InvalidReferralProjectId();

    //*********************************************************************//
    // --------------------------- view methods -------------------------- //
    //*********************************************************************//

    /// @notice The terminal whose `JBTerminalStore` volume ledger this hook reads from.
    function TERMINAL() external view returns (address);

    /// @notice The terminal store that publishes the per-referrer fee volume ledger.
    function STORE() external view returns (IJBTerminalStore);

    /// @notice The directory used to authenticate the controller call to `processSplitWith`.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The tokens registry used to resolve the fee project's and referrers' project tokens.
    function TOKENS() external view returns (IJBTokens);

    /// @notice The distributor that receives forwarded per-referrer shares.
    function DISTRIBUTOR() external view returns (IJBDistributor);

    /// @notice The project ID receiving fees (typically project 1).
    function FEE_PROJECT_ID() external view returns (uint256);

    /// @notice Cumulative fee-project tokens received by this hook via `processSplitWith`.
    function totalDeposited() external view returns (uint256);

    /// @notice High-water mark of fee-project tokens forwarded to the distributor for a given referrer.
    /// @param referralProjectId The referring project.
    /// @return The cumulative amount pushed.
    function pushedOf(uint256 referralProjectId) external view returns (uint256);

    //*********************************************************************//
    // -------------------------- external txs ---------------------------- //
    //*********************************************************************//

    /// @notice Forward this referrer's accrued pro-rata share to the distributor.
    /// @dev Permissionless. Computes `entitled = mulDiv(totalDeposited, refVolume, totalFeeVolume)` and pushes
    /// `entitled - pushedOf[referralProjectId]` (clamped at 0). Reverts on `referralProjectId in {0, FEE_PROJECT_ID}`.
    /// No-ops (without revert) when the referrer has no `IJBToken`, no recorded volume, or has already been pushed
    /// at or above its current entitled level.
    /// @param referralProjectId The referring project whose share to forward.
    /// @return pushed The number of tokens forwarded in this call (0 on no-op).
    function pushTo(uint256 referralProjectId) external returns (uint256 pushed);
}
