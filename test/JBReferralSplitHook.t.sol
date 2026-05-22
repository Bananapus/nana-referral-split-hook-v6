// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";
import {IJBSucker} from "@bananapus/suckers-v6/src/interfaces/IJBSucker.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBClaim} from "@bananapus/suckers-v6/src/structs/JBClaim.sol";
import {JBLeaf} from "@bananapus/suckers-v6/src/structs/JBLeaf.sol";

import {JBReferralSplitHook} from "../src/JBReferralSplitHook.sol";
import {IJBReferralSplitHook} from "../src/interfaces/IJBReferralSplitHook.sol";

/// @notice Smoke tests for `JBReferralSplitHook`. Full unit + integration coverage layers on once
/// `@bananapus/core-v6` 0.0.59 and `@bananapus/suckers-v6` 0.0.50 (with the nested
/// `feeVolumeByReferralOf(terminal, chainId, projectId)` mapping and the `bytes32 metadata` leaf field) are published.
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
        vm.expectRevert(IJBReferralSplitHook.JBReferralSplitHook_InvalidReferralProjectId.selector);
        hook.pushTo({referralChainId: block.chainid, referralProjectId: 0});
    }

    function test_pushTo_revertsOnFeeProjectIdSelfReference() public {
        vm.expectRevert(IJBReferralSplitHook.JBReferralSplitHook_InvalidReferralProjectId.selector);
        hook.pushTo({referralChainId: block.chainid, referralProjectId: FEE_PROJECT_ID});
    }

    function test_pushTo_skipsRemoteChainCredit() public {
        // A referrer on a different chain — `pushTo` is strictly same-chain. Use `bridgeRemote` for cross-chain.
        uint256 remoteChainId = block.chainid + 1;
        assertEq(hook.pushTo({referralChainId: remoteChainId, referralProjectId: 42}), 0);
        assertEq(hook.pushedOf({referralChainId: remoteChainId, referralProjectId: 42}), 0);
    }

    function test_pushTo_noopsWhenTotalVolumeIsZero() public {
        vm.mockCall(store, abi.encodeCall(IJBTerminalStore.totalFeeVolumeOf, (terminal)), abi.encode(uint256(0)));
        assertEq(hook.pushTo({referralChainId: block.chainid, referralProjectId: 42}), 0);
        assertEq(hook.pushedOf({referralChainId: block.chainid, referralProjectId: 42}), 0);
    }

    function test_bridgeRemote_revertsOnSameChain() public {
        // Bridging to the current chain would mean using a sucker for a same-chain settlement, which is wrong.
        vm.expectRevert(
            abi.encodeWithSelector(
                IJBReferralSplitHook.JBReferralSplitHook_WrongBridgeTarget.selector, block.chainid, block.chainid
            )
        );
        hook.bridgeRemote({
            referralChainId: block.chainid,
            referralProjectId: 42,
            sucker: IJBSucker(makeAddr("sucker")),
            terminalToken: makeAddr("terminalToken")
        });
    }

    function test_bridgeRemote_revertsOnZeroOrFeeProjectId() public {
        vm.expectRevert(IJBReferralSplitHook.JBReferralSplitHook_InvalidReferralProjectId.selector);
        hook.bridgeRemote({
            referralChainId: block.chainid + 1,
            referralProjectId: 0,
            sucker: IJBSucker(makeAddr("sucker")),
            terminalToken: makeAddr("terminalToken")
        });

        vm.expectRevert(IJBReferralSplitHook.JBReferralSplitHook_InvalidReferralProjectId.selector);
        hook.bridgeRemote({
            referralChainId: block.chainid + 1,
            referralProjectId: FEE_PROJECT_ID,
            sucker: IJBSucker(makeAddr("sucker")),
            terminalToken: makeAddr("terminalToken")
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
            abi.encodeWithSelector(IJBReferralSplitHook.JBReferralSplitHook_NotASucker.selector, address(sucker))
        );
        hook.bridgeRemote({
            referralChainId: block.chainid + 1,
            referralProjectId: 42,
            sucker: sucker,
            terminalToken: makeAddr("terminalToken")
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
            abi.encodeWithSelector(IJBReferralSplitHook.JBReferralSplitHook_NotASucker.selector, address(sucker))
        );
        hook.claimAndPush({originChainId: 1, referralProjectId: 42, sucker: sucker, claimData: claimData});
    }

    function test_claimAndPush_revertsOnDataMismatch() public {
        IJBSucker sucker = IJBSucker(makeAddr("sucker"));
        vm.mockCall(
            suckerRegistry,
            abi.encodeCall(IJBSuckerRegistry.isSuckerOf, (FEE_PROJECT_ID, address(sucker))),
            abi.encode(true)
        );

        bytes32[32] memory proof;
        // Caller claims this leaf is for projectId 99 — but the leaf's data was packed for projectId 42.
        bytes32 honestMetadata = hook.packLeafMetadata({originChainId: 1, referralProjectId: 42});
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

        bytes32 lyingMetadata = hook.packLeafMetadata({originChainId: 1, referralProjectId: 99});
        vm.expectRevert(
            abi.encodeWithSelector(
                IJBReferralSplitHook.JBReferralSplitHook_LeafBeneficiaryMismatch.selector, lyingMetadata, honestMetadata
            )
        );
        hook.claimAndPush({originChainId: 1, referralProjectId: 99, sucker: sucker, claimData: claimData});
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
}
