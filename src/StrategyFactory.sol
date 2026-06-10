// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {MorphoVaultV2Limits} from "./MorphoVaultV2Limits.sol";
import {MorphoVaultV2Lender} from "./Strategy.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";

/// @title Strategy Factory
/// @notice Deploys Morpho Vault V2 lender strategies with shared defaults and a shared limits helper.
contract StrategyFactory {
    /// @notice Emitted when a new strategy is deployed.
    event NewStrategy(address indexed strategy, address indexed asset);

    /// @notice Emergency admin assigned to newly deployed strategies.
    address public immutable emergencyAdmin;
    /// @notice Shared limits helper assigned to newly deployed strategies.
    MorphoVaultV2Limits public immutable limits;

    /// @notice Management address assigned to newly deployed strategies.
    address public management;
    /// @notice Performance fee recipient assigned to newly deployed strategies.
    address public performanceFeeRecipient;
    /// @notice Keeper address assigned to newly deployed strategies.
    address public keeper;

    /// @notice Track the deployments. asset => pool => strategy
    mapping(address => address) public deployments;

    /// @notice Initializes the factory and deploys the default limits helper.
    /// @param _management The management address assigned to newly deployed strategies.
    /// @param _performanceFeeRecipient The performance fee recipient assigned to new strategies.
    /// @param _keeper The keeper address assigned to newly deployed strategies.
    /// @param _emergencyAdmin The emergency admin assigned to newly deployed strategies.
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
        limits = new MorphoVaultV2Limits();
    }

    /**
     * @notice Deploy a new Strategy.
     * @dev Deploys with the default limits helper.
     * @param _asset The underlying asset for the strategy to use.
     * @param _name The ERC-20 name used by the tokenized strategy wrapper.
     * @param _morphoVaultV2 The Morpho Vault V2 yield source for the strategy.
     * @param _router The swap router used for reward liquidation.
     * @return The address of the new strategy.
     */
    function newStrategy(
        address _asset,
        string calldata _name,
        address _morphoVaultV2,
        address _router
    ) external virtual returns (address) {
        return
            _deployStrategy(
                _asset,
                _name,
                _morphoVaultV2,
                _router,
                address(limits)
            );
    }

    /**
     * @notice Deploy a new Strategy with a custom limits helper.
     * @dev Deploys with a custom limits helper.
     * @param _asset The underlying asset for the strategy to use.
     * @param _name The ERC-20 name used by the tokenized strategy wrapper.
     * @param _morphoVaultV2 The Morpho Vault V2 yield source for the strategy.
     * @param _router The swap router used for reward liquidation.
     * @param _limits The custom limits helper assigned to the new strategy.
     * @return The address of the new strategy.
     */
    function newStrategyWithLimits(
        address _asset,
        string calldata _name,
        address _morphoVaultV2,
        address _router,
        address _limits
    ) external virtual returns (address) {
        require(_limits != address(0), "zero address");
        return _deployStrategy(_asset, _name, _morphoVaultV2, _router, _limits);
    }

    /// @notice Deploys and configures a new strategy instance.
    /// @param _asset The underlying asset for the strategy to use.
    /// @param _name The ERC-20 name used by the tokenized strategy wrapper.
    /// @param _morphoVaultV2 The Morpho Vault V2 yield source for the strategy.
    /// @param _router The swap router used for reward liquidation.
    /// @param _limits The limits helper assigned to the new strategy.
    /// @return The address of the new strategy.
    function _deployStrategy(
        address _asset,
        string calldata _name,
        address _morphoVaultV2,
        address _router,
        address _limits
    ) internal returns (address) {
        IStrategyInterface _newStrategy = IStrategyInterface(
            address(
                new MorphoVaultV2Lender(
                    _asset,
                    _name,
                    _morphoVaultV2,
                    _router,
                    _limits
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

    /// @notice Updates the default role addresses used for future strategy deployments.
    /// @param _management The new management address.
    /// @param _performanceFeeRecipient The new performance fee recipient.
    /// @param _keeper The new keeper address.
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

    /// @notice Returns whether a strategy address matches the deployment recorded for its asset.
    /// @param _strategy The strategy address to check.
    /// @return Whether the provided strategy is the factory deployment for its asset.
    function isDeployedStrategy(
        address _strategy
    ) external view returns (bool) {
        address _asset = IStrategyInterface(_strategy).asset();
        return deployments[_asset] == _strategy;
    }
}
