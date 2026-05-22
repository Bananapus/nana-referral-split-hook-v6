// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";

import {JBReferralSplitHook} from "../src/JBReferralSplitHook.sol";
import {IJBReferralSplitHook} from "../src/interfaces/IJBReferralSplitHook.sol";

/// @notice Smoke tests for `JBReferralSplitHook`. Full unit + integration coverage will follow once
/// `nana-core-v6` 0.0.59 (with the nested `feeVolumeByReferralOf(terminal, chainId, projectId)` mapping and the
/// auto-resolved `(chainId, projectId)` encoding) is published.
contract JBReferralSplitHookTest is Test {
    JBReferralSplitHook internal hook;

    address internal directory = makeAddr("directory");
    address internal store = makeAddr("store");
    address internal tokens = makeAddr("tokens");
    address internal distributor = makeAddr("distributor");
    address internal terminal = makeAddr("terminal");
    uint256 internal constant FEE_PROJECT_ID = 1;

    function setUp() public {
        hook = new JBReferralSplitHook({
            directory: IJBDirectory(directory),
            store: IJBTerminalStore(store),
            tokens: IJBTokens(tokens),
            distributor: IJBDistributor(distributor),
            terminal: terminal,
            feeProjectId: FEE_PROJECT_ID
        });
    }

    function test_constructor_setsImmutables() public view {
        assertEq(address(hook.DIRECTORY()), directory);
        assertEq(address(hook.STORE()), store);
        assertEq(address(hook.TOKENS()), tokens);
        assertEq(address(hook.DISTRIBUTOR()), distributor);
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
        // A referrer on a different chain — credit is accumulated in the store but the local hook cannot settle
        // cross-chain, so it skips and emits a "remote" reason. `pushedOf` stays at 0.
        uint256 remoteChainId = block.chainid + 1;
        assertEq(hook.pushTo({referralChainId: remoteChainId, referralProjectId: 42}), 0);
        assertEq(hook.pushedOf({referralChainId: remoteChainId, referralProjectId: 42}), 0);
    }

    function test_pushTo_noopsWhenTotalVolumeIsZero() public {
        vm.mockCall(store, abi.encodeCall(IJBTerminalStore.totalFeeVolumeOf, (terminal)), abi.encode(uint256(0)));
        assertEq(hook.pushTo({referralChainId: block.chainid, referralProjectId: 42}), 0);
        assertEq(hook.pushedOf({referralChainId: block.chainid, referralProjectId: 42}), 0);
    }
}
