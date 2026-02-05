// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Base4626Compounder} from "@periphery/Bases/4626Compounder/Base4626Compounder.sol";
import {AuctionSwapper, Auction} from "@periphery/swappers/AuctionSwapper.sol";
import {UniswapV3Swapper} from "@periphery/swappers/UniswapV3Swapper.sol";

contract MorphoVaultV2Lender is
    Base4626Compounder,
    AuctionSwapper,
    UniswapV3Swapper
{
    using SafeERC20 for ERC20;

    IERC4626 public morphoVaultV1;
    address public adapter; // MorphoV2 -> adapter -> MorphoV1
    bool public open = true;
    mapping(address => bool) public allowed;

    address[] public rewardTokens;

    constructor(
        address _asset,
        string memory _name,
        address _morphoVaultV2,
        address _morphoVaultV1,
        address _adapter,
        address _router
    ) Base4626Compounder(_asset, _name, _morphoVaultV2) {
        morphoVaultV1 = IERC4626(_morphoVaultV1);
        adapter = _adapter;
        router = _router;
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    // MorphoV2 -> adapter -> MorphoV1
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        if (!open && !allowed[_owner]) {
            return 0;
        }
        return morphoVaultV1.maxDeposit(address(adapter));
    }

    // MorphoV2 -> adapter -> MorphoV1 and idle V2 balances
    function vaultsMaxWithdraw() public view override returns (uint256) {
        return
            morphoVaultV1.convertToAssets(
                morphoVaultV1.maxRedeem(address(adapter))
            ) + asset.balanceOf(address(vault));
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

    function kickAuction(address _from) external override returns (uint256) {
        require(
            _from != address(asset) && _from != address(vault),
            "cannot kick asset"
        );
        return _kickAuction(_from);
    }

    ////////////////////////////////
    // UniswapV3Swapper implementation
    ////////////////////////////////

    function setUniFees(
        address _token0,
        address _token1,
        uint24 _fee
    ) external onlyManagement {
        uniFees[_token0][_token1] = _fee;
        uniFees[_token1][_token0] = _fee;
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
