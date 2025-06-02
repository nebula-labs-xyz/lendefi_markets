// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {IASSETS} from "../../contracts/interfaces/IASSETS.sol";
import {MockPriceOracle} from "../../contracts/mock/MockPriceOracle.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title LendefiCoreAdditionalCoverageTest
 * @notice Additional tests to improve code coverage for uncovered functions
 * @dev Focuses on calculateLimits and other edge cases
 */
contract LendefiCoreAdditionalCoverageTest is BasicDeploy {
    MockPriceOracle internal usdcOracleInstance;
    MockPriceOracle internal wethOracleInstance;
    MockPriceOracle internal rwaOracleInstance;
    TokenMock internal rwaToken;

    // Test constants
    uint256 constant INITIAL_LIQUIDITY = 1_000_000e6; // 1M USDC
    uint256 constant ETH_PRICE = 2500e8;
    uint256 constant RWA_PRICE = 100e8;

    function setUp() public {
        // Create oracles
        usdcOracleInstance = new MockPriceOracle();
        usdcOracleInstance.setPrice(1e8); // $1 per USDC
        usdcOracleInstance.setTimestamp(block.timestamp);
        usdcOracleInstance.setRoundId(1);
        usdcOracleInstance.setAnsweredInRound(1);

        wethOracleInstance = new MockPriceOracle();
        wethOracleInstance.setPrice(int256(ETH_PRICE));
        wethOracleInstance.setTimestamp(block.timestamp);
        wethOracleInstance.setRoundId(1);
        wethOracleInstance.setAnsweredInRound(1);

        rwaOracleInstance = new MockPriceOracle();
        rwaOracleInstance.setPrice(int256(RWA_PRICE));
        rwaOracleInstance.setTimestamp(block.timestamp);
        rwaOracleInstance.setRoundId(1);
        rwaOracleInstance.setAnsweredInRound(1);

        // Deploy complete system
        deployMarketsWithUSDC();

        // Deploy WETH and RWA token
        wethInstance = new WETH9();
        rwaToken = new TokenMock("Real World Asset", "RWA");

        // Configure assets
        vm.startPrank(address(timelockInstance));

        // Configure USDC
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6,
                borrowThreshold: 900,
                liquidationThreshold: 950,
                maxSupplyThreshold: 10_000_000e6,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(usdcOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Configure WETH
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 10_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Configure RWA token as ISOLATED
        assetsInstance.updateAssetConfig(
            address(rwaToken),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 500,
                liquidationThreshold: 600,
                maxSupplyThreshold: 100_000e18,
                isolationDebtCap: 50_000e6,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.ISOLATED,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(rwaOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Update oracle timestamps
        usdcOracleInstance.setTimestamp(block.timestamp);
        wethOracleInstance.setTimestamp(block.timestamp);
        rwaOracleInstance.setTimestamp(block.timestamp);

        vm.stopPrank();

        // Provide initial liquidity
        usdcInstance.mint(alice, INITIAL_LIQUIDITY);
        vm.startPrank(alice);
        usdcInstance.approve(address(marketCoreInstance), INITIAL_LIQUIDITY);
        uint256 expectedShares = marketVaultInstance.previewDeposit(INITIAL_LIQUIDITY);
        marketCoreInstance.depositLiquidity(INITIAL_LIQUIDITY, expectedShares, 100);
        vm.stopPrank();
    }

    // ========== CALCULATE LIMITS TESTS ==========

    /**
     * @notice Test calculateLimits with empty position (no collateral)
     */
    function test_CalculateLimits_EmptyPosition() public {
        // Create position but don't supply collateral
        vm.prank(bob);
        marketCoreInstance.createPosition(address(wethInstance), false);
        uint256 positionId = 0;

        (uint256 credit, uint256 liqLevel, uint256 value) = marketCoreInstance.calculateLimits(bob, positionId);

        assertEq(credit, 0, "Empty position should have 0 credit");
        assertEq(liqLevel, 0, "Empty position should have 0 liquidation level");
        assertEq(value, 0, "Empty position should have 0 value");
    }

    /**
     * @notice Test calculateLimits with single collateral asset
     */
    function test_CalculateLimits_SingleCollateral() public {
        // Setup: Create position and supply WETH
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        uint256 wethAmount = 1 ether;

        deal(address(wethInstance), bob, wethAmount);
        _supplyCollateral(bob, positionId, address(wethInstance), wethAmount);

        // Calculate limits
        (uint256 credit, uint256 liqLevel, uint256 value) = marketCoreInstance.calculateLimits(bob, positionId);

        // Expected calculations:
        // Value = 1 ETH * $2500 = $2500 (in 6 decimals = 2500e6)
        // Credit = $2500 * 80% (borrow threshold) = $2000
        // LiqLevel = $2500 * 85% (liquidation threshold) = $2125

        assertEq(value, 2500e6, "Position value should be $2500");
        assertEq(credit, 2000e6, "Credit limit should be $2000");
        assertEq(liqLevel, 2125e6, "Liquidation level should be $2125");
    }

    /**
     * @notice Test calculateLimits with multiple collateral assets
     */
    function test_CalculateLimits_MultipleCollateral() public {
        // Setup: Create position and supply both WETH and USDC
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        uint256 wethAmount = 1 ether;
        uint256 usdcAmount = 1000e6;

        deal(address(wethInstance), bob, wethAmount);
        deal(address(usdcInstance), bob, usdcAmount);

        _supplyCollateral(bob, positionId, address(wethInstance), wethAmount);
        _supplyCollateral(bob, positionId, address(usdcInstance), usdcAmount);

        // Calculate limits
        (uint256 credit, uint256 liqLevel, uint256 value) = marketCoreInstance.calculateLimits(bob, positionId);

        // Expected calculations:
        // WETH Value = 1 ETH * $2500 = $2500
        // USDC Value = 1000 USDC = $1000
        // Total Value = $3500 (in 6 decimals = 3500e6)
        //
        // Credit = (WETH: $2500 * 80%) + (USDC: $1000 * 90%) = $2000 + $900 = $2900
        // LiqLevel = (WETH: $2500 * 85%) + (USDC: $1000 * 95%) = $2125 + $950 = $3075

        assertEq(value, 3500e6, "Position value should be $3500");
        assertEq(credit, 2900e6, "Credit limit should be $2900");
        assertEq(liqLevel, 3075e6, "Liquidation level should be $3075");
    }

    /**
     * @notice Test calculateLimits with isolated position
     */
    function test_CalculateLimits_IsolatedPosition() public {
        // Setup: Create isolated position with RWA token
        uint256 positionId = _createPosition(bob, address(rwaToken), true);
        uint256 rwaAmount = 100e18;

        rwaToken.mint(bob, rwaAmount);
        _supplyCollateral(bob, positionId, address(rwaToken), rwaAmount);

        // Calculate limits
        (uint256 credit, uint256 liqLevel, uint256 value) = marketCoreInstance.calculateLimits(bob, positionId);

        // Expected calculations:
        // Value = 100 RWA * $100 = $10000 (in 6 decimals = 10000e6)
        // Credit = $10000 * 50% (borrow threshold for isolated) = $5000
        // LiqLevel = $10000 * 60% (liquidation threshold for isolated) = $6000

        assertEq(value, 10000e6, "Position value should be $10000");
        assertEq(credit, 5000e6, "Credit limit should be $5000");
        assertEq(liqLevel, 6000e6, "Liquidation level should be $6000");
    }

    /**
     * @notice Test calculateLimits reverts for invalid position
     */
    function test_Revert_CalculateLimits_InvalidPosition() public {
        // Try to calculate limits for non-existent position
        vm.expectRevert(IPROTOCOL.InvalidPosition.selector);
        marketCoreInstance.calculateLimits(bob, 999);
    }

    /**
     * @notice Test calculateLimits reverts for out of bounds position
     */
    function test_Revert_CalculateLimits_OutOfBounds() public {
        // Create one position
        vm.prank(bob);
        marketCoreInstance.createPosition(address(wethInstance), false);

        // Try to access position ID 1 when only position 0 exists
        vm.expectRevert(IPROTOCOL.InvalidPosition.selector);
        marketCoreInstance.calculateLimits(bob, 1);
    }

    /**
     * @notice Test calculateLimits with position at max collateral value
     */
    function test_CalculateLimits_MaxCollateralValue() public {
        // Setup: Create position with large WETH amount
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        uint256 wethAmount = 1000 ether; // Large amount

        deal(address(wethInstance), bob, wethAmount);
        _supplyCollateral(bob, positionId, address(wethInstance), wethAmount);

        // Calculate limits
        (uint256 credit, uint256 liqLevel, uint256 value) = marketCoreInstance.calculateLimits(bob, positionId);

        // Expected calculations:
        // Value = 1000 ETH * $2500 = $2,500,000 (in 6 decimals = 2500000e6)
        // Credit = $2,500,000 * 80% = $2,000,000
        // LiqLevel = $2,500,000 * 85% = $2,125,000

        assertEq(value, 2500000e6, "Position value should be $2.5M");
        assertEq(credit, 2000000e6, "Credit limit should be $2M");
        assertEq(liqLevel, 2125000e6, "Liquidation level should be $2.125M");
    }

    // ========== HELPER FUNCTIONS ==========

    function _createPosition(address user, address asset, bool isolated) internal returns (uint256) {
        vm.prank(user);
        marketCoreInstance.createPosition(asset, isolated);
        return marketCoreInstance.getUserPositionsCount(user) - 1;
    }

    function _supplyCollateral(address user, uint256 positionId, address asset, uint256 amount) internal {
        vm.startPrank(user);
        IERC20(asset).approve(address(marketCoreInstance), amount);
        marketCoreInstance.supplyCollateral(asset, amount, positionId);
        vm.stopPrank();
    }
}
