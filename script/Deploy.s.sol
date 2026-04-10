// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Script, console2} from "forge-std/Script.sol";

import {StrategyFactory} from "../src/StrategyFactory.sol";
import {IStrategyInterface} from "../src/interfaces/IStrategyInterface.sol";

contract Deploy is Script {
    address public constant DEFAULT_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // Set these before broadcasting.
    address public management;
    address public performanceFeeRecipient;
    address public keeper;
    address public emergencyAdmin;

    // Leave these zeroed if you only want the factory.
    address public asset;
    address public morphoVaultV2;
    string public strategyName = "";
    address public router = DEFAULT_ROUTER;

    function run() external returns (StrategyFactory factory, address strategy) {

        vm.startBroadcast();

        factory = new StrategyFactory(
            management,
            performanceFeeRecipient,
            keeper,
            emergencyAdmin
        );
        console2.log("factory", address(factory));

        strategy = factory.newStrategy(
            asset,
            strategyName,
            morphoVaultV2,
            router
        );
        console2.log("strategy", strategy);

        vm.stopBroadcast();
    }
}
