// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Base4626Compounder} from "@periphery/Bases/4626Compounder/Base4626Compounder.sol";
import {AuctionSwapper} from "@periphery/swappers/AuctionSwapper.sol";
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

    constructor(
        address _asset,
        string memory _name,
        address _morphoVaultV2,
        address _morphoVaultV1,
        address _adapter
    ) Base4626Compounder(_asset, _name, _morphoVaultV2) {
        morphoVaultV1 = IERC4626(_morphoVaultV1);
        adapter = _adapter;
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    // MorphoV2 -> adapter -> MorphoV1
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        return
            balanceOfAsset() +
            asset.balanceOf(address(vault)) +
            morphoVaultV1.convertToAssets(
                morphoVaultV1.maxRedeem(address(adapter))
            );
    }

    // MorphoV2 -> adapter -> MorphoV1
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        if (!open && !allowed[_owner]) {
            return 0;
        }
        return morphoVaultV1.maxDeposit(address(adapter));
    }

    ////////////////////////////////
    // AuctionSwapper implementation
    ////////////////////////////////

    function setAuction(address _auction) external onlyManagement {
        auction = _auction;
    }

    function setUseAuction(bool _useAuction) external onlyManagement {
        useAuction = _useAuction;
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
