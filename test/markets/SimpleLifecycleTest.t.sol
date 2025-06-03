// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import "../BasicDeploy.sol";

/**
 * @title SimpleLifecycleTest
 * @notice Simple lifecycle test to verify setup and basic functionality
 */
contract SimpleLifecycleTest is Test, BasicDeploy {
    uint256 constant INITIAL_DEPOSIT = 100_000e6; // 100k USDC
    uint256 constant YIELD_BOOST = 10_000e6; // 10k USDC yield

    address testAlice = address(0xA11CE); // Liquidity provider

    function setUp() public {
        deployMarketsWithUSDC();

        // Setup users
        vm.label(testAlice, "Alice");

        // Give Alice USDC
        usdcInstance.mint(testAlice, INITIAL_DEPOSIT * 2);
    }

    /**
     * @notice Test basic liquidity operations and commission
     */
    function test_BasicLifecycle() public {
        console2.log("=== BASIC LIFECYCLE TEST ===");

        // Step 1: Alice deposits liquidity
        vm.startPrank(testAlice);
        usdcInstance.approve(address(marketCoreInstance), INITIAL_DEPOSIT);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        uint256 expectedShares = marketVaultInstance.previewDeposit(INITIAL_DEPOSIT);
        console2.log("Expected shares for deposit:", expectedShares);

        marketCoreInstance.depositLiquidity(INITIAL_DEPOSIT, expectedShares, 100);
        vm.stopPrank();

        uint256 aliceShares = marketVaultInstance.balanceOf(testAlice);
        console2.log("Alice received shares:", aliceShares);
        assertEq(aliceShares, expectedShares, "Alice should receive expected shares");

        // Step 2: Add yield boost
        vm.warp(block.timestamp + 365 days);

        deal(address(usdcInstance), address(timelockInstance), YIELD_BOOST);

        vm.startPrank(address(timelockInstance));
        usdcInstance.approve(address(marketVaultInstance), YIELD_BOOST);
        marketVaultInstance.boostYield(testAlice, YIELD_BOOST);
        vm.stopPrank();

        // Step 3: Check supply rate
        uint256 supplyRate = marketVaultInstance.getSupplyRate();
        console2.log("Supply rate after yield boost:", supplyRate);
        assertTrue(supplyRate > 95000, "Supply rate should be close to 10%");
        assertTrue(supplyRate < 105000, "Supply rate should be close to 10%");

        // Step 4: Alice withdraws
        vm.startPrank(testAlice);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        uint256 sharesToRedeem = marketVaultInstance.balanceOf(testAlice);
        uint256 aliceShareValue = marketVaultInstance.previewRedeem(sharesToRedeem);
        console2.log("Alice's shares are worth:", aliceShareValue, "USDC");

        uint256 aliceUSDCBefore = usdcInstance.balanceOf(testAlice);
        marketVaultInstance.redeem(sharesToRedeem, testAlice, testAlice);
        uint256 aliceUSDCAfter = usdcInstance.balanceOf(testAlice);

        uint256 aliceProfit = aliceUSDCAfter - aliceUSDCBefore;
        console2.log("Alice profit:", aliceProfit);
        vm.stopPrank();

        // Alice should have received more than her initial deposit
        assertGt(aliceProfit, INITIAL_DEPOSIT, "Alice should have received more than initial deposit");

        // Check timelock shares (commission)
        uint256 timelockShares = marketVaultInstance.balanceOf(marketVaultInstance.timelock());
        console2.log("Timelock shares received:", timelockShares);

        if (timelockShares > 0) {
            uint256 timelockCommissionValue = marketVaultInstance.previewRedeem(timelockShares);
            console2.log("Timelock commission value:", timelockCommissionValue);
        }

        console2.log("=== BASIC LIFECYCLE TEST COMPLETED ===");
    }
}
