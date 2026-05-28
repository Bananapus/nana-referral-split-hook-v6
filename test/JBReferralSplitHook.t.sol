// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";
import {JBSuckerState} from "@bananapus/suckers-v6/src/enums/JBSuckerState.sol";
import {IJBSucker} from "@bananapus/suckers-v6/src/interfaces/IJBSucker.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBClaim} from "@bananapus/suckers-v6/src/structs/JBClaim.sol";
import {JBLeaf} from "@bananapus/suckers-v6/src/structs/JBLeaf.sol";

import {JBReferralSplitHook} from "../src/JBReferralSplitHook.sol";
import {IJBReferralSplitHook} from "../src/interfaces/IJBReferralSplitHook.sol";

/// @notice Smoke tests for `JBReferralSplitHook`. Exercises construction, immutables, and the pure
/// `packLeafMetadata` encoding. Deeper integration coverage (mocked `feeVolumeByReferralOf`,
/// sucker bridge round-trips, distributor pushes) layers on in subsequent test files.
contract JBReferralSplitHookTest is Test {
    JBReferralSplitHook internal hook;

    address internal directory = makeAddr("directory");
    address internal store = makeAddr("store");
    address internal tokens = makeAddr("tokens");
    address internal distributor = makeAddr("distributor");
    address internal suckerRegistry = makeAddr("suckerRegistry");
    address internal terminal = makeAddr("terminal");
    uint256 internal constant FEE_PROJECT_ID = 1;

    function setUp() public {
        hook = new JBReferralSplitHook({
            directory: IJBDirectory(directory),
            store: IJBTerminalStore(store),
            tokens: IJBTokens(tokens),
            distributor: IJBDistributor(distributor),
            suckerRegistry: IJBSuckerRegistry(suckerRegistry),
            terminal: terminal,
            feeProjectId: FEE_PROJECT_ID
        });
    }

    function test_constructor_setsImmutables() public view {
        assertEq(address(hook.DIRECTORY()), directory);
        assertEq(address(hook.STORE()), store);
        assertEq(address(hook.TOKENS()), tokens);
        assertEq(address(hook.DISTRIBUTOR()), distributor);
        assertEq(address(hook.SUCKER_REGISTRY()), suckerRegistry);
        assertEq(hook.TERMINAL(), terminal);
        assertEq(hook.FEE_PROJECT_ID(), FEE_PROJECT_ID);
    }

    function test_supportsInterface() public view {
        assertTrue(hook.supportsInterface(type(IJBSplitHook).interfaceId));
        assertTrue(hook.supportsInterface(type(IJBReferralSplitHook).interfaceId));
        assertTrue(hook.supportsInterface(0x01ffc9a7)); // ERC-165
        assertFalse(hook.supportsInterface(0xdeadbeef));
    }

    function test_pushTo_revertsOnZeroReferralProjectId() public {
        vm.expectRevert(JBReferralSplitHook.JBReferralSplitHook_InvalidReferralProjectId.selector);
        hook.pushTo({referralChainId: block.chainid, referralProjectId: 0});
    }

    function test_pushTo_revertsOnFeeProjectIdSelfReference() public {
        vm.expectRevert(JBReferralSplitHook.JBReferralSplitHook_InvalidReferralProjectId.selector);
        hook.pushTo({referralChainId: block.chainid, referralProjectId: FEE_PROJECT_ID});
    }

    function test_pushTo_skipsRemoteChainCredit() public {
        // A referrer on a different chain — `pushTo` is strictly same-chain. Use `bridgeRemote` for cross-chain.
        // Same-chain ledger stays untouched, and so does the cross-chain ledger (since `pushTo` never writes
        // there regardless of input).
        uint256 remoteChainId = block.chainid + 1;
        assertEq(hook.pushTo({referralChainId: remoteChainId, referralProjectId: 42}), 0);
        assertEq(hook.pushedLocallyOf(42), 0);
        assertEq(hook.bridgedOutOf({referralChainId: remoteChainId, referralProjectId: 42}), 0);
    }

    function test_pushTo_noopsWhenTotalVolumeIsZero() public {
        vm.mockCall(store, abi.encodeCall(IJBTerminalStore.totalFeeVolumeOf, (terminal)), abi.encode(uint256(0)));
        assertEq(hook.pushTo({referralChainId: block.chainid, referralProjectId: 42}), 0);
        assertEq(hook.pushedLocallyOf(42), 0);
    }

    function test_bridgeRemote_revertsOnSameChain() public {
        // Bridging to the current chain would mean using a sucker for a same-chain settlement, which is wrong.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBReferralSplitHook.JBReferralSplitHook_WrongBridgeTarget.selector, block.chainid, block.chainid
            )
        );
        hook.bridgeRemote({
            referralChainId: block.chainid,
            referralProjectId: 42,
            sucker: IJBSucker(makeAddr("sucker")),
            terminalToken: makeAddr("terminalToken"),
            minTokensReclaimed: 0
        });
    }

    function test_bridgeRemote_revertsOnZeroOrFeeProjectId() public {
        vm.expectRevert(JBReferralSplitHook.JBReferralSplitHook_InvalidReferralProjectId.selector);
        hook.bridgeRemote({
            referralChainId: block.chainid + 1,
            referralProjectId: 0,
            sucker: IJBSucker(makeAddr("sucker")),
            terminalToken: makeAddr("terminalToken"),
            minTokensReclaimed: 0
        });

        vm.expectRevert(JBReferralSplitHook.JBReferralSplitHook_InvalidReferralProjectId.selector);
        hook.bridgeRemote({
            referralChainId: block.chainid + 1,
            referralProjectId: FEE_PROJECT_ID,
            sucker: IJBSucker(makeAddr("sucker")),
            terminalToken: makeAddr("terminalToken"),
            minTokensReclaimed: 0
        });
    }

    function test_bridgeRemote_revertsOnNonRegisteredSucker() public {
        IJBSucker sucker = IJBSucker(makeAddr("rogueSucker"));
        vm.mockCall(
            suckerRegistry,
            abi.encodeCall(IJBSuckerRegistry.isSuckerOf, (FEE_PROJECT_ID, address(sucker))),
            abi.encode(false)
        );

        vm.expectRevert(
            abi.encodeWithSelector(JBReferralSplitHook.JBReferralSplitHook_NotASucker.selector, address(sucker))
        );
        hook.bridgeRemote({
            referralChainId: block.chainid + 1,
            referralProjectId: 42,
            sucker: sucker,
            terminalToken: makeAddr("terminalToken"),
            minTokensReclaimed: 0
        });
    }

    function test_claimAndPush_revertsOnNonRegisteredSucker() public {
        IJBSucker sucker = IJBSucker(makeAddr("rogueSucker"));
        vm.mockCall(
            suckerRegistry,
            abi.encodeCall(IJBSuckerRegistry.isSuckerOf, (FEE_PROJECT_ID, address(sucker))),
            abi.encode(false)
        );

        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: makeAddr("terminalToken"),
            leaf: JBLeaf({
                index: 0,
                beneficiary: bytes32(uint256(uint160(address(hook)))),
                projectTokenCount: 1 ether,
                terminalTokenAmount: 1 ether,
                metadata: hook.packLeafMetadata({originChainId: 1, referralProjectId: 42})
            }),
            proof: proof
        });

        vm.expectRevert(
            abi.encodeWithSelector(JBReferralSplitHook.JBReferralSplitHook_NotASucker.selector, address(sucker))
        );
        hook.claimAndPush({originChainId: 1, referralProjectId: 42, sucker: sucker, claimData: claimData});
    }

    function test_claimAndPush_revertsOnMetadataMismatch() public {
        IJBSucker sucker = IJBSucker(makeAddr("sucker"));
        vm.mockCall(
            suckerRegistry,
            abi.encodeCall(IJBSuckerRegistry.isSuckerOf, (FEE_PROJECT_ID, address(sucker))),
            abi.encode(true)
        );

        bytes32[32] memory proof;
        // Caller claims this leaf is for projectId 99 — but the leaf's metadata was packed for projectId 42.
        bytes32 honestMetadata = hook.packLeafMetadata({originChainId: 7, referralProjectId: 42});
        JBClaim memory claimData = JBClaim({
            token: makeAddr("terminalToken"),
            leaf: JBLeaf({
                index: 0,
                beneficiary: bytes32(uint256(uint160(address(hook)))),
                projectTokenCount: 1 ether,
                terminalTokenAmount: 1 ether,
                metadata: honestMetadata
            }),
            proof: proof
        });

        bytes32 lyingMetadata = hook.packLeafMetadata({originChainId: 7, referralProjectId: 99});
        vm.expectRevert(
            abi.encodeWithSelector(
                JBReferralSplitHook.JBReferralSplitHook_LeafMetadataMismatch.selector, lyingMetadata, honestMetadata
            )
        );
        hook.claimAndPush({originChainId: 7, referralProjectId: 99, sucker: sucker, claimData: claimData});
    }

    function test_claimAndPush_revertsOnLocalOrigin() public {
        // `claimAndPush` is exclusively for cross-chain settlement — a leaf "originating" from `block.chainid`
        // would let a caller bypass the same-chain `pushTo` high-water-mark math by hand-crafting a leaf and
        // running it through this path. Block it up front.
        IJBSucker sucker = IJBSucker(makeAddr("sucker"));
        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: makeAddr("terminalToken"),
            leaf: JBLeaf({
                index: 0,
                beneficiary: bytes32(uint256(uint160(address(hook)))),
                projectTokenCount: 1 ether,
                terminalTokenAmount: 1 ether,
                metadata: hook.packLeafMetadata({originChainId: block.chainid, referralProjectId: 42})
            }),
            proof: proof
        });

        vm.expectRevert(
            abi.encodeWithSelector(JBReferralSplitHook.JBReferralSplitHook_OriginIsLocal.selector, block.chainid)
        );
        hook.claimAndPush({originChainId: block.chainid, referralProjectId: 42, sucker: sucker, claimData: claimData});
    }

    function test_bridgeRemote_revertsOnSuckerPeerMismatch() public {
        // Registered sucker that bridges to chain 999, but caller asks to credit a referrer on chain 7 —
        // routing the credit through this sucker would land it on the wrong omnichain leg.
        uint256 referrerChain = 7;
        uint256 suckerPeerChain = 999;
        IJBSucker sucker = IJBSucker(makeAddr("misroutedSucker"));
        vm.mockCall(
            suckerRegistry,
            abi.encodeCall(IJBSuckerRegistry.isSuckerOf, (FEE_PROJECT_ID, address(sucker))),
            abi.encode(true)
        );
        // The deprecated-sucker rejection runs before the peer-mismatch check; mock ENABLED state so we reach
        // the peer-mismatch branch we're testing.
        vm.mockCall(address(sucker), abi.encodeCall(IJBSucker.state, ()), abi.encode(JBSuckerState.ENABLED));
        vm.mockCall(address(sucker), abi.encodeCall(IJBSucker.peerChainId, ()), abi.encode(suckerPeerChain));

        vm.expectRevert(
            abi.encodeWithSelector(
                JBReferralSplitHook.JBReferralSplitHook_SuckerPeerMismatch.selector, referrerChain, suckerPeerChain
            )
        );
        hook.bridgeRemote({
            referralChainId: referrerChain,
            referralProjectId: 42,
            sucker: sucker,
            terminalToken: makeAddr("terminalToken"),
            minTokensReclaimed: 0
        });
    }

    function test_packLeafMetadata_roundTrips() public view {
        uint256 originChainId = 12_345;
        uint256 referralProjectId = 67_890;
        bytes32 packed = hook.packLeafMetadata({originChainId: originChainId, referralProjectId: referralProjectId});

        // Lower 64 bits = projectId; bits [95:64] = chainId.
        uint256 raw = uint256(packed);
        assertEq(raw & type(uint64).max, referralProjectId, "projectId in lower 64 bits");
        assertEq((raw >> 64) & type(uint32).max, originChainId, "chainId in bits [95:64]");
        assertEq(raw >> 96, 0, "upper 160 bits reserved (zero)");
    }

    function test_packLeafMetadata_revertsOnChainIdOverflow() public {
        uint256 oversized = uint256(type(uint32).max) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(JBReferralSplitHook.JBReferralSplitHook_ChainIdTooLarge.selector, oversized)
        );
        hook.packLeafMetadata({originChainId: oversized, referralProjectId: 1});
    }

    function test_packLeafMetadata_revertsOnProjectIdOverflow() public {
        uint256 oversized = uint256(type(uint64).max) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                JBReferralSplitHook.JBReferralSplitHook_ReferralProjectIdTooLarge.selector, oversized
            )
        );
        hook.packLeafMetadata({originChainId: 1, referralProjectId: oversized});
    }

    //*********************************************************************//
    // ---------- F-REF-B: bridgeRemote rejects deprecated suckers --------- //
    //*********************************************************************//

    function test_bridgeRemote_revertsOnDeprecatedSucker() public {
        IJBSucker sucker = IJBSucker(makeAddr("deprecatedSucker"));
        vm.mockCall(
            suckerRegistry,
            abi.encodeCall(IJBSuckerRegistry.isSuckerOf, (FEE_PROJECT_ID, address(sucker))),
            abi.encode(true)
        );
        vm.mockCall(address(sucker), abi.encodeCall(IJBSucker.state, ()), abi.encode(JBSuckerState.DEPRECATED));

        vm.expectRevert(
            abi.encodeWithSelector(
                JBReferralSplitHook.JBReferralSplitHook_SuckerNotEnabled.selector,
                address(sucker),
                JBSuckerState.DEPRECATED
            )
        );
        hook.bridgeRemote({
            referralChainId: block.chainid + 1,
            referralProjectId: 42,
            sucker: sucker,
            terminalToken: makeAddr("terminalToken"),
            minTokensReclaimed: 0
        });
    }

    function test_bridgeRemote_revertsOnSendingDisabledSucker() public {
        IJBSucker sucker = IJBSucker(makeAddr("sendingDisabledSucker"));
        vm.mockCall(
            suckerRegistry,
            abi.encodeCall(IJBSuckerRegistry.isSuckerOf, (FEE_PROJECT_ID, address(sucker))),
            abi.encode(true)
        );
        vm.mockCall(address(sucker), abi.encodeCall(IJBSucker.state, ()), abi.encode(JBSuckerState.SENDING_DISABLED));

        vm.expectRevert(
            abi.encodeWithSelector(
                JBReferralSplitHook.JBReferralSplitHook_SuckerNotEnabled.selector,
                address(sucker),
                JBSuckerState.SENDING_DISABLED
            )
        );
        hook.bridgeRemote({
            referralChainId: block.chainid + 1,
            referralProjectId: 42,
            sucker: sucker,
            terminalToken: makeAddr("terminalToken"),
            minTokensReclaimed: 0
        });
    }

    //*********************************************************************//
    // - claimAndPush: settledLeafOf idempotency + front-run authentication - //
    //*********************************************************************//

    function test_claimAndPush_revertsOnAlreadySettled() public {
        // Setup: a previous successful claim has marked the leaf as settled. The second attempt — even with
        // valid claimData — must revert with LeafAlreadySettled to prevent double-processing.
        IJBSucker sucker = IJBSucker(makeAddr("sucker"));
        address terminalToken = makeAddr("terminalToken");

        vm.mockCall(
            suckerRegistry,
            abi.encodeCall(IJBSuckerRegistry.isSuckerOf, (FEE_PROJECT_ID, address(sucker))),
            abi.encode(true)
        );

        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: terminalToken,
            leaf: JBLeaf({
                index: 7,
                beneficiary: bytes32(uint256(uint160(address(hook)))),
                projectTokenCount: 100,
                terminalTokenAmount: 50,
                metadata: hook.packLeafMetadata({originChainId: 10, referralProjectId: 42})
            }),
            proof: proof
        });

        // Mock a successful first claim via the front-run path (sucker already executed). Local twin has no
        // IJBToken, so the first call PARKS the minted amount and sets settledLeafOf. The second call
        // must then revert with LeafAlreadySettled.
        vm.mockCall(
            address(sucker),
            abi.encodeCall(IJBSucker.executedLeafHashOf, (terminalToken, 7)),
            abi.encode(
                keccak256(
                    abi.encodePacked(
                        claimData.leaf.projectTokenCount,
                        claimData.leaf.terminalTokenAmount,
                        claimData.leaf.beneficiary,
                        claimData.leaf.metadata
                    )
                )
            )
        );
        vm.mockCall(tokens, abi.encodeCall(IJBTokens.tokenOf, (FEE_PROJECT_ID)), abi.encode(address(0xfee)));
        vm.mockCall(tokens, abi.encodeCall(IJBTokens.tokenOf, (uint256(42))), abi.encode(address(0)));

        // First call settles via front-run path. Park-on-strand fires because the local twin has no
        // IJBToken — no controller burn call is needed.
        hook.claimAndPush({originChainId: 10, referralProjectId: 42, sucker: sucker, claimData: claimData});

        // The park mapping is now populated keyed by `(sucker, terminalToken, leafIndex)`.
        bytes32 strandedKey = keccak256(abi.encode(sucker, terminalToken, uint256(7)));
        assertEq(hook.parkedAmountOf(strandedKey), 100, "parked amount should equal projectTokenCount");
        assertEq(hook.parkedReferralProjectIdOf(strandedKey), 42, "parked refProjectId should equal local twin");

        // Second call with same leaf reverts.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBReferralSplitHook.JBReferralSplitHook_LeafAlreadySettled.selector,
                address(sucker),
                terminalToken,
                uint256(7)
            )
        );
        hook.claimAndPush({originChainId: 10, referralProjectId: 42, sucker: sucker, claimData: claimData});
    }

    //*********************************************************************//
    // ----- D6: park-and-retry deferred claim instead of burn-on-strand --- //
    //*********************************************************************//

    function test_claimAndPush_parksWhenLocalTwinHasNoToken() public {
        // When the local twin's TOKENS.tokenOf returns address(0), the freshly-minted fee-project tokens
        // are parked (not burned). Asserts: park mapping populated, ParkedOnStrand emitted, NO controller
        // burn call (we don't mock it — if the contract tried to burn the test would revert from the
        // missing mock), ClaimedRemote(pushed: 0) still emitted.
        IJBSucker sucker = IJBSucker(makeAddr("sucker"));
        address terminalToken = makeAddr("terminalToken");
        uint256 originChainId = 10;
        uint256 referralProjectId = 42;
        uint256 leafIndex = 3;
        uint256 projectTokenCount = 1234;

        vm.mockCall(
            suckerRegistry,
            abi.encodeCall(IJBSuckerRegistry.isSuckerOf, (FEE_PROJECT_ID, address(sucker))),
            abi.encode(true)
        );

        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: terminalToken,
            leaf: JBLeaf({
                index: leafIndex,
                beneficiary: bytes32(uint256(uint160(address(hook)))),
                projectTokenCount: projectTokenCount,
                terminalTokenAmount: 50,
                metadata: hook.packLeafMetadata({originChainId: originChainId, referralProjectId: referralProjectId})
            }),
            proof: proof
        });

        // Front-run path: sucker already executed this leaf (so the hook does not call sucker.claim).
        bytes32 storedHash = keccak256(
            abi.encodePacked(
                claimData.leaf.projectTokenCount,
                claimData.leaf.terminalTokenAmount,
                claimData.leaf.beneficiary,
                claimData.leaf.metadata
            )
        );
        vm.mockCall(
            address(sucker),
            abi.encodeCall(IJBSucker.executedLeafHashOf, (terminalToken, leafIndex)),
            abi.encode(storedHash)
        );
        vm.mockCall(tokens, abi.encodeCall(IJBTokens.tokenOf, (FEE_PROJECT_ID)), abi.encode(address(0xfee)));
        // Local twin has no IJBToken — triggers the park-on-strand path.
        vm.mockCall(tokens, abi.encodeCall(IJBTokens.tokenOf, (referralProjectId)), abi.encode(address(0)));

        // The controller is NOT mocked — if claimAndPush tried to burn, the call to a non-existent
        // controller (DIRECTORY.controllerOf is also unmocked) would revert and fail the test.

        // Expect ParkedOnStrand emitted with exactly these fields.
        vm.expectEmit(true, true, false, true, address(hook));
        emit IJBReferralSplitHook.ParkedOnStrand({
            originChainId: originChainId,
            referralProjectId: referralProjectId,
            sucker: sucker,
            terminalToken: terminalToken,
            leafIndex: leafIndex,
            feeProjectParked: projectTokenCount,
            caller: address(this)
        });
        // And ClaimedRemote with pushed = 0.
        vm.expectEmit(true, true, true, true, address(hook));
        emit IJBReferralSplitHook.ClaimedRemote({
            originChainId: originChainId,
            referralProjectId: referralProjectId,
            terminalToken: terminalToken,
            terminalReceived: claimData.leaf.terminalTokenAmount,
            feeProjectMinted: projectTokenCount,
            pushed: 0,
            caller: address(this)
        });
        uint256 pushed = hook.claimAndPush({
            originChainId: originChainId, referralProjectId: referralProjectId, sucker: sucker, claimData: claimData
        });
        assertEq(pushed, 0, "no immediate push when stranded");

        // Park mapping populated.
        bytes32 strandedKey = keccak256(abi.encode(sucker, terminalToken, leafIndex));
        assertEq(hook.parkedAmountOf(strandedKey), projectTokenCount, "parked amount");
        assertEq(hook.parkedReferralProjectIdOf(strandedKey), referralProjectId, "parked refProjectId");
        // Leaf is settled.
        assertTrue(hook.settledLeafOf(sucker, terminalToken, leafIndex), "leaf marked settled");
    }

    function test_claimAndPush_parkSetsKeyExactlyOnce() public {
        // A second claimAndPush with the same `(sucker, terminalToken, leafIndex)` must revert
        // LeafAlreadySettled — the park happens exactly once per leaf, and the bitmap protects re-entry.
        IJBSucker sucker = IJBSucker(makeAddr("sucker"));
        address terminalToken = makeAddr("terminalToken");

        vm.mockCall(
            suckerRegistry,
            abi.encodeCall(IJBSuckerRegistry.isSuckerOf, (FEE_PROJECT_ID, address(sucker))),
            abi.encode(true)
        );

        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: terminalToken,
            leaf: JBLeaf({
                index: 9,
                beneficiary: bytes32(uint256(uint160(address(hook)))),
                projectTokenCount: 77,
                terminalTokenAmount: 33,
                metadata: hook.packLeafMetadata({originChainId: 10, referralProjectId: 42})
            }),
            proof: proof
        });

        bytes32 storedHash = keccak256(
            abi.encodePacked(
                claimData.leaf.projectTokenCount,
                claimData.leaf.terminalTokenAmount,
                claimData.leaf.beneficiary,
                claimData.leaf.metadata
            )
        );
        vm.mockCall(
            address(sucker),
            abi.encodeCall(IJBSucker.executedLeafHashOf, (terminalToken, uint256(9))),
            abi.encode(storedHash)
        );
        vm.mockCall(tokens, abi.encodeCall(IJBTokens.tokenOf, (FEE_PROJECT_ID)), abi.encode(address(0xfee)));
        vm.mockCall(tokens, abi.encodeCall(IJBTokens.tokenOf, (uint256(42))), abi.encode(address(0)));

        // First call parks.
        hook.claimAndPush({originChainId: 10, referralProjectId: 42, sucker: sucker, claimData: claimData});

        // Second call reverts — even though the local twin still has no token, the leaf is already settled
        // and cannot be re-parked.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBReferralSplitHook.JBReferralSplitHook_LeafAlreadySettled.selector,
                address(sucker),
                terminalToken,
                uint256(9)
            )
        );
        hook.claimAndPush({originChainId: 10, referralProjectId: 42, sucker: sucker, claimData: claimData});
    }

    function test_pokeDeferredClaim_succeedsAfterTokenization() public {
        // Round trip: park via claimAndPush -> tokenize the referrer -> call pokeDeferredClaim ->
        // assert _fundDistributor effects fire (forceApprove + fund) -> mapping cleared.
        IJBSucker sucker = IJBSucker(makeAddr("sucker"));
        address terminalToken = makeAddr("terminalToken");
        uint256 leafIndex = 5;
        uint256 projectTokenCount = 555;
        uint256 referralProjectId = 42;
        address feeERC20 = makeAddr("feeERC20");
        address refERC20 = makeAddr("refERC20");

        vm.mockCall(
            suckerRegistry,
            abi.encodeCall(IJBSuckerRegistry.isSuckerOf, (FEE_PROJECT_ID, address(sucker))),
            abi.encode(true)
        );

        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: terminalToken,
            leaf: JBLeaf({
                index: leafIndex,
                beneficiary: bytes32(uint256(uint160(address(hook)))),
                projectTokenCount: projectTokenCount,
                terminalTokenAmount: 50,
                metadata: hook.packLeafMetadata({originChainId: 10, referralProjectId: referralProjectId})
            }),
            proof: proof
        });

        bytes32 storedHash = keccak256(
            abi.encodePacked(
                claimData.leaf.projectTokenCount,
                claimData.leaf.terminalTokenAmount,
                claimData.leaf.beneficiary,
                claimData.leaf.metadata
            )
        );
        vm.mockCall(
            address(sucker),
            abi.encodeCall(IJBSucker.executedLeafHashOf, (terminalToken, leafIndex)),
            abi.encode(storedHash)
        );
        vm.mockCall(tokens, abi.encodeCall(IJBTokens.tokenOf, (FEE_PROJECT_ID)), abi.encode(feeERC20));
        // Round 1: ref has no IJBToken — claim parks.
        vm.mockCall(tokens, abi.encodeCall(IJBTokens.tokenOf, (referralProjectId)), abi.encode(address(0)));
        hook.claimAndPush({
            originChainId: 10, referralProjectId: referralProjectId, sucker: sucker, claimData: claimData
        });
        bytes32 strandedKey = keccak256(abi.encode(sucker, terminalToken, leafIndex));
        assertEq(hook.parkedAmountOf(strandedKey), projectTokenCount, "park populated");

        // Round 2: referrer tokenizes — TOKENS.tokenOf now returns a real IJBToken.
        vm.mockCall(tokens, abi.encodeCall(IJBTokens.tokenOf, (referralProjectId)), abi.encode(refERC20));
        // The distributor pull path: forceApprove(distributor, amount), DISTRIBUTOR.fund(refToken, fee, amount),
        // forceApprove(distributor, 0). Mock the fee-token approve and the distributor's fund.
        vm.mockCall(feeERC20, abi.encodeWithSignature("approve(address,uint256)"), abi.encode(true));
        vm.mockCall(
            feeERC20,
            abi.encodeWithSignature("allowance(address,address)", address(hook), distributor),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            distributor, abi.encodeCall(IJBDistributor.fund, (refERC20, IERC20(feeERC20), projectTokenCount)), ""
        );

        // Expect a fund call on the distributor with exact args.
        vm.expectCall(
            distributor, abi.encodeCall(IJBDistributor.fund, (refERC20, IERC20(feeERC20), projectTokenCount)), 1
        );
        // Expect a PokedDeferredClaim event.
        vm.expectEmit(true, true, false, true, address(hook));
        emit IJBReferralSplitHook.PokedDeferredClaim({
            strandedKey: strandedKey,
            referralProjectId: referralProjectId,
            amount: projectTokenCount,
            caller: address(this)
        });
        uint256 pushed = hook.pokeDeferredClaim({sucker: sucker, terminalToken: terminalToken, leafIndex: leafIndex});
        assertEq(pushed, projectTokenCount, "released full parked amount");

        // Mapping cleared.
        assertEq(hook.parkedAmountOf(strandedKey), 0, "park cleared");
        assertEq(hook.parkedReferralProjectIdOf(strandedKey), 0, "park refId cleared");
    }

    function test_pokeDeferredClaim_revertsWhenStillStranded() public {
        // Park, then call pokeDeferredClaim without mocking the referrer's IJBToken — still address(0) —
        // and assert StillStranded reverts with the parked refProjectId.
        IJBSucker sucker = IJBSucker(makeAddr("sucker"));
        address terminalToken = makeAddr("terminalToken");
        uint256 leafIndex = 11;
        uint256 referralProjectId = 42;

        vm.mockCall(
            suckerRegistry,
            abi.encodeCall(IJBSuckerRegistry.isSuckerOf, (FEE_PROJECT_ID, address(sucker))),
            abi.encode(true)
        );

        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: terminalToken,
            leaf: JBLeaf({
                index: leafIndex,
                beneficiary: bytes32(uint256(uint160(address(hook)))),
                projectTokenCount: 88,
                terminalTokenAmount: 44,
                metadata: hook.packLeafMetadata({originChainId: 10, referralProjectId: referralProjectId})
            }),
            proof: proof
        });
        bytes32 storedHash = keccak256(
            abi.encodePacked(
                claimData.leaf.projectTokenCount,
                claimData.leaf.terminalTokenAmount,
                claimData.leaf.beneficiary,
                claimData.leaf.metadata
            )
        );
        vm.mockCall(
            address(sucker),
            abi.encodeCall(IJBSucker.executedLeafHashOf, (terminalToken, leafIndex)),
            abi.encode(storedHash)
        );
        vm.mockCall(tokens, abi.encodeCall(IJBTokens.tokenOf, (FEE_PROJECT_ID)), abi.encode(address(0xfee)));
        vm.mockCall(tokens, abi.encodeCall(IJBTokens.tokenOf, (referralProjectId)), abi.encode(address(0)));
        hook.claimAndPush({
            originChainId: 10, referralProjectId: referralProjectId, sucker: sucker, claimData: claimData
        });

        // Local twin still has no IJBToken — poke must revert.
        vm.expectRevert(
            abi.encodeWithSelector(JBReferralSplitHook.JBReferralSplitHook_StillStranded.selector, referralProjectId)
        );
        hook.pokeDeferredClaim({sucker: sucker, terminalToken: terminalToken, leafIndex: leafIndex});
    }

    function test_pokeDeferredClaim_revertsWhenNothingParked() public {
        // Empty key — never parked.
        IJBSucker sucker = IJBSucker(makeAddr("sucker"));
        address terminalToken = makeAddr("terminalToken");
        uint256 leafIndex = 99;
        bytes32 strandedKey = keccak256(abi.encode(sucker, terminalToken, leafIndex));
        vm.expectRevert(
            abi.encodeWithSelector(JBReferralSplitHook.JBReferralSplitHook_NothingParked.selector, strandedKey)
        );
        hook.pokeDeferredClaim({sucker: sucker, terminalToken: terminalToken, leafIndex: leafIndex});
    }

    function test_pokeDeferredClaim_revertsOnReplay() public {
        // Park, then poke successfully, then poke again — second poke must revert NothingParked because
        // the mapping was cleared.
        IJBSucker sucker = IJBSucker(makeAddr("sucker"));
        address terminalToken = makeAddr("terminalToken");
        uint256 leafIndex = 13;
        uint256 referralProjectId = 42;
        uint256 projectTokenCount = 200;
        address feeERC20 = makeAddr("feeERC20");
        address refERC20 = makeAddr("refERC20");

        vm.mockCall(
            suckerRegistry,
            abi.encodeCall(IJBSuckerRegistry.isSuckerOf, (FEE_PROJECT_ID, address(sucker))),
            abi.encode(true)
        );

        bytes32[32] memory proof;
        JBClaim memory claimData = JBClaim({
            token: terminalToken,
            leaf: JBLeaf({
                index: leafIndex,
                beneficiary: bytes32(uint256(uint160(address(hook)))),
                projectTokenCount: projectTokenCount,
                terminalTokenAmount: 50,
                metadata: hook.packLeafMetadata({originChainId: 10, referralProjectId: referralProjectId})
            }),
            proof: proof
        });
        bytes32 storedHash = keccak256(
            abi.encodePacked(
                claimData.leaf.projectTokenCount,
                claimData.leaf.terminalTokenAmount,
                claimData.leaf.beneficiary,
                claimData.leaf.metadata
            )
        );
        vm.mockCall(
            address(sucker),
            abi.encodeCall(IJBSucker.executedLeafHashOf, (terminalToken, leafIndex)),
            abi.encode(storedHash)
        );
        vm.mockCall(tokens, abi.encodeCall(IJBTokens.tokenOf, (FEE_PROJECT_ID)), abi.encode(feeERC20));
        vm.mockCall(tokens, abi.encodeCall(IJBTokens.tokenOf, (referralProjectId)), abi.encode(address(0)));
        hook.claimAndPush({
            originChainId: 10, referralProjectId: referralProjectId, sucker: sucker, claimData: claimData
        });

        // Tokenize and poke once.
        vm.mockCall(tokens, abi.encodeCall(IJBTokens.tokenOf, (referralProjectId)), abi.encode(refERC20));
        vm.mockCall(feeERC20, abi.encodeWithSignature("approve(address,uint256)"), abi.encode(true));
        vm.mockCall(
            feeERC20,
            abi.encodeWithSignature("allowance(address,address)", address(hook), distributor),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            distributor, abi.encodeCall(IJBDistributor.fund, (refERC20, IERC20(feeERC20), projectTokenCount)), ""
        );
        hook.pokeDeferredClaim({sucker: sucker, terminalToken: terminalToken, leafIndex: leafIndex});

        // Second poke must revert.
        bytes32 strandedKey = keccak256(abi.encode(sucker, terminalToken, leafIndex));
        vm.expectRevert(
            abi.encodeWithSelector(JBReferralSplitHook.JBReferralSplitHook_NothingParked.selector, strandedKey)
        );
        hook.pokeDeferredClaim({sucker: sucker, terminalToken: terminalToken, leafIndex: leafIndex});
    }

    function test_claimAndPush_frontRunHashMismatch_reverts() public {
        // Setup: leaf at index 7 was front-run by an external sucker.claim. The sucker stored the hash of the
        // REAL leaf data. Caller submits fabricated claimData with the same index but tampered metadata
        // (different referralProjectId), trying to redirect settlement.
        IJBSucker sucker = IJBSucker(makeAddr("sucker"));
        address terminalToken = makeAddr("terminalToken");
        bytes32[32] memory proof;

        // The REAL executed leaf was for referralProjectId 42.
        bytes32 realMetadata = hook.packLeafMetadata({originChainId: 10, referralProjectId: 42});
        bytes32 realLeafHash = keccak256(
            abi.encodePacked(uint256(100), uint256(50), bytes32(uint256(uint160(address(hook)))), realMetadata)
        );

        // Caller fakes claimData for referralProjectId 99 (their own project) at the same index.
        bytes32 fakeMetadata = hook.packLeafMetadata({originChainId: 10, referralProjectId: 99});
        JBClaim memory fakeClaim = JBClaim({
            token: terminalToken,
            leaf: JBLeaf({
                index: 7,
                beneficiary: bytes32(uint256(uint160(address(hook)))),
                projectTokenCount: 100,
                terminalTokenAmount: 50,
                metadata: fakeMetadata
            }),
            proof: proof
        });
        bytes32 fakeLeafHash = keccak256(
            abi.encodePacked(uint256(100), uint256(50), bytes32(uint256(uint160(address(hook)))), fakeMetadata)
        );

        vm.mockCall(
            suckerRegistry,
            abi.encodeCall(IJBSuckerRegistry.isSuckerOf, (FEE_PROJECT_ID, address(sucker))),
            abi.encode(true)
        );
        // Sucker stores the REAL leaf's hash, not the fake one.
        vm.mockCall(
            address(sucker), abi.encodeCall(IJBSucker.executedLeafHashOf, (terminalToken, 7)), abi.encode(realLeafHash)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                JBReferralSplitHook.JBReferralSplitHook_FrontRunLeafMismatch.selector, fakeLeafHash, realLeafHash
            )
        );
        hook.claimAndPush({originChainId: 10, referralProjectId: 99, sucker: sucker, claimData: fakeClaim});
    }

    //*********************************************************************//
    // ---- burnUnbridgeableCreditFor uses allSuckersOf (includes dep'd) --- //
    //*********************************************************************//

    function test_burnUnbridgeable_revertsWhenDeprecatedSuckerPeersToChain() public {
        // A sucker exists for chain 11 but has been deprecated-and-removed (now lives only in `allSuckersOf`,
        // not in `suckersOf`). Burning credit for chain 11 must still revert because the credit is still
        // bridgeable through the deprecated sucker.
        address depSucker = makeAddr("deprecatedSuckerToChain11");
        address[] memory all = new address[](1);
        all[0] = depSucker;

        vm.mockCall(suckerRegistry, abi.encodeCall(IJBSuckerRegistry.allSuckersOf, (FEE_PROJECT_ID)), abi.encode(all));
        vm.mockCall(depSucker, abi.encodeCall(IJBSucker.peerChainId, ()), abi.encode(uint256(11)));

        vm.expectRevert(
            abi.encodeWithSelector(
                JBReferralSplitHook.JBReferralSplitHook_SuckerExistsForChain.selector, depSucker, uint256(11)
            )
        );
        hook.burnUnbridgeableCreditFor({referralChainId: 11, referralProjectId: 42});
    }

    // NOTE: `test_burnUnbridgeable_skipsBrokenPeerChainId` (try/catch on peerChainId) is best validated in the
    // fork-test layer where a real broken sucker can be constructed and the full `processSplitWith` -> burn
    // path runs end-to-end. The unit-test layer here doesn't have a clean way to populate `totalDeposited`
    // (which requires constructing a real `JBSplitHookContext`). See `deploy-all-v6/test/fork/
    // ReferralRewardCrossChainFork.t.sol` for that integration coverage.
}
