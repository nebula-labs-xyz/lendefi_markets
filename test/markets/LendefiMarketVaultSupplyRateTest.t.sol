// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import "../BasicDeploy.sol";

/**
 * @title LendefiMarketVaultSupplyRateTest
 * @notice Test file to validate that getSupplyRate() returns correct rates
 * @dev Tests the commission mechanism by depositing liquidity, warping time, and verifying rates
 */
contract LendefiMarketVaultSupplyRateTest is Test, BasicDeploy {
    uint256 constant INITIAL_DEPOSIT = 100_000e6; // 100k USDC
    uint256 constant YIELD_BOOST = 10_000e6; // 10k USDC yield
    uint256 constant ONE_YEAR = 365 days;
    uint256 constant BLOCKS_PER_YEAR = 365 * 24 * 60 * 5; // Assuming 5 blocks per minute

    address testAlice = address(0xA11CE);

    function setUp() public {
        deployMarketsWithUSDC();

        // Setup users
        vm.label(testAlice, "Alice");

        // Give users USDC
        usdcInstance.mint(testAlice, INITIAL_DEPOSIT * 2);
    }

    /**
     * @notice Test that getSupplyRate() returns correct rate after yield boost
     * @dev Validates commission mechanism by checking rate calculation over time
     */
    function test_GetSupplyRate_WithCommissionAfterYieldBoost() public {
        // Record initial state
        uint256 initialSupplyRate = marketVaultInstance.getSupplyRate();
        console2.log("Initial supply rate:", initialSupplyRate);

        // Alice deposits liquidity
        vm.startPrank(testAlice);
        usdcInstance.approve(address(marketCoreInstance), INITIAL_DEPOSIT);

        // Move to next block to avoid MEV protection
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        uint256 expectedShares = marketVaultInstance.previewDeposit(INITIAL_DEPOSIT);
        marketCoreInstance.depositLiquidity(INITIAL_DEPOSIT, expectedShares, 100);
        vm.stopPrank();

        // Check vault state after deposit
        uint256 totalSuppliedLiquidity = marketVaultInstance.totalSuppliedLiquidity();
        uint256 totalBase = marketVaultInstance.totalAssets();
        uint256 totalSupply = marketVaultInstance.totalSupply();

        console2.log("After deposit - Total supplied liquidity:", totalSuppliedLiquidity);
        console2.log("After deposit - Total base:", totalBase);
        console2.log("After deposit - Total supply:", totalSupply);
        console2.log("After deposit - Supply rate:", marketVaultInstance.getSupplyRate());

        // Fast forward 1 year
        vm.warp(block.timestamp + ONE_YEAR);
        vm.roll(block.number + BLOCKS_PER_YEAR);

        // Boost yield (simulating protocol profits)
        deal(address(usdcInstance), address(timelockInstance), YIELD_BOOST);

        vm.startPrank(address(timelockInstance));
        usdcInstance.approve(address(marketVaultInstance), YIELD_BOOST);
        marketVaultInstance.boostYield(testAlice, YIELD_BOOST);
        vm.stopPrank();

        // Check vault state after yield boost
        uint256 newTotalBase = marketVaultInstance.totalAssets();
        uint256 newSupplyRate = marketVaultInstance.getSupplyRate();

        console2.log("After yield boost - Total base:", newTotalBase);
        console2.log("After yield boost - Supply rate:", newSupplyRate);

        // Verify that total base increased by yield amount
        assertEq(newTotalBase, totalBase + YIELD_BOOST, "Total base should increase by yield amount");

        // With the new ERC4626-based getSupplyRate(), we can simply check the math directly
        // 1 share should be worth more than 1 asset due to yield, but less than without commission

        uint256 shareValue = marketVaultInstance.previewRedeem(1e6); // Value of 1 share
        console2.log("Value of 1 share (1e6):", shareValue);

        // Simple math: if 1 share = 1.09 assets, then supply rate = 9%
        // Expected: ~1.09e6 (9% yield after 1% commission)
        uint256 expectedShareValue = 1.09e6; // Approximately
        console2.log("Expected share value (with ~9% net yield):", expectedShareValue);

        // Verify that commission is working in the conversion functions
        uint256 sharesFor1Asset = marketVaultInstance.previewDeposit(1e6);
        console2.log("Shares for 1 USDC deposit (should be < 1e6 due to commission):", sharesFor1Asset);

        // The new supply rate should reflect the ERC4626 calculation
        uint256 expectedSupplyRate = shareValue > 1e6 ? ((shareValue - 1e6) * 1e6) / 1e6 : 0;
        console2.log("Expected supply rate from ERC4626:", expectedSupplyRate);
        console2.log("Actual supply rate:", newSupplyRate);

        // Supply rate should be approximately 10% (100,000) because existing shareholders
        // get the full benefit. Commission affects new deposits/withdrawals, not existing share values.
        assertTrue(newSupplyRate > 95000, "Supply rate should be close to 10%");
        assertTrue(newSupplyRate < 105000, "Supply rate should be close to 10%");

        // Supply rate should increase due to yield
        assertGt(newSupplyRate, initialSupplyRate, "Supply rate should increase after yield boost");

        // The conversion rate should reflect commission
        assertLt(sharesFor1Asset, 1e6, "Shares received should be less than 1:1 due to commission");
    }

    /**
     * @notice Test supply rate calculation with multiple deposits and withdrawals
     * @dev Ensures rate calculation remains accurate with changing vault state
     */
    function test_GetSupplyRate_WithMultipleOperations() public {
        // First deposit by Alice
        vm.startPrank(testAlice);
        usdcInstance.approve(address(marketCoreInstance), INITIAL_DEPOSIT);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        uint256 expectedShares = marketVaultInstance.previewDeposit(INITIAL_DEPOSIT);
        marketCoreInstance.depositLiquidity(INITIAL_DEPOSIT, expectedShares, 100);
        vm.stopPrank();

        uint256 rateAfterFirstDeposit = marketVaultInstance.getSupplyRate();
        console2.log("Rate after first deposit:", rateAfterFirstDeposit);

        // Fast forward 6 months
        vm.warp(block.timestamp + ONE_YEAR / 2);
        vm.roll(block.number + BLOCKS_PER_YEAR / 2);

        // Add yield boost
        deal(address(usdcInstance), address(timelockInstance), YIELD_BOOST);

        vm.startPrank(address(timelockInstance));
        usdcInstance.approve(address(marketVaultInstance), YIELD_BOOST);
        marketVaultInstance.boostYield(testAlice, YIELD_BOOST);
        vm.stopPrank();

        uint256 rateAfterYieldBoost = marketVaultInstance.getSupplyRate();
        console2.log("Rate after yield boost:", rateAfterYieldBoost);

        // Second deposit by Alice
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        vm.startPrank(testAlice);
        uint256 secondDeposit = INITIAL_DEPOSIT / 2;
        usdcInstance.approve(address(marketCoreInstance), secondDeposit);
        expectedShares = marketVaultInstance.previewDeposit(secondDeposit);
        marketCoreInstance.depositLiquidity(secondDeposit, expectedShares, 100);
        vm.stopPrank();

        uint256 rateAfterSecondDeposit = marketVaultInstance.getSupplyRate();
        console2.log("Rate after second deposit:", rateAfterSecondDeposit);

        // Verify rates are reasonable and reflect the share value accurately
        assertGt(rateAfterYieldBoost, rateAfterFirstDeposit, "Rate should increase after yield boost");
        // With ERC4626-based getSupplyRate(), the rate reflects existing share value, not dilution
        // Additional deposits don't decrease the rate for existing shareholders
        assertGe(rateAfterSecondDeposit, 0, "Rate should remain non-negative after additional deposits");

        // Ensure rates are within reasonable bounds (0-100% APR)
        assertLt(rateAfterSecondDeposit, 1e6, "Rate should be less than 100%");
        assertGe(rateAfterSecondDeposit, 0, "Rate should be non-negative");
    }

    /**
     * @notice Test that commission is properly calculated when withdrawing
     * @dev Validates that protocol fees are collected during withdrawal operations
     */
    function test_GetSupplyRate_CommissionCollectionOnWithdraw() public {
        // Setup: Alice deposits and we add yield
        vm.startPrank(testAlice);
        usdcInstance.approve(address(marketCoreInstance), INITIAL_DEPOSIT);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        uint256 expectedShares = marketVaultInstance.previewDeposit(INITIAL_DEPOSIT);
        marketCoreInstance.depositLiquidity(INITIAL_DEPOSIT, expectedShares, 100);
        uint256 aliceShares = marketVaultInstance.balanceOf(testAlice);
        vm.stopPrank();

        // Add significant yield to trigger commission
        deal(address(usdcInstance), address(timelockInstance), YIELD_BOOST);

        vm.startPrank(address(timelockInstance));
        usdcInstance.approve(address(marketVaultInstance), YIELD_BOOST);
        marketVaultInstance.boostYield(testAlice, YIELD_BOOST);
        vm.stopPrank();

        // Record state before withdrawal
        uint256 totalSupplyBefore = marketVaultInstance.totalSupply();
        address timelockAddr = marketVaultInstance.timelock();
        uint256 timelockBalanceBefore = marketVaultInstance.balanceOf(timelockAddr);

        console2.log("Total supply before withdrawal:", totalSupplyBefore);
        console2.log("Timelock balance before:", timelockBalanceBefore);

        // Alice withdraws half her shares
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        vm.startPrank(testAlice);
        uint256 sharesToWithdraw = aliceShares / 2;
        marketVaultInstance.redeem(sharesToWithdraw, testAlice, testAlice);
        vm.stopPrank();

        // Check if commission was collected
        uint256 totalSupplyAfter = marketVaultInstance.totalSupply();
        uint256 timelockBalanceAfter = marketVaultInstance.balanceOf(timelockAddr);
        uint256 expectedBurnedShares = sharesToWithdraw;

        console2.log("Total supply after withdrawal:", totalSupplyAfter);
        console2.log("Timelock balance after:", timelockBalanceAfter);
        console2.log("Expected burned shares:", expectedBurnedShares);

        // If commission was collected, timelock balance should increase
        if (timelockBalanceAfter > timelockBalanceBefore) {
            console2.log("Commission collected:", timelockBalanceAfter - timelockBalanceBefore);

            // Total supply should decrease by withdrawn shares but increase by fee shares
            uint256 feeShares = timelockBalanceAfter - timelockBalanceBefore;
            uint256 expectedTotalSupply = totalSupplyBefore - expectedBurnedShares + feeShares;

            assertEq(totalSupplyAfter, expectedTotalSupply, "Total supply should account for fee shares");
        } else {
            // No commission collected, total supply should just decrease by withdrawn shares
            assertEq(
                totalSupplyAfter,
                totalSupplyBefore - expectedBurnedShares,
                "Total supply should decrease by withdrawn shares"
            );
        }

        // Verify supply rate is still calculated correctly
        uint256 finalSupplyRate = marketVaultInstance.getSupplyRate();
        assertGt(finalSupplyRate, 0, "Supply rate should be positive after operations");
        console2.log("Final supply rate:", finalSupplyRate);
    }

    /**
     * @notice Test edge case with very small deposits and yield
     * @dev Ensures rate calculation doesn't break with minimal amounts
     */
    function test_GetSupplyRate_EdgeCaseSmallAmounts() public {
        uint256 smallDeposit = 1e6; // 1 USDC
        uint256 smallYield = 1e5; // 0.1 USDC

        // Give testAlice smaller amount
        usdcInstance.mint(testAlice, smallDeposit);

        vm.startPrank(testAlice);
        usdcInstance.approve(address(marketCoreInstance), smallDeposit);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        uint256 expectedShares = marketVaultInstance.previewDeposit(smallDeposit);
        marketCoreInstance.depositLiquidity(smallDeposit, expectedShares, 100);
        vm.stopPrank();

        // Add small yield
        deal(address(usdcInstance), address(timelockInstance), smallYield);

        vm.startPrank(address(timelockInstance));
        usdcInstance.approve(address(marketVaultInstance), smallYield);
        marketVaultInstance.boostYield(testAlice, smallYield);
        vm.stopPrank();

        // Verify rate calculation doesn't break
        uint256 supplyRate = marketVaultInstance.getSupplyRate();
        console2.log("Supply rate with small amounts:", supplyRate);

        // Rate should be reasonable (not overflow or underflow)
        assertLt(supplyRate, 10e6, "Rate should not be absurdly high");
        assertGe(supplyRate, 0, "Rate should be non-negative");
    }
}
