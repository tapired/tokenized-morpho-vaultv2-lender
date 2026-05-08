// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TokenizedStrategy} from "@tokenized-strategy/TokenizedStrategy.sol";
import {MorphoVaultV2Lender} from "../Strategy.sol";
import {
    MorphoVaultV2Limits,
    MorphoMarketParams
} from "../MorphoVaultV2Limits.sol";

contract MockAsset is ERC20 {
    constructor() ERC20("Mock Asset", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockMorphoVaultV2 {
    address public immutable asset;
    address public liquidityAdapter;
    bytes public liquidityData;
    uint256 public totalAssetsValue;
    bool public canSendAssetsValue = true;
    bool public canReceiveSharesValue = true;
    bool public canReceiveAssetsValue = true;
    bool public canSendSharesValue = true;

    mapping(bytes32 => uint256) public absoluteCaps;
    mapping(bytes32 => uint256) public relativeCaps;
    mapping(bytes32 => uint256) public allocations;
    mapping(address => uint256) public shareBalances;

    constructor(address _asset) {
        asset = _asset;
    }

    function setLiquidityAdapterAndData(
        address _liquidityAdapter,
        bytes memory _liquidityData
    ) external {
        liquidityAdapter = _liquidityAdapter;
        liquidityData = _liquidityData;
    }

    function setTotalAssets(uint256 _totalAssets) external {
        totalAssetsValue = _totalAssets;
    }

    function setCanSendAssets(bool _canSendAssets) external {
        canSendAssetsValue = _canSendAssets;
    }

    function setCanReceiveShares(bool _canReceiveShares) external {
        canReceiveSharesValue = _canReceiveShares;
    }

    function setCanReceiveAssets(bool _canReceiveAssets) external {
        canReceiveAssetsValue = _canReceiveAssets;
    }

    function setCanSendShares(bool _canSendShares) external {
        canSendSharesValue = _canSendShares;
    }

    function setShareBalance(address account, uint256 amount) external {
        shareBalances[account] = amount;
    }

    function setCaps(
        bytes32 id,
        uint256 absoluteCapValue,
        uint256 relativeCapValue,
        uint256 allocationValue
    ) external {
        absoluteCaps[id] = absoluteCapValue;
        relativeCaps[id] = relativeCapValue;
        allocations[id] = allocationValue;
    }

    function totalAssets() external view returns (uint256) {
        return totalAssetsValue;
    }

    function absoluteCap(bytes32 id) external view returns (uint256) {
        return absoluteCaps[id];
    }

    function relativeCap(bytes32 id) external view returns (uint256) {
        return relativeCaps[id];
    }

    function allocation(bytes32 id) external view returns (uint256) {
        return allocations[id];
    }

    function canReceiveShares(address) external view returns (bool) {
        return canReceiveSharesValue;
    }

    function canSendAssets(address) external view returns (bool) {
        return canSendAssetsValue;
    }

    function canReceiveAssets(address) external view returns (bool) {
        return canReceiveAssetsValue;
    }

    function canSendShares(address) external view returns (bool) {
        return canSendSharesValue;
    }

    function deposit(uint256, address) external pure returns (uint256) {
        return 0;
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function redeem(
        uint256 shares,
        address,
        address
    ) external pure returns (uint256) {
        return shares;
    }

    function balanceOf(address account) external view returns (uint256) {
        return shareBalances[account];
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function maxRedeem(address) external pure returns (uint256) {
        return 0;
    }
}

contract MockMorphoBlue {
    struct MarketState {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
        uint128 fee;
    }

    mapping(bytes32 => MarketState) public markets;

    function setMarket(
        bytes32 id,
        uint128 totalSupplyAssets,
        uint128 totalSupplyShares,
        uint128 totalBorrowAssets,
        uint128 totalBorrowShares,
        uint128 lastUpdate,
        uint128 fee
    ) external {
        markets[id] = MarketState({
            totalSupplyAssets: totalSupplyAssets,
            totalSupplyShares: totalSupplyShares,
            totalBorrowAssets: totalBorrowAssets,
            totalBorrowShares: totalBorrowShares,
            lastUpdate: lastUpdate,
            fee: fee
        });
    }

    function market(
        bytes32 id
    )
        external
        view
        returns (uint128, uint128, uint128, uint128, uint128, uint128)
    {
        MarketState memory state = markets[id];
        return (
            state.totalSupplyAssets,
            state.totalSupplyShares,
            state.totalBorrowAssets,
            state.totalBorrowShares,
            state.lastUpdate,
            state.fee
        );
    }
}

contract MockMorphoMarketV1AdapterV2 {
    address public immutable morpho;
    mapping(bytes32 => uint256) public expectedSupplyAssetsByMarket;

    constructor(address _morpho) {
        morpho = _morpho;
    }

    function setExpectedSupplyAssets(
        bytes32 marketId,
        uint256 amount
    ) external {
        expectedSupplyAssetsByMarket[marketId] = amount;
    }

    function expectedSupplyAssets(
        bytes32 marketId
    ) external view returns (uint256) {
        return expectedSupplyAssetsByMarket[marketId];
    }
}

contract AvailableDepositLimitTest is Test {
    address internal constant TOKENIZED_STRATEGY =
        0xD377919FA87120584B21279a491F82D5265A139c;
    uint256 internal constant WAD = 1e18;

    MockAsset internal asset;
    MockMorphoVaultV2 internal morphoVault;
    MockMorphoBlue internal morphoBlue;
    MorphoVaultV2Limits internal limits;
    MorphoVaultV2Lender internal strategy;

    function setUp() public {
        TokenizedStrategy implementation = new TokenizedStrategy(address(this));
        vm.etch(TOKENIZED_STRATEGY, address(implementation).code);

        asset = new MockAsset();
        morphoVault = new MockMorphoVaultV2(address(asset));
        morphoBlue = new MockMorphoBlue();
        limits = new MorphoVaultV2Limits();
        strategy = new MorphoVaultV2Lender(
            address(asset),
            "Test Strategy",
            address(morphoVault),
            address(1),
            address(limits)
        );

        strategy.setOpen(true);
    }

    function test_availableDepositLimit_unlimitedWithoutLiquidityAdapter()
        public
        view
    {
        assertEq(
            strategy.availableDepositLimit(address(this)),
            type(uint256).max
        );
    }

    function test_availableDepositLimit_zeroWhenGateBlocks() public {
        morphoVault.setCanSendAssets(false);
        assertEq(strategy.availableDepositLimit(address(this)), 0);

        morphoVault.setCanSendAssets(true);
        morphoVault.setCanReceiveShares(false);
        assertEq(strategy.availableDepositLimit(address(this)), 0);
    }

    function test_availableDepositLimit_usesMorphoCapHeadroom() public {
        address liquidityAdapter = address(0xA11CE);
        MorphoMarketParams memory marketParams = MorphoMarketParams({
            loanToken: address(asset),
            collateralToken: address(0xBEEF),
            oracle: address(0xCAFE),
            irm: address(0xF00D),
            lltv: 0.945e18
        });

        morphoVault.setLiquidityAdapterAndData(
            liquidityAdapter,
            abi.encode(marketParams)
        );
        morphoVault.setTotalAssets(1_000e18);

        bytes32 adapterId = keccak256(abi.encode("this", liquidityAdapter));
        bytes32 collateralId = keccak256(
            abi.encode("collateralToken", marketParams.collateralToken)
        );
        bytes32 marketId = keccak256(
            abi.encode("this/marketParams", liquidityAdapter, marketParams)
        );

        morphoVault.setCaps(adapterId, 900e18, WAD, 500e18);
        morphoVault.setCaps(collateralId, 800e18, 0.6e18, 100e18);
        morphoVault.setCaps(marketId, 700e18, WAD, 600e18);

        assertEq(strategy.availableDepositLimit(address(this)), 100e18);
    }

    function test_availableDepositLimit_treatsRelativeCapAsBindingUnlessWad()
        public
    {
        address liquidityAdapter = address(0xA11CE);
        MorphoMarketParams memory marketParams = MorphoMarketParams({
            loanToken: address(asset),
            collateralToken: address(0xBEEF),
            oracle: address(0xCAFE),
            irm: address(0xF00D),
            lltv: 0.945e18
        });

        morphoVault.setLiquidityAdapterAndData(
            liquidityAdapter,
            abi.encode(marketParams)
        );
        morphoVault.setTotalAssets(1_000e18);

        bytes32 adapterId = keccak256(abi.encode("this", liquidityAdapter));
        bytes32 collateralId = keccak256(
            abi.encode("collateralToken", marketParams.collateralToken)
        );
        bytes32 marketId = keccak256(
            abi.encode("this/marketParams", liquidityAdapter, marketParams)
        );

        morphoVault.setCaps(adapterId, 1_000e18, 0.5e18, 500e18);
        morphoVault.setCaps(collateralId, 1_000e18, WAD, 0);
        morphoVault.setCaps(marketId, 1_000e18, WAD, 0);

        assertEq(strategy.availableDepositLimit(address(this)), 0);
    }

    function test_availableWithdrawLimit_noLiquidityAdapterUsesVaultIdleOnly()
        public
    {
        morphoVault.setShareBalance(address(strategy), 100e18);
        asset.mint(address(morphoVault), 40e18);

        assertEq(strategy.vaultsMaxWithdraw(), 40e18);
        assertEq(strategy.availableWithdrawLimit(address(this)), 40e18);
    }

    function test_availableWithdrawLimit_zeroWhenExitGateBlocks() public {
        morphoVault.setShareBalance(address(strategy), 100e18);
        asset.mint(address(morphoVault), 100e18);

        morphoVault.setCanSendShares(false);
        assertEq(strategy.vaultsMaxWithdraw(), 0);

        morphoVault.setCanSendShares(true);
        morphoVault.setCanReceiveAssets(false);
        assertEq(strategy.vaultsMaxWithdraw(), 0);
    }

    function test_availableWithdrawLimit_usesIdlePlusMarketLiquidity() public {
        MorphoMarketParams memory marketParams = MorphoMarketParams({
            loanToken: address(asset),
            collateralToken: address(0xBEEF),
            oracle: address(0xCAFE),
            irm: address(0xF00D),
            lltv: 0.945e18
        });
        bytes32 marketId = keccak256(abi.encode(marketParams));
        MockMorphoMarketV1AdapterV2 liquidityAdapter = new MockMorphoMarketV1AdapterV2(
                address(morphoBlue)
            );

        morphoVault.setShareBalance(address(strategy), 500e18);
        morphoVault.setLiquidityAdapterAndData(
            address(liquidityAdapter),
            abi.encode(marketParams)
        );
        asset.mint(address(morphoVault), 40e18);
        liquidityAdapter.setExpectedSupplyAssets(marketId, 300e18);
        morphoBlue.setMarket(
            marketId,
            1_000e18,
            1_000e18,
            780e18,
            780e18,
            0,
            0
        );

        assertEq(strategy.vaultsMaxWithdraw(), 260e18);
        assertEq(strategy.availableWithdrawLimit(address(this)), 260e18);
    }

    function test_availableWithdrawLimit_isBoundByStrategyClaim() public {
        MorphoMarketParams memory marketParams = MorphoMarketParams({
            loanToken: address(asset),
            collateralToken: address(0xBEEF),
            oracle: address(0xCAFE),
            irm: address(0xF00D),
            lltv: 0.945e18
        });
        bytes32 marketId = keccak256(abi.encode(marketParams));
        MockMorphoMarketV1AdapterV2 liquidityAdapter = new MockMorphoMarketV1AdapterV2(
                address(morphoBlue)
            );

        morphoVault.setShareBalance(address(strategy), 150e18);
        morphoVault.setLiquidityAdapterAndData(
            address(liquidityAdapter),
            abi.encode(marketParams)
        );
        asset.mint(address(morphoVault), 40e18);
        liquidityAdapter.setExpectedSupplyAssets(marketId, 300e18);
        morphoBlue.setMarket(
            marketId,
            1_000e18,
            1_000e18,
            780e18,
            780e18,
            0,
            0
        );

        assertEq(strategy.vaultsMaxWithdraw(), 150e18);
    }
}
