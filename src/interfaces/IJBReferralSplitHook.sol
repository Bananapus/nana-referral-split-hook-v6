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
/// @dev Naming convention — `referralProjectId` ALWAYS refers to the projectId on the referrer's home chain
/// (`referralChainId`), never to a numerically-matching projectId on some other chain. Juicebox projectId spaces
/// are per-chain, so a referrer registered as `42` on Optimism is unrelated to project `42` on Base. All call
/// sites in this hook — `pushTo`, `bridgeRemote`, `claimAndPush`, `packLeafMetadata`, and the source-side ledger
/// at `JBTerminalStore.feeVolumeByReferralOf(terminal, referralChainId, referralProjectId)` — interpret the
/// field the same way. Callers crediting a cross-chain referrer at the original cashOut/pay/payout call site
/// must therefore pass the referrer's projectId on the referrer's chain, not the source-chain projectId.
/// @dev See `ARCHITECTURE.md` for the system context and `RISKS.md` for the late-entrant skew of the high-water-mark
/// pro-rata math.
interface IJBReferralSplitHook is IJBSplitHook {
    //*********************************************************************//
    // ------------------------------ events ------------------------------ //
    //*********************************************************************//

    /// @notice Emitted when a cross-chain referrer's accrued share is bridged via the fee project's sucker.
    /// @param referralChainId The referrer's home chain ID.
    /// @param referralProjectId The referring project credited.
    /// @param sucker The sucker used to bridge.
    /// @param terminalToken The terminal token cashed out into for the bridge.
    /// @param amount The number of fee-project tokens cashed out into the sucker.
    /// @param leafMetadata The `bytes32 metadata` payload written into the sucker leaf for atomic destination
    /// settlement.
    /// @param caller The address that bridged the remote share.
    event BridgedRemote(
        uint256 indexed referralChainId,
        uint256 indexed referralProjectId,
        IJBSucker sucker,
        address terminalToken,
        uint256 amount,
        bytes32 leafMetadata,
        address caller
    );

    /// @notice DEPRECATED. Retained in the interface ABI so historical event logs from prior deployments
    /// remain decodable. Current code emits `ParkedOnStrand` instead — the freshly-minted fee-project
    /// tokens are parked in the hook pending `pokeDeferredClaim`, not burned. Will be removed in a future
    /// major release once indexers have migrated.
    /// @param originChainId The chain the credit was originally earned on.
    /// @param referralProjectId The local twin's project ID on this chain (had no IJBToken).
    /// @param feeProjectBurned The number of fee-project tokens that would have been burned.
    /// @param caller The address that settled the bridged claim.
    event BurnedOnStrand(
        uint256 indexed originChainId, uint256 indexed referralProjectId, uint256 feeProjectBurned, address caller
    );

    /// @notice Emitted when an accumulated cross-chain referral credit was burned because no sucker exists
    /// for the credited chain. The bridged terminal-token value never actually moved — the credit was
    /// sitting idle in the hook's pro-rata pool — so burning the fee-project tokens directly cancels the
    /// accumulated allocation and returns the surplus to existing fee-token holders.
    /// @dev Advances `bridgedOutOf[chainId][projectId]` by `amount` so the burn is idempotent and so that a
    /// future sucker deployment for `chainId` can only `bridgeRemote` INCREMENTAL credit accumulated AFTER
    /// the burn — the burned portion is permanently irrecoverable for the credited referrer (by design).
    /// @param caller The address that burned the unbridgeable credit.
    event BurnedUnbridgeable(
        uint256 indexed referralChainId, uint256 indexed referralProjectId, uint256 amount, address caller
    );

    /// @notice Emitted when `claimAndPush` settled via the front-run path: an external caller already
    /// invoked `sucker.claim` for this leaf, so the freshly-minted fee-project tokens were already in this
    /// hook's balance. We re-derived the leaf hash from the caller's claim data, matched against the hash
    /// the sucker committed at execution time, and proceeded with settlement.
    /// @param originChainId The chain the credit was originally earned on.
    /// @param referralProjectId The local twin's project ID on this chain.
    /// @param leafIndex The leaf index in the sucker's inbox tree.
    /// @param feeProjectMinted The amount of fee-project tokens being settled (== leaf's `projectTokenCount`).
    /// @param caller The address that triggered the `claimAndPush` call.
    event ClaimedFromFrontRun(
        uint256 indexed originChainId,
        uint256 indexed referralProjectId,
        uint256 indexed leafIndex,
        uint256 feeProjectMinted,
        address caller
    );

    /// @notice Emitted when a bridged claim is settled on the referrer's home chain: tokens are claimed
    /// from the sucker, paid into the local fee project (yielding fee-project tokens), and pushed to the
    /// local distributor.
    /// @param originChainId The chain the credit was originally earned on.
    /// @param referralProjectId The local twin of the referring project on this chain.
    /// @param terminalToken The terminal token received from the sucker claim.
    /// @param terminalReceived The amount of terminal tokens received from the sucker.
    /// @param feeProjectMinted The amount of fee-project tokens minted by paying the local fee project.
    /// @param pushed The amount actually forwarded to the distributor.
    /// @param caller The address that settled the bridged claim.
    event ClaimedRemote(
        uint256 indexed originChainId,
        uint256 indexed referralProjectId,
        address indexed terminalToken,
        uint256 terminalReceived,
        uint256 feeProjectMinted,
        uint256 pushed,
        address caller
    );

    /// @notice Emitted when reserved tokens are received from the fee project's split distribution.
    /// @param amount The number of tokens received in this `processSplitWith` call.
    /// @param newTotalDeposited The new value of `totalDeposited` after this deposit.
    /// @param caller The address that called the hook.
    event Deposit(uint256 amount, uint256 newTotalDeposited, address caller);

    /// @notice Emitted when a same-chain referring project's accrued share is forwarded to the distributor.
    /// @param referralChainId The referrer's home chain ID (always `block.chainid` for this event).
    /// @param referralProjectId The referring project credited.
    /// @param referralToken The referring project's IVotes token (the distributor `hook` key).
    /// @param amount The number of fee-project tokens forwarded.
    /// @param caller The address that pushed the share.
    event Push(
        uint256 indexed referralChainId,
        uint256 indexed referralProjectId,
        address indexed referralToken,
        uint256 amount,
        address caller
    );

    /// @notice Emitted when a bridged claim lands but the local twin has no `IJBToken`, so the
    /// freshly-minted fee-project tokens are parked in this hook keyed by leaf identity. The parked
    /// amount can later be released to the local distributor via `pokeDeferredClaim` once the referrer
    /// tokenizes.
    /// @param originChainId The chain the credit was originally earned on.
    /// @param referralProjectId The local twin's project ID on this chain (had no `IJBToken` at claim time).
    /// @param sucker The fee project's sucker pair the claim came from. Used as part of the park key.
    /// @param terminalToken The terminal token of the bridged leaf. Used as part of the park key.
    /// @param leafIndex The leaf index in the sucker's inbox tree. Used as part of the park key.
    /// @param feeProjectParked The number of fee-project tokens parked in the hook pending tokenization.
    /// @param caller The address that triggered the deferred-claim park.
    event ParkedOnStrand(
        uint256 indexed originChainId,
        uint256 indexed referralProjectId,
        IJBSucker sucker,
        address terminalToken,
        uint256 leafIndex,
        uint256 feeProjectParked,
        address caller
    );

    /// @notice Emitted when `pokeDeferredClaim` successfully releases a parked deferred-claim amount to the
    /// local distributor — typically after the referrer's `IJBToken` was finally deployed.
    /// @param strandedKey The `keccak256(abi.encode(sucker, terminalToken, leafIndex))` that keyed the park.
    /// @param referralProjectId The local twin's project ID on this chain (now has an `IJBToken`).
    /// @param amount The number of fee-project tokens released to the local distributor.
    /// @param caller The address that triggered the deferred-claim release.
    event PokedDeferredClaim(
        bytes32 indexed strandedKey, uint256 indexed referralProjectId, uint256 amount, address caller
    );

    /// @notice Emitted when `pushTo` or `bridgeRemote` no-ops for an observable reason.
    /// @param referralChainId The referrer's home chain ID.
    /// @param referralProjectId The referring project whose action was skipped.
    /// @param reason A short, indexed code (e.g. `"no token"`, `"no volume"`, `"caught up"`, `"no sucker"`).
    /// @param caller The address that triggered the skipped action.
    event Skipped(uint256 indexed referralChainId, uint256 indexed referralProjectId, bytes32 reason, address caller);

    //*********************************************************************//
    // --------------------------- view methods -------------------------- //
    //*********************************************************************//

    /// @notice The directory used to authenticate the controller call to `processSplitWith` and to resolve
    /// the fee project's primary terminal on the local chain.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The distributor that receives forwarded per-referrer shares.
    function DISTRIBUTOR() external view returns (IJBDistributor);

    /// @notice The project ID receiving fees (typically project 1).
    function FEE_PROJECT_ID() external view returns (uint256);

    /// @notice The terminal store that publishes the per-referrer fee volume ledger.
    function STORE() external view returns (IJBTerminalStore);

    /// @notice The sucker registry used to authenticate sucker addresses passed to `bridgeRemote` and
    /// `claimAndPush`.
    function SUCKER_REGISTRY() external view returns (IJBSuckerRegistry);

    /// @notice The terminal whose `JBTerminalStore` volume ledger this hook reads from.
    function TERMINAL() external view returns (address);

    /// @notice The tokens registry used to resolve the fee project's and referrers' project tokens.
    function TOKENS() external view returns (IJBTokens);

    /// @notice High-water mark of fee-project tokens cashed out via `bridgeRemote` for a cross-chain
    /// referrer.
    /// @dev Cross-chain only. The same-chain analog is `pushedLocallyOf`. Keyed by `(referralChainId,
    /// referralProjectId)` where `referralProjectId` is the referrer's projectId *on `referralChainId`* —
    /// NOT on the source. Each chain has an independent projectId space, so a numeric `42` on Optimism and
    /// a numeric `42` on Base identify two different projects and get two independent bridge budgets here.
    /// @param referralChainId The referrer's home chain ID.
    /// @param referralProjectId The referring project's projectId on `referralChainId`.
    /// @return The cumulative amount bridged out for this pair.
    function bridgedOutOf(uint256 referralChainId, uint256 referralProjectId) external view returns (uint256);

    /// @notice Pack `(originChainId, referralProjectId)` into the `bytes32 metadata` payload carried by the
    /// sucker leaf. Pure helper so off-chain integrations and tests can derive the value identically.
    /// @dev Layout: bits [95:64] = `originChainId` (uint32), bits [63:0] = `referralProjectId` (uint64).
    /// The upper bits are reserved.
    /// @param originChainId The chain the credit was originally earned on.
    /// @param referralProjectId The referring project's bare ID on the destination chain.
    /// @return metadata The packed value to pass into `sucker.prepare`.
    function packLeafMetadata(uint256 originChainId, uint256 referralProjectId) external pure returns (bytes32 metadata);

    /// @notice High-water mark of fee-project tokens forwarded *to the local distributor* for a same-chain
    /// referrer (i.e. one whose `referralChainId == block.chainid`).
    /// @dev Same-chain only. The cross-chain analog is `bridgedOutOf`. The two are tracked in separate
    /// mappings because they represent very different actions — a local push to a distributor, versus
    /// tokens cashed out into a sucker for cross-chain bridging — and prior versions that conflated them
    /// under one nested mapping were error-prone for off-chain indexers.
    /// @param localReferralProjectId The referring project's projectId on `block.chainid`.
    /// @return The cumulative amount pushed locally for this projectId.
    function pushedLocallyOf(uint256 localReferralProjectId) external view returns (uint256);

    /// @notice The fee-project token amount parked in this hook by `claimAndPush` when the local twin had
    /// no `IJBToken` at claim time, keyed by leaf identity.
    /// @dev Keyed by `keccak256(abi.encode(sucker, terminalToken, leafIndex))`. Non-zero iff the leaf was
    /// settled while the local twin's `TOKENS.tokenOf(referralProjectId) == address(0)`. The amount is
    /// released to the local distributor by `pokeDeferredClaim` once the referrer tokenizes.
    /// @param strandedKey The `keccak256(abi.encode(sucker, terminalToken, leafIndex))` lookup key.
    /// @return The parked fee-project token amount (0 if nothing is parked).
    function parkedAmountOf(bytes32 strandedKey) external view returns (uint256);

    /// @notice The local-twin `referralProjectId` associated with a parked leaf, so `pokeDeferredClaim` can
    /// re-derive the destination without trusting calldata.
    /// @dev Mirrors `parkedAmountOf` 1:1.
    /// @param strandedKey The `keccak256(abi.encode(sucker, terminalToken, leafIndex))` lookup key.
    /// @return The referral project ID parked alongside `parkedAmountOf[strandedKey]`.
    function parkedReferralProjectIdOf(bytes32 strandedKey) external view returns (uint256);

    /// @notice Whether this hook has already settled the leaf at `(sucker, terminalToken, leafIndex)`.
    /// @dev Set inside `claimAndPush` after the leaf's tokens have been processed (either via the normal
    /// `sucker.claim` path or via the front-run path). Subsequent calls with the same triple revert with
    /// `JBReferralSplitHook_LeafAlreadySettled` so the hook can never double-process a single leaf even when
    /// an external caller raced ahead of it.
    /// @param sucker The sucker that produced the leaf.
    /// @param terminalToken The terminal token of the leaf.
    /// @param leafIndex The leaf index in the sucker's inbox tree.
    /// @return Whether the leaf has already been settled.
    function settledLeafOf(IJBSucker sucker, address terminalToken, uint256 leafIndex) external view returns (bool);

    /// @notice Cumulative fee-project tokens received by this hook via `processSplitWith`.
    function totalDeposited() external view returns (uint256);

    //*********************************************************************//
    // -------------------------- external txs ---------------------------- //
    //*********************************************************************//

    /// @notice Bridge a cross-chain referrer's accrued pro-rata share through the fee project's sucker.
    /// @dev Permissionless. Cashes out the entitled fee-project tokens via `sucker.prepare`, which (for
    /// sucker holders on omnichain revnets) pays 0% cash-out tax — the bridge is loss-free in
    /// fee-project-token terms. The leaf's `metadata` field is set to `(originChainId, referralProjectId)`
    /// so the sibling hook on `referralChainId` can atomically settle on `claimAndPush`. Reverts if the
    /// sucker isn't a registered, ENABLED sucker of the fee project. Skips (without reverting) on the usual
    /// no-token / no-volume / caught-up cases. `referralChainId` must not equal `block.chainid` (that's a
    /// local push — use `pushTo`).
    /// @param referralChainId The referrer's home EIP-155 chain ID. Must NOT equal `block.chainid`.
    /// @param referralProjectId The referring project on that chain.
    /// @param sucker The fee project's sucker pair to use; must bridge to `referralChainId` and be
    /// registered.
    /// @param terminalToken The terminal token to cash out into. Must be mapped on the sucker.
    /// @param minTokensReclaimed The minimum acceptable amount of terminal tokens to receive from the
    /// sucker's bonding-curve cash-out. Passes through to `sucker.prepare`. Callers MUST set this
    /// conservatively — passing `0` leaves the cash-out leg fully exposed to MEV sandwich attacks. The hook
    /// is permissionless, so the caller chooses their own slippage tolerance.
    /// @return bridged The number of fee-project tokens cashed out into the sucker (0 on skip).
    function bridgeRemote(
        uint256 referralChainId,
        uint256 referralProjectId,
        IJBSucker sucker,
        address terminalToken,
        uint256 minTokensReclaimed
    )
        external
        returns (uint256 bridged);

    /// @notice Burn the accumulated cross-chain referral credit for `(referralChainId, referralProjectId)`
    /// when NO sucker pair for the fee project peers to `referralChainId` — i.e. the credit is
    /// unbridgeable.
    /// @dev Permissionless. Burning here means: the entitled fee-project tokens for this referrer pair are
    /// removed from supply, returning the bridged terminal-token value (already in the fee project's
    /// balance from the original protocol-fee flow) to all existing fee-token holders pro-rata. This is the
    /// cross-chain analog of `claimAndPush`'s burn-on-strand path. Reverts with `SuckerExistsForChain` if
    /// any sucker for the fee project — active OR deprecated — peers to `referralChainId` (iterates
    /// `SUCKER_REGISTRY.allSuckersOf(FEE_PROJECT_ID)`, defensively `try/catch`ing `peerChainId()` so a
    /// fully broken sucker can't permanently block burns of unrelated chains' credit). Deprecated suckers
    /// stay settlement-eligible until they're truly removed, so credit routed through them is NOT
    /// stranded. Reverts on the usual malformed-args cases
    /// (`projectId == 0 || projectId == FEE_PROJECT_ID`, `chainId == 0`, `chainId == block.chainid`).
    /// Skips (without reverting) when there's nothing to burn (no recorded volume, or the high-water mark
    /// is already caught up). Advances `bridgedOutOf` by the burned amount so the burn is idempotent AND so
    /// a future sucker deployment for `referralChainId` can only bridge INCREMENTAL credit accumulated
    /// after the burn — the burned portion stays burned.
    /// @param referralChainId The referrer's home EIP-155 chain ID. Must NOT equal `block.chainid`. Must
    /// NOT have a sucker pair on the fee project.
    /// @param referralProjectId The referring project on that chain.
    /// @return burned The number of fee-project tokens burned (0 on skip).
    function burnUnbridgeableCreditFor(
        uint256 referralChainId,
        uint256 referralProjectId
    )
        external
        returns (uint256 burned);

    /// @notice Atomically claim a bridged credit and push it to the local distributor for the referrer's
    /// local-twin project.
    /// @dev Permissionless. Validates that `originChainId != block.chainid`, the sucker is a registered
    /// sucker of the fee project, the claim's beneficiary is this hook, and the leaf's `metadata` matches
    /// the asserted `(originChainId, referralProjectId)` pair (the merkle proof inside `sucker.claim`
    /// already authenticated `metadata` — the equality check here just enforces correct argument
    /// ordering). Then it calls `sucker.claim`, which deposits the bridged terminal tokens into the
    /// destination fee project's terminal AND mints destination fee-project tokens directly to this hook
    /// (the leaf's `beneficiary`). The hook measures the fee-project-token balance delta and forwards it
    /// to the local distributor for `referralProjectId`'s local twin. When the local twin has no
    /// `IJBToken` yet, the freshly-minted fee-project tokens are PARKED in the hook keyed by
    /// `(sucker, terminalToken, leafIndex)` — anyone can later call `pokeDeferredClaim` to release them
    /// once the referrer tokenizes. No `pushedOf` accounting on the destination side because the source
    /// chain's `bridgeRemote` already advanced its high-water mark.
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

    /// @notice Release a parked deferred-claim amount to the local distributor once the referral project's
    /// `IJBToken` has been deployed on this chain.
    /// @dev Permissionless. Looks up `parkedAmountOf[keccak256(abi.encode(sucker, terminalToken, leafIndex))]`,
    /// re-derives the referral project ID from `parkedReferralProjectIdOf` (so the caller can't redirect the
    /// release), resolves the referrer's `IJBToken`, and forwards the parked amount to the distributor. Clears
    /// the park BEFORE the external call so reentrancy in the distributor cannot double-spend the parked slot.
    /// Reverts with `NothingParked` when there's nothing to release, and with `StillStranded` when the
    /// referrer still has no `IJBToken`.
    /// @param sucker The fee project's sucker pair that produced the original parked leaf.
    /// @param terminalToken The terminal token of the original parked leaf.
    /// @param leafIndex The leaf index of the original parked leaf in the sucker's inbox tree.
    /// @return pushed The number of fee-project tokens released to the local distributor.
    function pokeDeferredClaim(
        IJBSucker sucker,
        address terminalToken,
        uint256 leafIndex
    )
        external
        returns (uint256 pushed);

    /// @notice Forward a same-chain referrer's accrued pro-rata share to the local distributor.
    /// @dev Permissionless. Reverts when `referralProjectId in {0, FEE_PROJECT_ID}`. Skips (without
    /// reverting) when the referrer has no `IJBToken` locally, when there's no recorded volume yet, when
    /// the entitled amount hasn't grown above the high-water mark, or when `referralChainId !=
    /// block.chainid` (cross-chain — use `bridgeRemote`).
    /// @param referralChainId The referrer's home EIP-155 chain ID. Must equal `block.chainid`.
    /// @param referralProjectId The referring project on that chain.
    /// @return pushed The number of tokens forwarded in this call (0 on skip).
    function pushTo(uint256 referralChainId, uint256 referralProjectId) external returns (uint256 pushed);
}
