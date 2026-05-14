// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Base4626Compounder, Math} from "@periphery/Bases/4626Compounder/Base4626Compounder.sol";
import {AuctionSwapper, Auction} from "@periphery/swappers/AuctionSwapper.sol";
import {UniswapV3Swapper} from "@periphery/swappers/UniswapV3Swapper.sol";
import {IMerklDistributor} from "./interfaces/IMerklDistributor.sol";
import {MorphoVaultV2Limits} from "./MorphoVaultV2Limits.sol";

/// @title Morpho Vault V2 Lender
/// @notice Yearn V3 strategy that deposits into a Morpho Vault V2 and compounds rewards.
contract MorphoVaultV2Lender is
    UniswapV3Swapper,
    AuctionSwapper,
    Base4626Compounder
{
    using SafeERC20 for ERC20;

    /// @notice Whether deposits are open to all users.
    bool public open;
    /// @notice Per-user allowlist used while deposits are closed.
    mapping(address => bool) public allowed;

    /// @notice Reward tokens the strategy is configured to earn.
    address[] public rewardTokens;
    /// @notice Helper contract used to compute realistic Morpho limits.
    MorphoVaultV2Limits public limits;

    /// @notice The Merkl Distributor contract for claiming rewards
    IMerklDistributor public constant MERKL_DISTRIBUTOR =
        IMerklDistributor(0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae);

    /// @notice Deploys the strategy with its Morpho vault, swap router, and limits helper.
    /// @param _asset The underlying asset managed by the strategy.
    /// @param _name The ERC-20 name used by the tokenized strategy wrapper.
    /// @param _morphoVaultV2 The Morpho Vault V2 instance used as the yield source.
    /// @param _router The swap router used for reward liquidation.
    /// @param _limits The helper contract used to compute realistic deposit and withdraw limits.
    constructor(
        address _asset,
        string memory _name,
        address _morphoVaultV2,
        address _router,
        address _limits
    ) Base4626Compounder(_asset, _name, _morphoVaultV2) {
        router = _router;
        limits = MorphoVaultV2Limits(_limits);
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the assets currently depositable into the strategy.
    /// @param _owner The account attempting to deposit.
    /// @return The remaining deposit capacity in asset units.
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        if (!open && !allowed[_owner]) {
            return 0;
        }

        return limits.availableDepositLimit(address(vault));
    }

    /// @notice Returns the assets currently withdrawable from the Morpho vault position.
    /// @return The realistic withdrawable amount denominated in the underlying asset.
    function vaultsMaxWithdraw() public view override returns (uint256) {
        return
            limits.vaultsMaxWithdraw(
                address(vault),
                address(asset),
                valueOfVault()
            );
    }

    /// @notice Updates the limits helper used by the strategy.
    /// @param _limits The new helper contract address.
    function setLimits(address _limits) external onlyManagement {
        require(_limits != address(0), "zero address");
        limits = MorphoVaultV2Limits(_limits);
    }

    /// @notice Withdraws funds from the Morpho vault during emergency shutdown handling.
    /// @param _amount The target amount of assets to free.
    function _emergencyWithdraw(uint256 _amount) internal override {
        uint256 assetsToWithdraw = Math.min(_amount, vaultsMaxWithdraw());
        uint256 shares = vault.previewWithdraw(assetsToWithdraw);

        vault.redeem(
            Math.min(balanceOfVault(), shares),
            address(this),
            address(this)
        );
    }

    ////////////////////////////////
    // AuctionSwapper implementation
    ////////////////////////////////

    /// @notice Sets the auction contract used for reward liquidation.
    /// @param _auction The auction contract address.
    function setAuction(address _auction) external onlyManagement {
        _setAuction(_auction);
    }

    /// @notice Enables or disables auction-based reward selling.
    /// @param _useAuction Whether auctions should be used.
    function setUseAuction(bool _useAuction) external onlyManagement {
        _setUseAuction(_useAuction);
    }

    /// @notice Starts an auction for a reward token balance.
    /// @param _from The reward token to auction.
    /// @return The amount kicked into the auction flow.
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

    /// @notice Sets the Uniswap V3 fee tier used for a token pair.
    /// @param _token0 The first token of the pair.
    /// @param _token1 The second token of the pair.
    /// @param _fee The Uniswap V3 fee tier.
    function setUniFees(
        address _token0,
        address _token1,
        uint24 _fee
    ) external onlyManagement {
        _setUniFees(_token0, _token1, _fee);
    }

    /// @notice Sets the base token used by the swapper.
    /// @param _base The base token address.
    function setBase(address _base) external onlyManagement {
        base = _base;
    }

    /// @notice Adds a reward token that can be liquidated by the strategy.
    /// @param _rewardToken The reward token address.
    function addRewardToken(address _rewardToken) external onlyManagement {
        require(
            _rewardToken != address(asset) && _rewardToken != address(vault),
            "Invalid reward token"
        );
        rewardTokens.push(_rewardToken);
    }

    /// @notice Removes a reward token from the liquidation allowlist.
    /// @param _rewardToken The reward token address.
    function removeRewardToken(address _rewardToken) external onlyManagement {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (rewardTokens[i] == _rewardToken) {
                rewardTokens[i] = rewardTokens[rewardTokens.length - 1];
                rewardTokens.pop();
            }
        }
    }

    /// @notice Claims and liquidates reward tokens when auctions are disabled.
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
    /// @notice Sells a specific reward token amount through the configured swap path.
    /// @param _rewardToken The reward token address.
    /// @param _amount The amount of reward token to sell.
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

    /// @notice Sets the minimum reward balance required before selling.
    /// @param _minAmountToSell The minimum amount required to trigger selling.
    function setMinAmountToSell(
        uint256 _minAmountToSell
    ) external onlyManagement {
        minAmountToSell = _minAmountToSell;
    }

    ////////////////////////////////
    // Access control Implementation
    ////////////////////////////////

    /// @notice Opens or closes deposits for non-allowlisted users.
    /// @param _open Whether deposits are open to everyone.
    function setOpen(bool _open) external onlyManagement {
        open = _open;
    }

    /// @notice Updates the per-user allowlist for deposits while closed.
    /// @param _user The user whose allowlist status is being changed.
    /// @param _allowed Whether the user is allowed to deposit while closed.
    function setAllowed(address _user, bool _allowed) external onlyManagement {
        allowed[_user] = _allowed;
    }
}
