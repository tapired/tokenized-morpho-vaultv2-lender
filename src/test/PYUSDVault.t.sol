// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {StrategyFactory} from "../StrategyFactory.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";

interface IHealthCheckStrategy is IStrategyInterface {
    function setDoHealthCheck(bool _doHealthCheck) external;
}

contract PYUSDVaultTest is Setup {
    address internal constant PYUSD_VAULT =
        0xb576765fB15505433aF24FEe2c0325895C559FB2;
    address internal constant PYUSD =
        0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;

    function setUp() public virtual override {
        _setTokenAddrs();

        morphoVaultV2 = PYUSD_VAULT;
        asset = ERC20(IERC4626(morphoVaultV2).asset());

        require(address(asset) == PYUSD, "wrong asset");

        decimals = asset.decimals();
        maxFuzzAmount = maxFuzzAmount * 10 ** decimals;
        minFuzzAmount = minFuzzAmount * 10 ** decimals;

        strategyFactory = new StrategyFactory(
            management,
            performanceFeeRecipient,
            keeper,
            emergencyAdmin
        );

        strategy = IStrategyInterface(setUpStrategy());
        factory = strategy.FACTORY();

        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "PYUSD");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
        vm.label(morphoVaultV2, "PYUSD Morpho Vault V2");
    }

    function test_pyusdVault_depositReportRedeem() public {
        uint256 amount = 10_000 * 10 ** decimals;

        mintAndDepositIntoStrategy(strategy, user, amount);

        assertEq(strategy.asset(), address(asset), "wrong strategy asset");
        assertEq(address(asset), PYUSD, "wrong pyusd asset");
        assertEq(strategy.totalAssets(), amount, "!totalAssets");

        skip(1 days);

        // The vault rounds convertToAssets down by 1 unit after time passes.
        vm.prank(management);
        IHealthCheckStrategy(address(strategy)).setDoHealthCheck(false);

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertEq(profit, 0, "!profit");
        assertLe(loss, 1, "!loss");

        uint256 shares = strategy.balanceOf(user);
        uint256 balanceBefore = asset.balanceOf(user);

        vm.prank(user);
        strategy.redeem(shares, user, user);

        assertGe(
            asset.balanceOf(user) + 1,
            balanceBefore + amount,
            "!final balance"
        );
        assertLe(strategy.totalAssets(), 1, "!remainingAssets");
    }
}
