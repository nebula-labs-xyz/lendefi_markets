// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {IASSETS} from "../../contracts/interfaces/IASSETS.sol";
import {IECOSYSTEM} from "../../contracts/interfaces/IEcosystem.sol";
import {IPoRFeed} from "../../contracts/interfaces/IPoRFeed.sol";
import {LendefiMarketVault} from "../../contracts/markets/LendefiMarketVault.sol";
import {MockPriceOracle} from "../../contracts/mock/MockPriceOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title LendefiMarketVaultCoverageTest_Simple
 * @notice Simplified test suite to improve code coverage for LendefiMarketVault
 * @dev Focuses on uncovered functions without modifying protocol config
 */
contract LendefiMarketVault_TestOne is BasicDeploy {
    MockPriceOracle internal usdcOracleInstance;
    MockPriceOracle internal wethOracleInstance;

    // Test constants
    uint256 constant INITIAL_DEPOSIT = 100_000e6; // 100k USDC
    uint256 constant WETH_COLLATERAL = 50 ether; // 50 WETH
    uint256 constant BORROW_AMOUNT = 50_000e6; // 50k USDC

    function setUp() public {
        // Create oracles
        usdcOracleInstance = new MockPriceOracle();
        usdcOracleInstance.setPrice(1e8); // $1 per USDC
        usdcOracleInstance.setTimestamp(block.timestamp);
        usdcOracleInstance.setRoundId(1);
        usdcOracleInstance.setAnsweredInRound(1);

        wethOracleInstance = new MockPriceOracle();
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        wethOracleInstance.setTimestamp(block.timestamp);
        wethOracleInstance.setRoundId(1);
        wethOracleInstance.setAnsweredInRound(1);

        // Deploy complete system
        deployCompleteWithOracle();
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        _deployMarket(address(usdcInstance), "Lendefi Yield Token", "LYTUSDC");

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
                maxSupplyThreshold: 1_000_000e6,
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
        wethInstance = new WETH9();
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Update oracle timestamps to be current
        usdcOracleInstance.setTimestamp(block.timestamp);
        wethOracleInstance.setTimestamp(block.timestamp);

        vm.stopPrank();

        // Setup initial liquidity
        _setupInitialState();

        // Grant necessary roles for rewards to work and configure protocol
        vm.startPrank(address(timelockInstance));

        // Grant the REWARDER_ROLE to the vault contract for ecosystem rewards
        ecoInstance.grantRole(REWARDER_ROLE, address(marketVaultInstance));

        // Initialize reward parameters via timelock using the config approach
        IPROTOCOL.ProtocolConfig memory config = marketCoreInstance.getConfig();

        // Update specific parameters while keeping others
        config.rewardAmount = 1_000e18; // Set target reward to 1000 tokens
        config.rewardInterval = 180 * 24 * 60 * 5; // 180 days in blocks (5 blocks per minute)
        config.rewardableSupply = 100_000e6; // Set rewardable supply to 100k USDC

        // Apply updated config
        marketCoreInstance.loadProtocolConfig(config);

        vm.stopPrank();
    }

    function _setupInitialState() internal {
        // Provide initial liquidity
        usdcInstance.mint(alice, INITIAL_DEPOSIT);
        vm.startPrank(alice);
        usdcInstance.approve(address(marketCoreInstance), INITIAL_DEPOSIT);
        uint256 expectedShares = marketVaultInstance.previewDeposit(INITIAL_DEPOSIT);
        marketCoreInstance.depositLiquidity(INITIAL_DEPOSIT, expectedShares, 100);
        vm.stopPrank();

        // Setup borrowing position for utilization
        vm.deal(bob, WETH_COLLATERAL);
        vm.startPrank(bob);
        wethInstance.deposit{value: WETH_COLLATERAL}();
        vm.stopPrank();

        // Create position and supply collateral using helper functions
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, positionId, address(wethInstance), WETH_COLLATERAL);
        _borrow(bob, positionId, BORROW_AMOUNT);
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

    function _borrow(address user, uint256 positionId, uint256 amount) internal {
        vm.startPrank(user);
        uint256 creditLimit = marketCoreInstance.calculateCreditLimit(user, positionId);
        marketCoreInstance.borrow(positionId, amount, creditLimit, 100);
        vm.stopPrank();
    }

    // ========== CHAINLINK AUTOMATION TESTS ==========

    function test_CheckUpkeep_WhenIntervalPassed() public {
        vm.warp(block.timestamp + 13 hours);

        (bool upkeepNeeded, bytes memory performData) = marketVaultInstance.checkUpkeep("");

        assertTrue(upkeepNeeded, "Upkeep should be needed after interval");
        assertEq(performData, "0x00", "Perform data should be empty");
    }

    function test_CheckUpkeep_WhenIntervalNotPassed() public {
        vm.warp(block.timestamp + 6 hours);

        (bool upkeepNeeded, bytes memory performData) = marketVaultInstance.checkUpkeep("");

        assertFalse(upkeepNeeded, "Upkeep should not be needed before interval");
        assertEq(performData, "0x00", "Perform data should be empty");
    }

    function test_PerformUpkeep_UpdatesStateWhenIntervalPassed() public {
        uint256 initialCounter = marketVaultInstance.counter();

        vm.warp(block.timestamp + 13 hours);
        marketVaultInstance.performUpkeep("");

        assertEq(marketVaultInstance.counter(), initialCounter + 1, "Counter should increment");
        assertEq(marketVaultInstance.lastTimeStamp(), block.timestamp, "Timestamp should update");
    }

    function test_PerformUpkeep_DoesNothingWhenIntervalNotPassed() public {
        uint256 initialCounter = marketVaultInstance.counter();
        uint256 initialTimestamp = marketVaultInstance.lastTimeStamp();

        vm.warp(block.timestamp + 6 hours);
        marketVaultInstance.performUpkeep("");

        assertEq(marketVaultInstance.counter(), initialCounter, "Counter should not change");
        assertEq(marketVaultInstance.lastTimeStamp(), initialTimestamp, "Timestamp should not change");
    }

    function test_PerformUpkeep_UpdatesPoRFeed() public {
        address porFeed = marketVaultInstance.porFeed();

        vm.warp(block.timestamp + 13 hours);
        marketVaultInstance.performUpkeep("");

        // Check that PoR feed has been updated (basic check)
        (, int256 answer,,,) = IPoRFeed(porFeed).latestRoundData();
        assertGt(uint256(answer), 0, "PoR feed should have updated reserves");
    }

    // ========== REWARD SYSTEM TESTS ==========

    function test_IsRewardable_InsufficientBalance() public {
        // Charlie has no deposits, should not be rewardable
        bool rewardable = marketVaultInstance.isRewardable(charlie);
        assertFalse(rewardable, "User with no deposits should not be rewardable");
    }

    function test_IsRewardable_SufficientBalanceAndTime() public {
        // Get the updated config
        IPROTOCOL.ProtocolConfig memory config = marketCoreInstance.getConfig();

        // Charlie deposits enough to meet threshold
        usdcInstance.mint(charlie, 150_000e6); // More than 100k threshold
        vm.startPrank(charlie);
        usdcInstance.approve(address(marketCoreInstance), 150_000e6);
        uint256 expectedShares = marketVaultInstance.previewDeposit(150_000e6);
        marketCoreInstance.depositLiquidity(150_000e6, expectedShares, 100);
        vm.stopPrank();

        // Fast-forward past the reward interval
        vm.roll(block.number + config.rewardInterval + 1);

        // Should now be rewardable
        bool rewardable = marketVaultInstance.isRewardable(charlie);
        assertTrue(rewardable, "User with sufficient balance and time should be rewardable");
    }

    function test_ClaimReward_IneligibleUser() public {
        // Charlie has no deposits, should get 0 reward
        vm.startPrank(charlie);
        uint256 reward = marketVaultInstance.claimReward();
        vm.stopPrank();

        assertEq(reward, 0, "Ineligible user should receive no reward");
    }

    function test_ClaimReward_EligibleUser() public {
        // Get the updated config
        IPROTOCOL.ProtocolConfig memory config = marketCoreInstance.getConfig();

        // Charlie deposits enough to meet threshold
        usdcInstance.mint(charlie, 150_000e6);
        vm.startPrank(charlie);
        usdcInstance.approve(address(marketCoreInstance), 150_000e6);
        uint256 expectedShares = marketVaultInstance.previewDeposit(150_000e6);
        marketCoreInstance.depositLiquidity(150_000e6, expectedShares, 100);
        vm.stopPrank();

        // Fast-forward past the reward interval
        vm.roll(block.number + config.rewardInterval + 1);

        // Record initial governance token balance
        uint256 initialGovBalance = tokenInstance.balanceOf(charlie);

        // Claim reward
        vm.startPrank(charlie);
        uint256 rewardAmount = marketVaultInstance.claimReward();
        vm.stopPrank();

        // Should receive approximately the configured reward amount (time-based calculation)
        assertApproxEqAbs(
            rewardAmount, config.rewardAmount, 1e18, "Should receive approximately configured reward amount"
        );
        assertEq(
            tokenInstance.balanceOf(charlie),
            initialGovBalance + rewardAmount,
            "Governance tokens should be transferred"
        );
    }

    // ========== ADMIN FUNCTIONS TESTS ==========

    function test_Pause_AffectsUserOperations() public {
        vm.prank(address(timelockInstance));
        marketVaultInstance.pause();

        usdcInstance.mint(charlie, 1000e6);
        vm.startPrank(charlie);
        usdcInstance.approve(address(marketVaultInstance), 1000e6);

        vm.expectRevert();
        marketVaultInstance.deposit(1000e6, charlie);

        vm.stopPrank();
    }

    function test_Unpause_RestoresOperations() public {
        vm.startPrank(address(timelockInstance));
        marketVaultInstance.pause();
        marketVaultInstance.unpause();
        vm.stopPrank();

        usdcInstance.mint(charlie, 1000e6);
        vm.startPrank(charlie);
        usdcInstance.approve(address(marketVaultInstance), 1000e6);

        uint256 shares = marketVaultInstance.deposit(1000e6, charlie);
        assertGt(shares, 0, "Should receive shares after unpause");

        vm.stopPrank();
    }

    // ========== VIEW FUNCTIONS TESTS ==========

    function test_TotalAssets_ReturnsTotalBase() public {
        uint256 totalAssets = marketVaultInstance.totalAssets();
        uint256 totalBase = marketVaultInstance.totalBase();

        assertEq(totalAssets, totalBase, "totalAssets should equal totalBase");
    }

    function test_Utilization_WithActiveLoans() public {
        uint256 util = marketVaultInstance.utilization();
        assertGt(util, 0, "Utilization should be greater than 0 with active borrowing");
    }


    function test_GetBorrowRate_DifferentTiers() public {
        uint256 stableRate = marketVaultInstance.getBorrowRate(IASSETS.CollateralTier.STABLE);
        uint256 crossARate = marketVaultInstance.getBorrowRate(IASSETS.CollateralTier.CROSS_A);
        uint256 crossBRate = marketVaultInstance.getBorrowRate(IASSETS.CollateralTier.CROSS_B);
        uint256 isolatedRate = marketVaultInstance.getBorrowRate(IASSETS.CollateralTier.ISOLATED);

        assertGt(stableRate, 0, "Stable tier should have positive borrow rate");
        assertGt(crossARate, 0, "Cross A tier should have positive borrow rate");
        assertGt(crossBRate, 0, "Cross B tier should have positive borrow rate");
        assertGt(isolatedRate, 0, "Isolated tier should have positive borrow rate");
    }
}
