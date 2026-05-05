// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Base4626Compounder, Math} from "@periphery/Bases/4626Compounder/Base4626Compounder.sol";
import {AuctionSwapper, Auction} from "@periphery/swappers/AuctionSwapper.sol";
import {UniswapV3Swapper} from "@periphery/swappers/UniswapV3Swapper.sol";
import {IMerklDistributor} from "./interfaces/IMerklDistributor.sol";

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

    function expectedSupplyAssets(bytes32 marketId) external view returns (uint256);
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

contract MorphoVaultV2Lender is
    UniswapV3Swapper,
    AuctionSwapper,
    Base4626Compounder
{
    using SafeERC20 for ERC20;

    uint256 internal constant WAD = 1e18;

    bool public open;
    mapping(address => bool) public allowed;

    address[] public rewardTokens;

    /// @notice The Merkl Distributor contract for claiming rewards
    IMerklDistributor public constant MERKL_DISTRIBUTOR =
        IMerklDistributor(0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae);

    constructor(
        address _asset,
        string memory _name,
        address _morphoVaultV2,
        address _router
    ) Base4626Compounder(_asset, _name, _morphoVaultV2) {
        router = _router;
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    // Assume the adapter is market v1 adapter! 
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        if (!open && !allowed[_owner]) {
            return 0;
        }

        IMorphoVaultV2Like morphoVault = IMorphoVaultV2Like(address(vault));

        if (
            !morphoVault.canSendAssets(address(this)) ||
            !morphoVault.canReceiveShares(address(this))
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
        if (marketParams.loanToken != address(asset)) {
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
                    abi.encode(
                        "collateralToken",
                        marketParams.collateralToken
                    )
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

    // Assume the adapter is market v1 adapter!
    function vaultsMaxWithdraw() public view override returns (uint256) {
        uint256 vaultClaim = valueOfVault();
        if (vaultClaim == 0) {
            return 0;
        }

        IMorphoVaultV2Like morphoVault = IMorphoVaultV2Like(address(vault));
        if (
            !morphoVault.canSendShares(address(this)) ||
            !morphoVault.canReceiveAssets(address(this))
        ) {
            return 0;
        }

        uint256 liquidAssets = asset.balanceOf(address(vault));
        address liquidityAdapter = morphoVault.liquidityAdapter();

        if (liquidityAdapter != address(0)) {
            bytes memory data = morphoVault.liquidityData();
            if (data.length == 160) {
                MorphoMarketParams memory marketParams = abi.decode(
                    data,
                    (MorphoMarketParams)
                );

                if (marketParams.loanToken == address(asset)) {
                    bytes32 marketId = keccak256(abi.encode(marketParams));
                    IMorphoMarketV1AdapterV2Like adapter = IMorphoMarketV1AdapterV2Like(liquidityAdapter);

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

    function _emergencyWithdraw(uint256 _amount) internal override {
        vault.redeem(
            Math.min(balanceOfVault(), _amount),
            address(this),
            address(this)
        );
    }

    ////////////////////////////////
    // AuctionSwapper implementation
    ////////////////////////////////

    function setAuction(address _auction) external onlyManagement {
        _setAuction(_auction);
    }

    function setUseAuction(bool _useAuction) external onlyManagement {
        _setUseAuction(_useAuction);
    }

    function kickAuction(
        address _from
    ) external override onlyKeepers returns (uint256) {
        require(
            _from != address(asset) && _from != address(vault),
            "cannot kick asset"
        );
        return _kickAuction(_from);
    }

    /**
     * @notice Claims rewards from Merkl distributor
     * @param users Recipients of tokens
     * @param tokens ERC20 tokens being claimed
     * @param amounts Amounts of tokens that will be sent to the corresponding users
     * @param proofs Array of Merkle proofs verifying the claims
     */
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external {
        MERKL_DISTRIBUTOR.claim(users, tokens, amounts, proofs);
    }

    ////////////////////////////////
    // UniswapV3Swapper implementation
    ////////////////////////////////

    function setUniFees(
        address _token0,
        address _token1,
        uint24 _fee
    ) external onlyManagement {
        _setUniFees(_token0, _token1, _fee);
    }

    function setBase(address _base) external onlyManagement {
        base = _base;
    }

    function addRewardToken(address _rewardToken) external onlyManagement {
        require(
            _rewardToken != address(asset) && _rewardToken != address(vault),
            "Invalid reward token"
        );
        rewardTokens.push(_rewardToken);
    }

    function removeRewardToken(address _rewardToken) external onlyManagement {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (rewardTokens[i] == _rewardToken) {
                rewardTokens[i] = rewardTokens[rewardTokens.length - 1];
                rewardTokens.pop();
            }
        }
    }

    function _claimAndSellRewards() internal override {
        if (!useAuction) {
            for (uint256 i = 0; i < rewardTokens.length; ++i) {
                address rewardToken = rewardTokens[i];
                // rewards will be in the contract no need to claim
                _swapFrom(
                    rewardToken,
                    address(asset),
                    ERC20(rewardToken).balanceOf(address(this)),
                    0
                );
            }
        }
    }

    // if we need to selll specific amount of a reward token
    // no need to check if reward token is in the array or not, just checking it's not asset or vault is enough
    function manualSellRewards(
        address _rewardToken,
        uint256 _amount
    ) external onlyKeepers {
        require(
            _rewardToken != address(asset) && _rewardToken != address(vault),
            "Invalid reward token"
        );
        _swapFrom(_rewardToken, address(asset), _amount, 0);
    }

    ////////////////////////////////
    // BaseSwapper Implementation
    ////////////////////////////////

    function setMinAmountToSell(
        uint256 _minAmountToSell
    ) external onlyManagement {
        minAmountToSell = _minAmountToSell;
    }

    ////////////////////////////////
    // Access control Implementation
    ////////////////////////////////

    function setOpen(bool _open) external onlyManagement {
        open = _open;
    }

    function setAllowed(address _user, bool _allowed) external onlyManagement {
        allowed[_user] = _allowed;
    }
}
