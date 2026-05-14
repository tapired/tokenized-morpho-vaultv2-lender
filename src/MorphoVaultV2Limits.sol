// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Morpho Blue market parameters encoded in the liquidity adapter data.
struct MorphoMarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @notice Subset of the Morpho Vault V2 surface used for limit calculations.
interface IMorphoVaultV2Like is IERC4626 {
    /// @notice Returns the liquidity adapter used by the Morpho vault.
    function liquidityAdapter() external view returns (address);

    /// @notice Returns the encoded data used with the liquidity adapter.
    function liquidityData() external view returns (bytes memory);

    /// @notice Returns the current total assets of the Morpho vault.
    function totalAssets() external view returns (uint256);

    /// @notice Returns the absolute cap for an allocation id.
    function absoluteCap(bytes32 id) external view returns (uint256);

    /// @notice Returns the relative cap for an allocation id.
    function relativeCap(bytes32 id) external view returns (uint256);

    /// @notice Returns the current allocation for an allocation id.
    function allocation(bytes32 id) external view returns (uint256);
}

/// @notice Subset of the Morpho Market V1 adapter surface used for liquidity calculations.
interface IMorphoMarketV1AdapterV2Like {
    /// @notice Returns the Morpho Blue core contract used by the adapter.
    function morpho() external view returns (address);

    /// @notice Returns the adapter's expected supplied assets for a market.
    /// @param marketId The Morpho Blue market id.
    /// @return The adapter's expected supplied assets for the market.
    function expectedSupplyAssets(
        bytes32 marketId
    ) external view returns (uint256);
}

/// @notice Subset of the Morpho Blue market surface used for liquidity calculations.
interface IMorphoBlueLike {
    /// @notice Returns market accounting data for a Morpho Blue market.
    /// @param id The Morpho Blue market id.
    function market(
        bytes32 id
    )
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );
}

/// @title Morpho Vault V2 Limits
/// @notice Shared helper for Morpho Vault V2 deposit and withdraw limit calculations.
/// @dev Assumes the configured liquidity adapter is always the Morpho Market V1 adapter.
contract MorphoVaultV2Limits {
    /// @notice Fixed-point scale used by Morpho relative caps.
    uint256 internal constant WAD = 1e18;

    /// @notice Returns the remaining deposit capacity for a strategy into a Morpho Vault V2.
    /// @dev Assumes the liquidity adapter is the Morpho Market V1 adapter! 
    /// @dev If no liquidity adapter is configured, deposits are treated as uncapped.
    /// @param morphoVault_ The Morpho Vault V2 address.
    /// @return The remaining asset amount that can be deposited.
    function availableDepositLimit(
        address morphoVault_
    ) external view returns (uint256) {
        IMorphoVaultV2Like morphoVault = IMorphoVaultV2Like(morphoVault_);

        address liquidityAdapter = morphoVault.liquidityAdapter();
        if (liquidityAdapter == address(0)) {
            return type(uint256).max;
        }

        uint256 firstTotalAssets = morphoVault.totalAssets();
        uint256 limit = _capHeadroom(
            morphoVault,
            keccak256(abi.encode("this", liquidityAdapter)),
            firstTotalAssets
        );

        MorphoMarketParams memory marketParams = abi.decode(
            morphoVault.liquidityData(),
            (MorphoMarketParams)
        );

        limit = Math.min(
            limit,
            _capHeadroom(
                morphoVault,
                keccak256(
                    abi.encode("collateralToken", marketParams.collateralToken)
                ),
                firstTotalAssets
            )
        );

        limit = Math.min(
            limit,
            _capHeadroom(
                morphoVault,
                keccak256(
                    abi.encode(
                        "this/marketParams",
                        liquidityAdapter,
                        marketParams
                    )
                ),
                firstTotalAssets
            )
        );

        return limit;
    }

    /// @notice Returns the maximum assets currently withdrawable from a Morpho Vault V2.
    /// @dev Combines idle vault liquidity with the liquid portion of the Market V1 position.
    /// @dev Assumes the liquidity adapter is the Morpho Market V1 adapter! 
    /// @param morphoVault_ The Morpho Vault V2 address.
    /// @param asset_ The underlying asset address.
    /// @param vaultClaim The strategy's current claim on the vault, denominated in assets.
    /// @return The maximum asset amount realistically withdrawable.
    function vaultsMaxWithdraw(
        address morphoVault_,
        address asset_,
        uint256 vaultClaim
    ) external view returns (uint256) {
        if (vaultClaim == 0) {
            return 0;
        }

        IMorphoVaultV2Like morphoVault = IMorphoVaultV2Like(morphoVault_);
        uint256 liquidAssets = IERC20(asset_).balanceOf(morphoVault_);
        address liquidityAdapter = morphoVault.liquidityAdapter();

        if (liquidityAdapter != address(0)) {
            bytes memory data = morphoVault.liquidityData();
            MorphoMarketParams memory marketParams = abi.decode(
                data,
                (MorphoMarketParams)
            );

            bytes32 marketId = keccak256(abi.encode(marketParams));
            IMorphoMarketV1AdapterV2Like adapter = IMorphoMarketV1AdapterV2Like(
                liquidityAdapter
            );

            uint256 adapterAssets = adapter.expectedSupplyAssets(marketId);
            (
                uint128 totalSupplyAssets,
                ,
                uint128 totalBorrowAssets,
                ,
                ,

            ) = IMorphoBlueLike(adapter.morpho()).market(marketId);

            uint256 marketLiquidity = totalSupplyAssets > totalBorrowAssets
                ? uint256(totalSupplyAssets) - uint256(totalBorrowAssets)
                : 0;

            liquidAssets += Math.min(adapterAssets, marketLiquidity);
        }

        return Math.min(vaultClaim, liquidAssets);
    }

    /// @notice Returns the remaining headroom for a capped Morpho Vault V2 allocation id.
    /// @param morphoVault The Morpho Vault V2 address.
    /// @param id The allocation id being checked.
    /// @param firstTotalAssets The vault total assets used for relative-cap checks.
    /// @return The remaining headroom for this id in asset units.
    function _capHeadroom(
        IMorphoVaultV2Like morphoVault,
        bytes32 id,
        uint256 firstTotalAssets
    ) internal view returns (uint256) {
        uint256 absoluteCap = morphoVault.absoluteCap(id);
        uint256 currentAllocation = morphoVault.allocation(id);

        if (absoluteCap == 0 || currentAllocation >= absoluteCap) {
            return 0;
        }

        uint256 limit = absoluteCap - currentAllocation;
        uint256 relativeCap = morphoVault.relativeCap(id);

        if (relativeCap != WAD) {
            uint256 relativeLimit = Math.mulDiv(
                firstTotalAssets,
                relativeCap,
                WAD
            );

            if (currentAllocation >= relativeLimit) {
                return 0;
            }

            limit = Math.min(limit, relativeLimit - currentAllocation);
        }

        return limit;
    }
}
