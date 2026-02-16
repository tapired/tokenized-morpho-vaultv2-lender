// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {MorphoVaultV2Lender, ERC20} from "./Strategy.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";

interface IMorphoVaultV2 {
    function adapters(uint256 index) external view returns (address);
    function adaptersLength() external view returns (uint256);
}

interface IAdapter {
    function morphoVaultV1() external view returns (address);
}

contract StrategyFactory {
    event NewStrategy(address indexed strategy, address indexed asset);

    address public immutable emergencyAdmin;

    address public management;
    address public performanceFeeRecipient;
    address public keeper;

    /// @notice Track the deployments. asset => pool => strategy
    mapping(address => address) public deployments;

    /// @notice Track the flexible deployments. asset => pool => strategy
    mapping(address => address) public flexibleDeployments;

    constructor(
        address _management,
        address _performanceFeeRecipient,
        address _keeper,
        address _emergencyAdmin
    ) {
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
        emergencyAdmin = _emergencyAdmin;
    }

    /**
     * @notice Deploy a new Strategy.
     * @param _asset The underlying asset for the strategy to use.
     * @return . The address of the new strategy.
     */
    function newStrategy(
        address _asset,
        string calldata _name,
        address _morphoVaultV2,
        address _router
    ) external virtual returns (address) {
        // tokenized strategies available setters.
        IMorphoVaultV2 __morphoVaultV2 = IMorphoVaultV2(_morphoVaultV2);
        require(__morphoVaultV2.adaptersLength() == 1, "Only one adapter");
        address _adapter = __morphoVaultV2.adapters(0);
        address _morphoVaultV1 = IAdapter(_adapter).morphoVaultV1();
        IStrategyInterface _newStrategy = IStrategyInterface(
            address(
                new MorphoVaultV2Lender(
                    _asset,
                    _name,
                    _morphoVaultV2,
                    _morphoVaultV1,
                    _adapter,
                    _router
                )
            )
        );

        _newStrategy.setPerformanceFeeRecipient(performanceFeeRecipient);

        _newStrategy.setKeeper(keeper);

        _newStrategy.setPendingManagement(management);

        _newStrategy.setEmergencyAdmin(emergencyAdmin);

        emit NewStrategy(address(_newStrategy), _asset);

        deployments[_asset] = address(_newStrategy);
        return address(_newStrategy);
    }

    /**
     * @notice Deploy a new Strategy with adapter and v1 as parameters
     * @param _asset The underlying asset for the strategy to use.
     * @return . The address of the new strategy.
     */
    function newStrategyFlexibleDeployment(
        address _asset,
        string calldata _name,
        address _morphoVaultV2,
        address _morphoVaultV1,
        address _adapter,
        address _router
    ) external virtual returns (address) {
        // tokenized strategies available setters
        IStrategyInterface _newStrategy = IStrategyInterface(
            address(
                new MorphoVaultV2Lender(
                    _asset,
                    _name,
                    _morphoVaultV2,
                    _morphoVaultV1,
                    _adapter,
                    _router
                )
            )
        );

        _newStrategy.setPerformanceFeeRecipient(performanceFeeRecipient);

        _newStrategy.setKeeper(keeper);

        _newStrategy.setPendingManagement(management);

        _newStrategy.setEmergencyAdmin(emergencyAdmin);

        emit NewStrategy(address(_newStrategy), _asset);

        flexibleDeployments[_asset] = address(_newStrategy);
        return address(_newStrategy);
    }

    function setAddresses(
        address _management,
        address _performanceFeeRecipient,
        address _keeper
    ) external {
        require(msg.sender == management, "!management");
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
    }

    function isDeployedStrategy(
        address _strategy
    ) external view returns (bool) {
        address _asset = IStrategyInterface(_strategy).asset();
        return deployments[_asset] == _strategy;
    }
}
