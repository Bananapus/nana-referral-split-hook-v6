// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";

import {JBReferralSplitHook} from "../src/JBReferralSplitHook.sol";

contract Deploy is Script {
    function run() public {
        vm.startBroadcast();

        // Configure these values before deploying.
        IJBDirectory directory = IJBDirectory(vm.envAddress("DIRECTORY_ADDRESS"));
        IJBTerminalStore store = IJBTerminalStore(vm.envAddress("TERMINAL_STORE_ADDRESS"));
        IJBTokens tokens = IJBTokens(vm.envAddress("TOKENS_ADDRESS"));
        IJBDistributor distributor = IJBDistributor(vm.envAddress("DISTRIBUTOR_ADDRESS"));
        IJBSuckerRegistry suckerRegistry = IJBSuckerRegistry(vm.envAddress("SUCKER_REGISTRY_ADDRESS"));
        address terminal = vm.envAddress("TERMINAL_ADDRESS");
        uint256 feeProjectId = vm.envUint("FEE_PROJECT_ID");

        new JBReferralSplitHook({
            directory: directory,
            store: store,
            tokens: tokens,
            distributor: distributor,
            suckerRegistry: suckerRegistry,
            terminal: terminal,
            feeProjectId: feeProjectId
        });

        vm.stopBroadcast();
    }
}
