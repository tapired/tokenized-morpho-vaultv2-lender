// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {AprOracleBase} from "@periphery/AprOracle/AprOracleBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct MorphoBlueMarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

struct MorphoBlueMarket {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
}

struct LiquidityTarget {
    address adapter;
    bytes32 marketId;
}

interface IMorphoVaultV2StrategyLike {
    function vault() external view returns (address);
}

interface IMorphoVaultV2Like {
    function asset() external view returns (address);

    function totalAssets() external view returns (uint256);

    function adaptersLength() external view returns (uint256);

    function adapters(uint256 index) external view returns (address);

    function liquidityAdapter() external view returns (address);

    function liquidityData() external view returns (bytes memory);
}

interface IMorphoMarketV1AdapterV2Like {
    function morpho() external view returns (address);

    function marketIdsLength() external view returns (uint256);

    function marketIds(uint256 index) external view returns (bytes32);

    function expectedSupplyAssets(
        bytes32 marketId
    ) external view returns (uint256);
}

interface IMorphoBlueLike {
    function market(bytes32 id) external view returns (MorphoBlueMarket memory);

    function idToMarketParams(
        bytes32 id
    ) external view returns (MorphoBlueMarketParams memory);
}

interface IIrmLike {
    function borrowRateView(
        MorphoBlueMarketParams memory marketParams,
        MorphoBlueMarket memory market
    ) external view returns (uint256);
}

interface IMorphoGenericOracle {
    function getRewardsRate(address vault) external view returns (uint256);
}

/// @title Strategy APR Oracle
/// @notice APR oracle for Morpho Vault V2 lender strategies.
/// @dev Assumes the destination vault only uses Morpho Market V1 adapters.
contract StrategyAprOracle is AprOracleBase {
    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 31_556_952;

    /// @notice Optional external reward oracle per Morpho Vault V2.
    mapping(address vault => address rewardOracle) public rewardOracles;

    constructor() AprOracleBase("Morpho Vault V2 Apr Oracle", msg.sender) {}

    /**
     * @notice Will return the expected Apr of a strategy post a debt change.
     * @dev `_delta` is a signed integer so that it can also represent a debt decrease.
     * @param _strategy The strategy to get the apr for.
     * @param _delta The difference in debt.
     * @return The expected apr for the strategy represented as 1e18.
     */
    function aprAfterDebtChange(
        address _strategy,
        int256 _delta
    ) external view override returns (uint256) {
        address vault = IMorphoVaultV2StrategyLike(_strategy).vault();
        uint256 underlyingYield = getUnderlyingYield(vault, _delta);

        // Give a small buffer for externally reported rewards.
        uint256 rewardsRate = (getRewardsRate(vault) * 9_500) / MAX_BPS;

        return rewardsRate + underlyingYield;
    }

    /// @notice Returns the optional external rewards APR for a Morpho Vault V2.
    /// @param _vault The Morpho Vault V2 to query.
    /// @return The reward APR represented as 1e18.
    function getRewardsRate(address _vault) public view returns (uint256) {
        address rewardOracle = rewardOracles[_vault];
        if (rewardOracle == address(0)) {
            return 0;
        }

        return IMorphoGenericOracle(rewardOracle).getRewardsRate(_vault);
    }

    /// @notice Returns the expected underlying APR for a Morpho Vault V2 after a debt change.
    /// @dev Current APR is weighted across all existing markets.
    /// @dev The debt-change simulation only mutates the liquidity-adapter market, because deposits route there and
    /// withdrawals first consume idle assets before deallocating from that market.
    /// @param _vault The Morpho Vault V2 to query.
    /// @param _delta The difference in debt.
    /// @return The expected underlying APR represented as 1e18.
    function getUnderlyingYield(
        address _vault,
        int256 _delta
    ) public view returns (uint256) {
        IMorphoVaultV2Like vault = IMorphoVaultV2Like(_vault);
        uint256 totalAssets = vault.totalAssets();
        uint256 idleAssets = IERC20(vault.asset()).balanceOf(_vault);

        if (totalAssets == 0) {
            return 0;
        }

        int256 adjustedTotalAssets = int256(totalAssets) + _delta;
        if (adjustedTotalAssets <= 0) {
            return 0;
        }

        LiquidityTarget memory liquidityTarget;
        liquidityTarget.adapter = vault.liquidityAdapter();
        if (liquidityTarget.adapter != address(0)) {
            MorphoBlueMarketParams memory liquidityMarketParams = abi.decode(
                vault.liquidityData(),
                (MorphoBlueMarketParams)
            );
            liquidityTarget.marketId = keccak256(
                abi.encode(liquidityMarketParams)
            );
        }

        return
            _aggregateWeightedRate(vault, liquidityTarget, _delta, idleAssets) /
            uint256(adjustedTotalAssets);
    }

    /// @notice Returns the weighted APR contribution of a single adapter market.
    function _aggregateWeightedRate(
        IMorphoVaultV2Like vault,
        LiquidityTarget memory liquidityTarget,
        int256 delta,
        uint256 idleAssets
    ) internal view returns (uint256 rate) {
        uint256 adaptersLength = vault.adaptersLength();

        for (uint256 i = 0; i < adaptersLength; ++i) {
            IMorphoMarketV1AdapterV2Like adapter = IMorphoMarketV1AdapterV2Like(
                vault.adapters(i)
            );
            uint256 marketIdsLength = adapter.marketIdsLength();

            for (uint256 j = 0; j < marketIdsLength; ++j) {
                rate += _marketContribution(
                    adapter,
                    adapter.marketIds(j),
                    liquidityTarget,
                    delta,
                    idleAssets
                );
            }
        }
    }

    /// @notice Returns the weighted APR contribution of a single adapter market.
    function _marketContribution(
        IMorphoMarketV1AdapterV2Like adapter,
        bytes32 marketId,
        LiquidityTarget memory liquidityTarget,
        int256 delta,
        uint256 idleAssets
    ) internal view returns (uint256) {
        uint256 suppliedAssets = adapter.expectedSupplyAssets(marketId);
        if (suppliedAssets == 0) {
            return 0;
        }

        int256 marketChange = _liquidityMarketChange(
            address(adapter),
            marketId,
            liquidityTarget,
            delta,
            idleAssets,
            suppliedAssets
        );

        uint256 adjustedSuppliedAssets = uint256(
            int256(suppliedAssets) + marketChange
        );
        if (adjustedSuppliedAssets == 0) {
            return 0;
        }

        IMorphoBlueLike morpho = IMorphoBlueLike(adapter.morpho());
        MorphoBlueMarketParams memory marketParams = morpho.idToMarketParams(
            marketId
        );
        if (marketParams.irm == address(0)) {
            return 0;
        }

        MorphoBlueMarket memory market = morpho.market(marketId);
        market.totalSupplyAssets = uint128(
            uint256(int256(uint256(market.totalSupplyAssets)) + marketChange)
        );

        uint256 borrowRate = IIrmLike(marketParams.irm).borrowRateView(
            marketParams,
            market
        );
        uint256 borrowApy = borrowRate * SECONDS_PER_YEAR;

        uint256 supplyApy = (borrowApy *
            ((uint256(market.totalBorrowAssets) * WAD) /
                uint256(market.totalSupplyAssets)) *
            (WAD - uint256(market.fee))) / WAD / WAD;

        return supplyApy * adjustedSuppliedAssets;
    }

    /// @notice Returns the simulated asset change applied to a market after a debt change.
    /// @dev Positive debt changes route directly to the liquidity market.
    /// @dev Negative debt changes first consume idle assets before reducing the liquidity market.
    function _liquidityMarketChange(
        address adapter,
        bytes32 marketId,
        LiquidityTarget memory liquidityTarget,
        int256 delta,
        uint256 idleAssets,
        uint256 suppliedAssets
    ) internal pure returns (int256) {
        if (
            adapter != liquidityTarget.adapter ||
            marketId != liquidityTarget.marketId
        ) {
            return 0;
        }

        if (delta >= 0) {
            return delta;
        }

        int256 deltaAfterIdle = delta + int256(idleAssets);
        if (deltaAfterIdle >= 0) {
            return 0;
        }

        int256 maxDecrease = -int256(suppliedAssets);
        return deltaAfterIdle < maxDecrease ? maxDecrease : deltaAfterIdle;
    }

    /// @notice Sets external reward oracles for Morpho Vault V2s.
    /// @param _vaults The Morpho Vault V2 addresses.
    /// @param _rewardOracles The reward oracle addresses.
    function setRewardOracles(
        address[] memory _vaults,
        address[] memory _rewardOracles
    ) external onlyGovernance {
        require(_vaults.length == _rewardOracles.length, "length mismatch");

        for (uint256 i = 0; i < _vaults.length; ++i) {
            rewardOracles[_vaults[i]] = _rewardOracles[i];
        }
    }
}
