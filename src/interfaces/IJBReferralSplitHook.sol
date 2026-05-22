// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";
import {IJBSucker} from "@bananapus/suckers-v6/src/interfaces/IJBSucker.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBClaim} from "@bananapus/suckers-v6/src/structs/JBClaim.sol";

/// @notice A split hook that pools the fee project's reserved-token allocation and forwards each referring project's
/// pro-rata share to an `IJBDistributor` (typically `JBTokenDistributor`) so the referring project's IVotes holders
/// can claim it.
/// @dev Referrers are identified by the `(referralChainId, referralProjectId)` pair recorded in
/// `JBTerminalStore.feeVolumeByReferralOf`. Same-chain referrers get pushed to the local distributor directly
/// (`pushTo`). Cross-chain referrers are bridged through the fee project's sucker: `bridgeRemote` cashes out the
/// entitled fee-project tokens via the sucker (0% tax for sucker holders) and tags the leaf with
/// `(originChainId, referralProjectId)` in the leaf's `metadata` field so the sibling hook on the referrer's home
/// chain can atomically claim and push to the local distributor (`claimAndPush`). The sucker's `_handleClaim`
/// already deposits the bridged terminal tokens into the destination fee project's terminal and mints
/// destination fee-project tokens to the beneficiary (this hook) — `claimAndPush` simply forwards those
/// freshly-minted tokens. The full settlement is authenticated by the sucker's merkle proof — no off-chain
/// coordination needed.
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

    /// @notice Emitted when a same-chain referring project's accrued share is forwarded to the distributor.
    /// @param referralChainId The referrer's home chain ID (always `block.chainid` for this event).
    /// @param referralProjectId The referring project credited.
    /// @param referralToken The referring project's IVotes token (the distributor `hook` key).
    /// @param amount The number of fee-project tokens forwarded.
    event Push(
        uint256 indexed referralChainId,
        uint256 indexed referralProjectId,
        address indexed referralToken,
        uint256 amount
    );

    /// @notice Emitted when a cross-chain referrer's accrued share is bridged via the fee project's sucker.
    /// @param referralChainId The referrer's home chain ID.
    /// @param referralProjectId The referring project credited.
    /// @param sucker The sucker used to bridge.
    /// @param terminalToken The terminal token cashed out into for the bridge.
    /// @param amount The number of fee-project tokens cashed out into the sucker.
    /// @param leafMetadata The `bytes32 metadata` payload written into the sucker leaf for atomic destination
    /// settlement.
    event BridgedRemote(
        uint256 indexed referralChainId,
        uint256 indexed referralProjectId,
        IJBSucker sucker,
        address terminalToken,
        uint256 amount,
        bytes32 leafMetadata
    );

    /// @notice Emitted when a bridged claim is settled on the referrer's home chain: tokens are claimed from the
    /// sucker, paid into the local fee project (yielding fee-project tokens), and pushed to the local distributor.
    /// @param originChainId The chain the credit was originally earned on.
    /// @param referralProjectId The local twin of the referring project on this chain.
    /// @param terminalToken The terminal token received from the sucker claim.
    /// @param terminalReceived The amount of terminal tokens received from the sucker.
    /// @param feeProjectMinted The amount of fee-project tokens minted by paying the local fee project.
    /// @param pushed The amount actually forwarded to the distributor.
    event ClaimedRemote(
        uint256 indexed originChainId,
        uint256 indexed referralProjectId,
        address indexed terminalToken,
        uint256 terminalReceived,
        uint256 feeProjectMinted,
        uint256 pushed
    );

    /// @notice Emitted when `pushTo` or `bridgeRemote` no-ops for an observable reason.
    /// @param referralChainId The referrer's home chain ID.
    /// @param referralProjectId The referring project whose action was skipped.
    /// @param reason A short, indexed code (e.g. `"no token"`, `"no volume"`, `"caught up"`, `"no sucker"`).
    event Skipped(uint256 indexed referralChainId, uint256 indexed referralProjectId, bytes32 reason);

    //*********************************************************************//
    // ------------------------------ errors ------------------------------ //
    //*********************************************************************//

    error JBReferralSplitHook_Unauthorized(uint256 projectId, address caller);
    error JBReferralSplitHook_WrongProject(uint256 expected, uint256 got);
    error JBReferralSplitHook_TokenMismatch(address expected, address got);
    error JBReferralSplitHook_InvalidReferralProjectId();
    error JBReferralSplitHook_NotASucker(address sucker);
    error JBReferralSplitHook_WrongBridgeTarget(uint256 expectedChainId, uint256 actualChainId);
    error JBReferralSplitHook_SuckerPeerMismatch(uint256 expectedPeerChainId, uint256 actualPeerChainId);
    error JBReferralSplitHook_LeafBeneficiaryMismatch(bytes32 expected, bytes32 got);
    error JBReferralSplitHook_LeafMetadataMismatch(bytes32 expected, bytes32 got);
    error JBReferralSplitHook_OriginIsLocal(uint256 chainId);
    error JBReferralSplitHook_ChainIdTooLarge(uint256 chainId);
    error JBReferralSplitHook_ReferralProjectIdTooLarge(uint256 referralProjectId);

    //*********************************************************************//
    // --------------------------- view methods -------------------------- //
    //*********************************************************************//

    /// @notice The terminal whose `JBTerminalStore` volume ledger this hook reads from.
    function TERMINAL() external view returns (address);

    /// @notice The terminal store that publishes the per-referrer fee volume ledger.
    function STORE() external view returns (IJBTerminalStore);

    /// @notice The directory used to authenticate the controller call to `processSplitWith` and to resolve the
    /// fee project's primary terminal on the local chain.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The tokens registry used to resolve the fee project's and referrers' project tokens.
    function TOKENS() external view returns (IJBTokens);

    /// @notice The distributor that receives forwarded per-referrer shares.
    function DISTRIBUTOR() external view returns (IJBDistributor);

    /// @notice The sucker registry used to authenticate sucker addresses passed to `bridgeRemote` and
    /// `claimAndPush`.
    function SUCKER_REGISTRY() external view returns (IJBSuckerRegistry);

    /// @notice The project ID receiving fees (typically project 1).
    function FEE_PROJECT_ID() external view returns (uint256);

    /// @notice Cumulative fee-project tokens received by this hook via `processSplitWith`.
    function totalDeposited() external view returns (uint256);

    /// @notice High-water mark of fee-project tokens forwarded for a given
    /// `(referralChainId, referralProjectId)` pair. Same-chain pairs are pushed directly to the local distributor;
    /// cross-chain pairs are bridged out via `bridgeRemote`. Both paths advance this mark by the same accounting
    /// formula, so a referrer is paid at most their pro-rata share regardless of which side does the work.
    /// @param referralChainId The referrer's home chain ID.
    /// @param referralProjectId The referring project on that chain.
    /// @return The cumulative amount processed for this pair.
    function pushedOf(uint256 referralChainId, uint256 referralProjectId) external view returns (uint256);

    //*********************************************************************//
    // -------------------------- external txs ---------------------------- //
    //*********************************************************************//

    /// @notice Forward a same-chain referrer's accrued pro-rata share to the local distributor.
    /// @dev Permissionless. Reverts when `referralProjectId in {0, FEE_PROJECT_ID}`. Skips (without reverting)
    /// when the referrer has no `IJBToken` locally, when there's no recorded volume yet, when the entitled
    /// amount hasn't grown above the high-water mark, or when `referralChainId != block.chainid` (cross-chain —
    /// use `bridgeRemote`).
    /// @param referralChainId The referrer's home EIP-155 chain ID. Must equal `block.chainid`.
    /// @param referralProjectId The referring project on that chain.
    /// @return pushed The number of tokens forwarded in this call (0 on skip).
    function pushTo(uint256 referralChainId, uint256 referralProjectId) external returns (uint256 pushed);

    /// @notice Bridge a cross-chain referrer's accrued pro-rata share through the fee project's sucker.
    /// @dev Permissionless. Cashes out the entitled fee-project tokens via `sucker.prepare`, which (for sucker
    /// holders on omnichain revnets) pays 0% cash-out tax — the bridge is loss-free in fee-project-token terms.
    /// The leaf's `metadata` field is set to `(originChainId, referralProjectId)` so the sibling hook on
    /// `referralChainId` can atomically settle on `claimAndPush`. Reverts if the sucker isn't a registered
    /// sucker of the fee project. Skips (without reverting) on the usual no-token / no-volume / caught-up cases.
    /// `referralChainId` must not equal `block.chainid` (that's a local push — use `pushTo`).
    /// @param referralChainId The referrer's home EIP-155 chain ID. Must NOT equal `block.chainid`.
    /// @param referralProjectId The referring project on that chain.
    /// @param sucker The fee project's sucker pair to use; must bridge to `referralChainId` and be registered.
    /// @param terminalToken The terminal token to cash out into. Must be mapped on the sucker.
    /// @return bridged The number of fee-project tokens cashed out into the sucker (0 on skip).
    function bridgeRemote(
        uint256 referralChainId,
        uint256 referralProjectId,
        IJBSucker sucker,
        address terminalToken
    )
        external
        returns (uint256 bridged);

    /// @notice Atomically claim a bridged credit and push it to the local distributor for the referrer's
    /// local-twin project.
    /// @dev Permissionless. Validates that `originChainId != block.chainid`, the sucker is a registered sucker
    /// of the fee project, the claim's beneficiary is this hook, and the leaf's `metadata` matches the asserted
    /// `(originChainId, referralProjectId)` pair (the merkle proof inside `sucker.claim` already authenticated
    /// `metadata` — the equality check here just enforces correct argument ordering). Then it calls
    /// `sucker.claim`, which deposits the bridged terminal tokens into the destination fee project's terminal
    /// AND mints destination fee-project tokens directly to this hook (the leaf's `beneficiary`). The hook
    /// measures the fee-project-token balance delta and forwards it to the local distributor for
    /// `referralProjectId`'s local twin. Skips (without reverting) when the local twin has no `IJBToken` yet —
    /// the unforwarded fee-project tokens stay in this hook's balance; no `pushedOf` accounting on the
    /// destination side because the source chain's `bridgeRemote` already advanced its high-water mark.
    /// @param originChainId The chain the credit was originally earned on.
    /// @param referralProjectId The local twin's project ID on this chain.
    /// @param sucker The fee project's sucker pair the claim belongs to.
    /// @param claimData The terminal token, leaf, and merkle proof from the bridge.
    /// @return pushed The number of fee-project tokens forwarded to the local distributor.
    function claimAndPush(
        uint256 originChainId,
        uint256 referralProjectId,
        IJBSucker sucker,
        JBClaim calldata claimData
    )
        external
        returns (uint256 pushed);

    /// @notice Pack `(originChainId, referralProjectId)` into the `bytes32 metadata` payload carried by the sucker
    /// leaf. Pure helper so off-chain integrations and tests can derive the value identically.
    /// @dev Layout: bits [95:64] = `originChainId` (uint32), bits [63:0] = `referralProjectId` (uint64). The
    /// upper bits are reserved.
    /// @param originChainId The chain the credit was originally earned on.
    /// @param referralProjectId The referring project's bare ID on the destination chain.
    /// @return metadata The packed value to pass into `sucker.prepare`.
    function packLeafMetadata(uint256 originChainId, uint256 referralProjectId) external pure returns (bytes32 metadata);
}
