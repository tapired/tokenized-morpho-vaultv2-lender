// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

struct MorphoMarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

interface IMorphoVaultV2Like is IERC4626 {
    function liquidityAdapter() external view returns (address);

    function liquidityData() external view returns (bytes memory);

    function totalAssets() external view returns (uint256);

    function absoluteCap(bytes32 id) external view returns (uint256);

    function relativeCap(bytes32 id) external view returns (uint256);

    function allocation(bytes32 id) external view returns (uint256);

    function canReceiveShares(address account) external view returns (bool);

    function canSendAssets(address account) external view returns (bool);

    function canReceiveAssets(address account) external view returns (bool);

    function canSendShares(address account) external view returns (bool);
}

interface IMorphoMarketV1AdapterV2Like {
    function morpho() external view returns (address);

    function expectedSupplyAssets(
        bytes32 marketId
    ) external view returns (uint256);
}

interface IMorphoBlueLike {
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

contract MorphoVaultV2Limits {
    uint256 internal constant WAD = 1e18;

    // Assume the adapter is market v1 adapter.
    function availableDepositLimit(
        address morphoVault_,
        address asset_,
        address strategy
    ) external view returns (uint256) {
        IMorphoVaultV2Like morphoVault = IMorphoVaultV2Like(morphoVault_);

        if (
            !morphoVault.canSendAssets(strategy) ||
            !morphoVault.canReceiveShares(strategy)
        ) {
            return 0;
        }

        address liquidityAdapter = morphoVault.liquidityAdapter();
        if (liquidityAdapter == address(0)) {
            return type(uint256).max;
        }

        bytes memory data = morphoVault.liquidityData();
        if (data.length != 160) {
            return 0;
        }

        MorphoMarketParams memory marketParams = abi.decode(
            data,
            (MorphoMarketParams)
        );
        if (marketParams.loanToken != asset_) {
            return 0;
        }

        uint256 firstTotalAssets = morphoVault.totalAssets();
        uint256 limit = _capHeadroom(
            morphoVault,
            keccak256(abi.encode("this", liquidityAdapter)),
            firstTotalAssets
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

    function vaultsMaxWithdraw(
        address morphoVault_,
        address asset_,
        address strategy,
        uint256 vaultClaim
    ) external view returns (uint256) {
        if (vaultClaim == 0) {
            return 0;
        }

        IMorphoVaultV2Like morphoVault = IMorphoVaultV2Like(morphoVault_);
        if (
            !morphoVault.canSendShares(strategy) ||
            !morphoVault.canReceiveAssets(strategy)
        ) {
            return 0;
        }

        uint256 liquidAssets = IERC20(asset_).balanceOf(morphoVault_);
        address liquidityAdapter = morphoVault.liquidityAdapter();

        if (liquidityAdapter != address(0)) {
            bytes memory data = morphoVault.liquidityData();
            if (data.length == 160) {
                MorphoMarketParams memory marketParams = abi.decode(
                    data,
                    (MorphoMarketParams)
                );

                if (marketParams.loanToken == asset_) {
                    bytes32 marketId = keccak256(abi.encode(marketParams));
                    IMorphoMarketV1AdapterV2Like adapter = IMorphoMarketV1AdapterV2Like(
                            liquidityAdapter
                        );

                    try adapter.expectedSupplyAssets(marketId) returns (
                        uint256 adapterAssets
                    ) {
                        try IMorphoBlueLike(adapter.morpho()).market(marketId) returns (
                            uint128 totalSupplyAssets,
                            uint128,
                            uint128 totalBorrowAssets,
                            uint128,
                            uint128,
                            uint128
                        ) {
                            uint256 marketLiquidity = totalSupplyAssets >
                                totalBorrowAssets
                                ? uint256(totalSupplyAssets) -
                                    uint256(totalBorrowAssets)
                                : 0;

                            liquidAssets += Math.min(
                                adapterAssets,
                                marketLiquidity
                            );
                        } catch {}
                    } catch {}
                }
            }
        }

        return Math.min(vaultClaim, liquidAssets);
    }

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
