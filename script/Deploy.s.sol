// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Script, console2} from "forge-std/Script.sol";

import {StrategyFactory} from "../src/StrategyFactory.sol";

contract Deploy is Script {
    address public constant DEFAULT_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    function run() external returns (StrategyFactory factory) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address management = vm.envAddress("MANAGEMENT");
        address performanceFeeRecipient = vm.envAddress(
            "PERFORMANCE_FEE_RECIPIENT"
        );
        address keeper = vm.envAddress("KEEPER");
        address emergencyAdmin = vm.envAddress("EMERGENCY_ADMIN");

        vm.startBroadcast(privateKey);

        factory = new StrategyFactory(
            management,
            performanceFeeRecipient,
            keeper,
            emergencyAdmin
        );
        console2.log("factory", address(factory));
        console2.log("default router", DEFAULT_ROUTER);

        vm.stopBroadcast();
    }
}
