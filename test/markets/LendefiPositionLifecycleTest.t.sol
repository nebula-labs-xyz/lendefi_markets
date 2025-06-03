// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import "../BasicDeploy.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {MockPriceOracle} from "../../contracts/mock/MockPriceOracle.sol";

/**
 * @title LendefiPositionLifecycleTest
 * @notice Comprehensive test of the entire position lifecycle with commission validation
 * @dev Tests the complete flow: deposit liquidity -> borrow -> repay -> withdraw
 *      Validates balances for all parties: lender, borrower, timelock (commission), vault
 */
contract LendefiPositionLifecycleTest is Test, BasicDeploy {
    uint256 constant INITIAL_DEPOSIT = 100_000e6; // 100k USDC liquidity
    uint256 constant BORROW_AMOUNT = 100_000e6; // Borrow entire liquidity pool
    uint256 constant COLLATERAL_AMOUNT = 50e18; // 50 WETH collateral (need more for 100k borrow)
    uint256 constant YIELD_BOOST = 10_000e6; // 10k USDC yield from liquidations
    uint256 constant ONE_YEAR = 365 days;
    uint256 constant EXPECTED_INTEREST = 6_000e6; // 6% of 100k = 6k USDC

    address testAlice = address(0xA11CE); // Liquidity provider
    address testBob = address(0xB0B); // Borrower
    WETHPriceConsumerV3 public wethOracle;
    MockPriceOracle public usdcOracle;

    // Track initial balances for all parties
    struct BalanceSnapshot {
        uint256 aliceUSDC;
        uint256 bobUSDC;
        uint256 bobWETH;
        uint256 vaultUSDC;
        uint256 vaultShares;
        uint256 aliceShares;
        uint256 timelockShares;
        uint256 timelockUSDC;
        uint256 totalSuppliedLiquidity;
        uint256 totalBorrow;
        uint256 totalBase;
    }

    function setUp() public {
        deployMarketsWithUSDC();

        // Deploy WETH
        if (address(wethInstance) == address(0)) {
            wethInstance = new WETH9();
        }

        // Deploy oracles
        wethOracle = new WETHPriceConsumerV3();
        wethOracle.setPrice(2500e8); // $2500 per ETH

        usdcOracle = new MockPriceOracle();
        usdcOracle.setPrice(1e8); // $1 per USDC

        // Add USDC as a valid asset (needed for borrowing)
        vm.startPrank(address(timelockInstance));
        IASSETS.Asset memory usdcAsset = IASSETS.Asset({
            active: 1,
            decimals: 6,
            borrowThreshold: 950, // 95% LTV for stablecoin
            liquidationThreshold: 980, // 98% liquidation for stablecoin
            maxSupplyThreshold: 100_000_000e6, // 100M USDC
            isolationDebtCap: 0,
            assetMinimumOracles: 1,
            porFeed: address(0),
            primaryOracleType: IASSETS.OracleType.CHAINLINK,
            tier: IASSETS.CollateralTier.STABLE,
            chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(usdcOracle), active: 1}),
            poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
        });
        assetsInstance.updateAssetConfig(address(usdcInstance), usdcAsset);

        // Add WETH as a valid collateral asset
        IASSETS.Asset memory wethAsset = IASSETS.Asset({
            active: 1,
            decimals: 18,
            borrowThreshold: 800, // 80% LTV
            liquidationThreshold: 850, // 85% liquidation threshold
            maxSupplyThreshold: 1000000e18, // 1M WETH max
            isolationDebtCap: 0, // Not isolated
            assetMinimumOracles: 1,
            porFeed: address(0),
            primaryOracleType: IASSETS.OracleType.CHAINLINK,
            tier: IASSETS.CollateralTier.CROSS_A,
            chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
            poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
        });
        assetsInstance.updateAssetConfig(address(wethInstance), wethAsset);
        vm.stopPrank();

        // Setup users
        vm.label(testAlice, "Alice");
        vm.label(testBob, "Bob");

        // Give users USDC
        usdcInstance.mint(testAlice, INITIAL_DEPOSIT); // Alice only needs 100k for deposit
        usdcInstance.mint(testBob, 150_000e6); // Give Bob enough USDC for repayment with interest (106k + buffer)

        // Give Bob WETH
        deal(address(wethInstance), testBob, COLLATERAL_AMOUNT);
    }

    /**
     * @notice Complete position lifecycle test with commission validation
     * @dev Tests: deposit -> borrow -> yield boost -> repay -> withdraw
     *      Validates all balances and commission collection
     */
    function test_CompletePositionLifecycle() public {
        console2.log("=== STARTING POSITION LIFECYCLE TEST ===");

        // Position ID for tracking throughout the test
        uint256 positionId;

        // Step 1: Alice deposits liquidity
        _step1_AliceDepositsLiquidity();

        // Step 2: Bob borrows against collateral
        positionId = _step2_BobBorrowsAgainstCollateral();

        // Step 3: Time passes and yield boost occurs
        _step3_TimePassesAndYieldBoost();

        // Step 4: Bob repays loan
        _step4_BobRepaysLoan(positionId);

        // Step 5: Bob withdraws collateral
        _step5_BobWithdrawsCollateral(positionId);

        // Step 6: Alice withdraws liquidity
        _step6_AliceWithdrawsLiquidity();

        // Step 7: Final validation
        _step7_FinalValidation();

        console2.log("=== POSITION LIFECYCLE TEST COMPLETED SUCCESSFULLY ===");
    }

    function _step1_AliceDepositsLiquidity() internal {
        console2.log("\n=== STEP 1: ALICE DEPOSITS LIQUIDITY ===");

        vm.startPrank(testAlice);
        usdcInstance.approve(address(marketCoreInstance), INITIAL_DEPOSIT);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        uint256 expectedShares = marketVaultInstance.previewDeposit(INITIAL_DEPOSIT);
        console2.log("Expected shares for deposit:", expectedShares / 1e6);

        marketCoreInstance.depositLiquidity(INITIAL_DEPOSIT, expectedShares, 100);
        vm.stopPrank();
    }

    function _step2_BobBorrowsAgainstCollateral() internal returns (uint256 positionId) {
        console2.log("\n=== STEP 2: BOB BORROWS AGAINST COLLATERAL ===");

        console2.log("Vault USDC before borrow:", usdcInstance.balanceOf(address(marketVaultInstance)) / 1e6);
        console2.log("Bob USDC before borrow:", usdcInstance.balanceOf(testBob) / 1e6);

        vm.startPrank(testBob);
        wethInstance.approve(address(marketCoreInstance), COLLATERAL_AMOUNT);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        // Create position first
        positionId = marketCoreInstance.createPosition(address(wethInstance), false);
        console2.log("Created position ID:", positionId);

        // Supply collateral to the position
        marketCoreInstance.supplyCollateral(address(wethInstance), COLLATERAL_AMOUNT, positionId);

        // Check actual credit limit to debug
        uint256 actualCreditLimit = marketCoreInstance.calculateCreditLimit(testBob, positionId);
        console2.log("Actual credit limit:", actualCreditLimit / 1e6);

        // Borrow against the position
        // With 50 WETH at $2500 and 80% LTV: 50 * 2500 * 0.8 = $100,000 = 100,000 USDC credit limit
        uint256 expectedCreditLimit = actualCreditLimit; // Use actual credit limit
        marketCoreInstance.borrow(positionId, BORROW_AMOUNT, expectedCreditLimit, 100);
        vm.stopPrank();

        console2.log("Vault USDC after borrow:", usdcInstance.balanceOf(address(marketVaultInstance)) / 1e6);
        console2.log("Bob USDC after borrow:", usdcInstance.balanceOf(testBob) / 1e6);
        console2.log("Vault totalBorrow:", marketVaultInstance.totalBorrow() / 1e6);
        console2.log("Vault totalBase:", marketVaultInstance.totalBase() / 1e6);
    }

    function _step3_TimePassesAndYieldBoost() internal {
        console2.log("\n=== STEP 3: TIME PASSES + YIELD BOOST ===");

        // Log initial rates before time passes
        uint256 borrowRateBefore = marketCoreInstance.getBorrowRate(IASSETS.CollateralTier.CROSS_A);
        uint256 supplyRateBefore = marketVaultInstance.getSupplyRate();
        console2.log("Borrow rate before time passes (CROSS_A):", borrowRateBefore);
        console2.log("Supply rate before time passes:", supplyRateBefore);

        // Fast forward 1 year
        vm.warp(block.timestamp + ONE_YEAR);
        vm.roll(block.number + (365 * 24 * 60 * 5)); // Properly simulate 1 year of blocks (5 blocks per minute)

        // Update oracle prices to current time to avoid stale price issues
        wethOracle.setPrice(2500e8); // Reset WETH price
        usdcOracle.setPrice(1e8); // Reset USDC price
        usdcOracle.setTimestamp(block.timestamp); // Update USDC timestamp

        console2.log("Vault USDC before boost:", usdcInstance.balanceOf(address(marketVaultInstance)) / 1e6);
        console2.log("Vault totalBase before boost:", marketVaultInstance.totalBase() / 1e6);

        // Add yield boost (simulating liquidation profits)
        deal(address(usdcInstance), address(timelockInstance), YIELD_BOOST);

        vm.startPrank(address(timelockInstance));
        usdcInstance.approve(address(marketVaultInstance), YIELD_BOOST);
        marketVaultInstance.boostYield(testAlice, YIELD_BOOST);
        vm.stopPrank();

        console2.log("Vault USDC after boost:", usdcInstance.balanceOf(address(marketVaultInstance)) / 1e6);
        console2.log("Vault totalBase after boost:", marketVaultInstance.totalBase() / 1e6);

        // Check rates after time passes and boost
        uint256 borrowRateAfter = marketCoreInstance.getBorrowRate(IASSETS.CollateralTier.CROSS_A);
        uint256 supplyRateAfter = marketVaultInstance.getSupplyRate();
        console2.log("Borrow rate after time passes (CROSS_A):", borrowRateAfter);
        console2.log("Supply rate after yield boost:", supplyRateAfter);

        // Log accrued interest before repayment
        uint256 accruedInterest = marketVaultInstance.totalAccruedInterest();
        console2.log("Total accrued interest after 1 year:", accruedInterest / 1e6);
    }

    function _step4_BobRepaysLoan(uint256 positionId) internal {
        console2.log("\n=== STEP 4: BOB REPAYS LOAN ===");

        // Calculate actual debt with interest
        uint256 actualDebt = marketCoreInstance.calculateDebtWithInterest(testBob, positionId);
        console2.log("Actual debt with interest:", actualDebt / 1e6);
        console2.log("Expected debt (principal + 6% interest):", (BORROW_AMOUNT + EXPECTED_INTEREST) / 1e6);

        // Note: The actual interest might be higher due to compounding and rate calculations
        // Log the interest calculation details
        uint256 interestAmount = actualDebt - BORROW_AMOUNT;
        uint256 interestRate = (interestAmount * 10000) / BORROW_AMOUNT; // basis points
        console2.log("Interest amount:", interestAmount / 1e6);
        console2.log("Effective interest rate (bps):", interestRate);
        console2.log("Expected interest rate: 600 bps (6%)");

        console2.log("Vault USDC before repay:", usdcInstance.balanceOf(address(marketVaultInstance)) / 1e6);
        console2.log("Vault totalBase before repay:", marketVaultInstance.totalBase() / 1e6);
        console2.log("Vault totalBorrow before repay:", marketVaultInstance.totalBorrow() / 1e6);

        // Use actual debt for repayment
        uint256 repaymentAmount = actualDebt + 100e6; // Add small buffer

        // Ensure Bob has enough USDC to repay
        if (usdcInstance.balanceOf(testBob) < repaymentAmount) {
            deal(address(usdcInstance), testBob, repaymentAmount);
        }

        vm.startPrank(testBob);
        usdcInstance.approve(address(marketCoreInstance), repaymentAmount);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        uint256 expectedDebt = actualDebt; // Use actual debt
        marketCoreInstance.repay(positionId, repaymentAmount, expectedDebt, 100);
        vm.stopPrank();

        console2.log("Vault USDC after repay:", usdcInstance.balanceOf(address(marketVaultInstance)) / 1e6);
        console2.log("Vault totalBase after repay:", marketVaultInstance.totalBase() / 1e6);
        console2.log("Vault totalBorrow after repay:", marketVaultInstance.totalBorrow() / 1e6);
    }

    function _step5_BobWithdrawsCollateral(uint256 positionId) internal {
        console2.log("\n=== STEP 5: BOB WITHDRAWS COLLATERAL ===");

        // Update oracle prices again to ensure they're fresh
        wethOracle.setPrice(2500e8); // Reset WETH price
        usdcOracle.setPrice(1e8); // Reset USDC price
        usdcOracle.setTimestamp(block.timestamp); // Update USDC timestamp

        vm.startPrank(testBob);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        uint256 expectedCreditLimit = marketCoreInstance.calculateCreditLimit(testBob, positionId);
        marketCoreInstance.withdrawCollateral(
            address(wethInstance), COLLATERAL_AMOUNT, positionId, expectedCreditLimit, 100
        );
        vm.stopPrank();
    }

    function _step6_AliceWithdrawsLiquidity() internal {
        console2.log("\n=== STEP 6: ALICE WITHDRAWS LIQUIDITY ===");

        vm.startPrank(testAlice);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        console2.log("Total vault value:", marketVaultInstance.totalBase() / 1e6);
        console2.log("Alice's shares:", marketVaultInstance.balanceOf(testAlice) / 1e6);

        // Alice withdraws her maximum available amount
        uint256 maxWithdrawAmount = marketVaultInstance.maxWithdraw(testAlice);
        console2.log("Alice withdrawing:", maxWithdrawAmount / 1e6);

        marketVaultInstance.withdraw(maxWithdrawAmount, testAlice, testAlice);

        console2.log(
            "Commission shares minted to timelock:", marketVaultInstance.balanceOf(marketVaultInstance.timelock()) / 1e6
        );
        vm.stopPrank();
    }

    function _step7_FinalValidation() internal {
        console2.log("\n=== STEP 7: FINAL VALIDATION ===");

        BalanceSnapshot memory finalSnapshot = _takeBalanceSnapshot();
        _logBalanceSnapshot("FINAL", finalSnapshot);

        // Commission Results
        console2.log("Timelock commission shares:", finalSnapshot.timelockShares / 1e6);
        if (finalSnapshot.timelockShares > 0) {
            uint256 timelockCommissionValue = marketVaultInstance.previewRedeem(finalSnapshot.timelockShares);
            console2.log("Timelock commission value:", timelockCommissionValue / 1e6);
        }

        // Final Results
        console2.log("Alice final USDC:", finalSnapshot.aliceUSDC / 1e6);
        console2.log("Alice profit:", (finalSnapshot.aliceUSDC - INITIAL_DEPOSIT) / 1e6);
        console2.log("Vault residual USDC:", finalSnapshot.vaultUSDC / 1e6);
        console2.log("Vault residual totalBase:", finalSnapshot.totalBase / 1e6);

        // Assertions
        assertTrue(finalSnapshot.aliceUSDC > INITIAL_DEPOSIT, "Alice should have profited");
        assertEq(finalSnapshot.totalBorrow, 0, "No outstanding borrows");
        assertEq(finalSnapshot.aliceShares, 0, "Alice should have no remaining shares");
        assertTrue(finalSnapshot.timelockShares > 0, "Timelock should have commission shares");
        assertEq(finalSnapshot.vaultUSDC, finalSnapshot.totalBase, "Vault USDC should equal totalBase");
        assertEq(finalSnapshot.totalSuppliedLiquidity, 0, "No original liquidity should remain");

        console2.log("Final balances validated successfully");
    }

    /**
     * @notice Helper function to take a complete balance snapshot
     */
    function _takeBalanceSnapshot() internal view returns (BalanceSnapshot memory snapshot) {
        snapshot.aliceUSDC = usdcInstance.balanceOf(testAlice);
        snapshot.bobUSDC = usdcInstance.balanceOf(testBob);
        snapshot.bobWETH = wethInstance.balanceOf(testBob);
        snapshot.vaultUSDC = usdcInstance.balanceOf(address(marketVaultInstance));
        snapshot.vaultShares = marketVaultInstance.totalSupply();
        snapshot.aliceShares = marketVaultInstance.balanceOf(testAlice);
        snapshot.timelockShares = marketVaultInstance.balanceOf(marketVaultInstance.timelock());
        snapshot.timelockUSDC = usdcInstance.balanceOf(marketVaultInstance.timelock());
        snapshot.totalSuppliedLiquidity = marketVaultInstance.totalSuppliedLiquidity();
        snapshot.totalBorrow = marketVaultInstance.totalBorrow();
        snapshot.totalBase = marketVaultInstance.totalBase();
    }

    /**
     * @notice Helper function to log balance snapshot
     */
    function _logBalanceSnapshot(string memory label, BalanceSnapshot memory snapshot) internal pure {
        console2.log(string(abi.encodePacked("--- ", label, " STATE ---")));
        console2.log("Alice USDC:", snapshot.aliceUSDC / 1e6);
        console2.log("Bob USDC:", snapshot.bobUSDC / 1e6);
        console2.log("Timelock Shares:", snapshot.timelockShares / 1e6);
        console2.log("Vault USDC:", snapshot.vaultUSDC / 1e6);
        console2.log("Total Base:", snapshot.totalBase / 1e6);
        console2.log("");
    }

    /**
     * @notice Complete position lifecycle test with REDEEM instead of withdraw
     * @dev Tests: deposit -> borrow -> yield boost -> repay -> redeem
     *      Validates all balances and commission collection using redeem function
     */
    function test_CompletePositionLifecycleWithRedeem() public {
        console2.log("=== STARTING POSITION LIFECYCLE TEST WITH REDEEM ===");

        // Position ID for tracking throughout the test
        uint256 positionId;

        // Step 1: Alice deposits liquidity
        _step1_AliceDepositsLiquidity();

        // Step 2: Bob borrows against collateral
        positionId = _step2_BobBorrowsAgainstCollateral();

        // Step 3: Time passes and yield boost occurs
        _step3_TimePassesAndYieldBoost();

        // Step 4: Bob repays loan
        _step4_BobRepaysLoan(positionId);

        // Step 5: Bob withdraws collateral
        _step5_BobWithdrawsCollateral(positionId);

        // Step 6: Alice redeems shares (instead of withdraw)
        _step6_AliceRedeemsShares();

        // Step 7: Final validation
        _step7_FinalValidation();

        console2.log("=== POSITION LIFECYCLE TEST WITH REDEEM COMPLETED SUCCESSFULLY ===");
    }

    function _step6_AliceRedeemsShares() internal {
        console2.log("\n=== STEP 6: ALICE REDEEMS SHARES ===");

        vm.startPrank(testAlice);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        console2.log("Total vault value:", marketVaultInstance.totalBase() / 1e6);
        console2.log("Alice's shares:", marketVaultInstance.balanceOf(testAlice) / 1e6);

        // Alice redeems all her shares
        uint256 aliceShares = marketVaultInstance.balanceOf(testAlice);
        uint256 maxRedeemableShares = marketVaultInstance.maxRedeem(testAlice);
        console2.log("Max redeemable shares:", maxRedeemableShares / 1e6);

        // Use the smaller of Alice's balance or max redeemable
        uint256 sharesToRedeem = aliceShares > maxRedeemableShares ? maxRedeemableShares : aliceShares;

        // Preview how much USDC Alice will receive
        uint256 expectedUsdc = marketVaultInstance.previewRedeem(sharesToRedeem);
        console2.log("Alice redeeming shares:", sharesToRedeem / 1e6);
        console2.log("Expected USDC from redeem:", expectedUsdc / 1e6);

        // Redeem shares
        uint256 receivedUsdc = marketVaultInstance.redeem(sharesToRedeem, testAlice, testAlice);
        console2.log("Actual USDC received:", receivedUsdc / 1e6);

        console2.log(
            "Commission shares minted to timelock:", marketVaultInstance.balanceOf(marketVaultInstance.timelock()) / 1e6
        );
        vm.stopPrank();
    }
}
