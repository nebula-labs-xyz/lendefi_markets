// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../BasicDeploy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";
import {LendefiCore} from "../../contracts/markets/LendefiCore.sol";
import {LendefiMarketVault} from "../../contracts/markets/LendefiMarketVault.sol";
import {LendefiMarketFactory} from "../../contracts/markets/LendefiMarketFactory.sol";
import {LendefiPositionVault} from "../../contracts/markets/LendefiPositionVault.sol";
import {WETH9} from "../../contracts/vendor/canonical-weth/contracts/WETH9.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {LendefiConstants} from "../../contracts/markets/lib/LendefiConstants.sol";

contract LendefiMarketFactoryTest is BasicDeploy {
    // Additional test tokens
    TokenMock public daiToken;
    TokenMock public usdtToken;

    // Events
    event MarketCreated(
        address indexed baseAsset,
        address indexed core,
        address indexed baseVault,
        string name,
        string symbol,
        address porFeed
    );

    function setUp() public {
        // Deploy base contracts and market
        deployMarketsWithUSDC();

        // Setup TGE
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy additional tokens for multi-market tests
        daiToken = new TokenMock("DAI Stablecoin", "DAI");
        usdtToken = new TokenMock("Tether USD", "USDT");

        // Set decimals for USDT (6 decimals like real USDT)
        vm.mockCall(address(usdtToken), abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(6));

        // Deploy and setup WETH for integration tests
        wethInstance = new WETH9();
    }

    // ============ Factory Initialization Tests ============

    function test_FactoryInitialize() public {
        assertEq(marketFactoryInstance.treasury(), address(treasuryInstance));
        assertEq(marketFactoryInstance.assetsModule(), address(assetsInstance));
        assertEq(marketFactoryInstance.govToken(), address(tokenInstance));
        assertEq(marketFactoryInstance.timelock(), address(timelockInstance));
        assertTrue(marketFactoryInstance.hasRole(DEFAULT_ADMIN_ROLE, address(timelockInstance)));
    }

    function test_Revert_FactoryInitializeTwice() public {
        vm.expectRevert();
        marketFactoryInstance.initialize(
            address(timelockInstance),
            address(treasuryInstance),
            address(assetsInstance),
            address(tokenInstance),
            address(0),
            address(ecoInstance)
        );
    }

    function test_Revert_FactoryInitializeZeroAddress() public {
        LendefiMarketFactory newFactory = new LendefiMarketFactory();

        // The factory uses InvalidInitialization when admin is zero
        vm.expectRevert();
        newFactory.initialize(
            address(0),
            address(treasuryInstance),
            address(assetsInstance),
            address(tokenInstance),
            address(0),
            address(ecoInstance)
        );
    }

    // ============ Implementation Management Tests ============

    function test_SetImplementations() public {
        LendefiCore newCoreImpl = new LendefiCore();
        LendefiMarketVault newVaultImpl = new LendefiMarketVault();
        LendefiPositionVault posVaultImpl = new LendefiPositionVault();

        vm.expectEmit(true, true, true, true);
        emit LendefiMarketFactory.ImplementationsSet(address(newCoreImpl), address(newVaultImpl), address(posVaultImpl));

        vm.prank(address(timelockInstance));
        marketFactoryInstance.setImplementations(address(newCoreImpl), address(newVaultImpl), address(posVaultImpl));

        assertEq(marketFactoryInstance.coreImplementation(), address(newCoreImpl));
        assertEq(marketFactoryInstance.vaultImplementation(), address(newVaultImpl));
        assertEq(marketFactoryInstance.positionVaultImplementation(), address(posVaultImpl));
    }

    function test_Revert_SetImplementations_Unauthorized() public {
        LendefiCore newCoreImpl = new LendefiCore();

        LendefiPositionVault posVaultImpl = new LendefiPositionVault();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, DEFAULT_ADMIN_ROLE)
        );
        marketFactoryInstance.setImplementations(address(newCoreImpl), address(0), address(posVaultImpl));
    }

    // ============ Market Creation Tests ============

    function test_CreateMarket_USDC() public {
        // USDC market is already created in setup
        IPROTOCOL.Market memory market = marketFactoryInstance.getMarketInfo(address(usdcInstance));

        assertEq(market.baseAsset, address(usdcInstance));
        assertEq(market.name, "Lendefi Yield Token"); // This is the name used in deployMarketsWithUSDC
        assertEq(market.symbol, "LYTUSDC"); // This is the symbol used in deployMarketsWithUSDC
        assertEq(market.decimals, 6);
        assertTrue(market.active);
        assertTrue(market.core != address(0));
        assertTrue(market.baseVault != address(0));
        assertTrue(market.createdAt > 0);
    }

    function test_CreateMarket_DAI() public {
        vm.prank(address(timelockInstance));
        marketFactoryInstance.createMarket(address(daiToken), "Lendefi DAI Market", "lfDAI");

        // Verify market was created
        IPROTOCOL.Market memory createdMarket = marketFactoryInstance.getMarketInfo(address(daiToken));
        assertEq(createdMarket.baseAsset, address(daiToken));
        assertEq(createdMarket.name, "Lendefi DAI Market");
        assertTrue(createdMarket.core != address(0));
        assertTrue(createdMarket.baseVault != address(0));

        // Verify core and vault are properly initialized
        LendefiCore daiCore = LendefiCore(createdMarket.core);
        LendefiMarketVault daiVault = LendefiMarketVault(createdMarket.baseVault);

        assertEq(daiCore.baseAsset(), address(daiToken));

        assertEq(daiVault.asset(), address(daiToken));
        assertEq(daiVault.name(), "Lendefi DAI Market");
        assertEq(daiVault.symbol(), "lfDAI");
    }

    function test_CreateMarket_USDT_6Decimals() public {
        vm.prank(address(timelockInstance));

        marketFactoryInstance.createMarket(address(usdtToken), "Lendefi USDT Market", "lfUSDT");

        IPROTOCOL.Market memory createdMarket = marketFactoryInstance.getMarketInfo(address(usdtToken));
        LendefiCore usdtCore = LendefiCore(createdMarket.core);

        // Verify WAD is correctly set for 6 decimal token
        assertEq(usdtCore.baseDecimals(), 1e6);
    }

    function test_Revert_CreateMarket_Duplicate() public {
        // Try to create another USDC market
        vm.prank(address(timelockInstance));
        vm.expectRevert(LendefiMarketFactory.MarketAlreadyExists.selector);
        marketFactoryInstance.createMarket(address(usdcInstance), "Duplicate Market", "DUP");
    }

    function test_Revert_CreateMarket_ZeroAsset() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(LendefiMarketFactory.ZeroAddress.selector);
        marketFactoryInstance.createMarket(address(0), "Bad Market", "BAD");
    }

    function test_Revert_CreateMarket_Unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, DEFAULT_ADMIN_ROLE)
        );
        marketFactoryInstance.createMarket(address(daiToken), "Unauthorized Market", "UNAUTH");
    }

    // ============ Market Query Tests ============

    function test_GetMarketInfo() public {
        IPROTOCOL.Market memory market = marketFactoryInstance.getMarketInfo(address(usdcInstance));

        assertEq(market.baseAsset, address(usdcInstance));
        assertEq(market.core, address(marketCoreInstance));
        assertEq(market.baseVault, address(marketVaultInstance));
        assertTrue(market.active);
    }

    function test_Revert_GetMarketInfo_NotFound() public {
        vm.expectRevert(LendefiMarketFactory.MarketNotFound.selector);
        marketFactoryInstance.getMarketInfo(address(daiToken));
    }

    function test_Revert_GetMarketInfo_ZeroAddress() public {
        vm.expectRevert(LendefiMarketFactory.ZeroAddress.selector);
        marketFactoryInstance.getMarketInfo(address(0));
    }

    function test_IsMarketActive() public {
        assertTrue(marketFactoryInstance.isMarketActive(address(usdcInstance)));
        assertFalse(marketFactoryInstance.isMarketActive(address(daiToken)));
    }

    function test_GetAllActiveMarkets() public {
        // Initially only USDC market
        address[] memory activeMarkets = marketFactoryInstance.getAllActiveMarkets();
        assertEq(activeMarkets.length, 1);
        assertEq(activeMarkets[0], address(usdcInstance));

        // Create DAI market
        vm.prank(address(timelockInstance));
        marketFactoryInstance.createMarket(address(daiToken), "Lendefi DAI Market", "lfDAI");

        // Create USDT market
        vm.prank(address(timelockInstance));
        marketFactoryInstance.createMarket(address(usdtToken), "Lendefi USDT Market", "lfUSDT");

        // Should have 3 active markets
        activeMarkets = marketFactoryInstance.getAllActiveMarkets();
        assertEq(activeMarkets.length, 3);
        assertEq(activeMarkets[0], address(usdcInstance));
        assertEq(activeMarkets[1], address(daiToken));
        assertEq(activeMarkets[2], address(usdtToken));
    }

    // ============ Integration Tests ============

    function test_Integration_MultiMarketOperations() public {
        // Deploy proper mock oracle for WETH
        WETHPriceConsumerV3 wethOracle = new WETHPriceConsumerV3();
        wethOracle.setPrice(int256(2500e8)); // $2500 per ETH

        // First configure WETH as a valid collateral asset
        vm.startPrank(address(timelockInstance));

        // Configure WETH as an asset in the assets module
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 750, // 75% LTV
                liquidationThreshold: 800, // 80% liquidation
                maxSupplyThreshold: 10_000 ether,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}), // Proper mock oracle
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Configure DAI as an asset in the assets module (needed for credit limit calculations)
        WETHPriceConsumerV3 daiOracle = new WETHPriceConsumerV3();
        daiOracle.setPrice(int256(1e8)); // $1 per DAI
        assetsInstance.updateAssetConfig(
            address(daiToken),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 950, // 95% LTV for stablecoin
                liquidationThreshold: 980, // 98% liquidation
                maxSupplyThreshold: 100_000_000 ether,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(daiOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
        vm.stopPrank();

        // Create DAI market
        vm.prank(address(timelockInstance));
        marketFactoryInstance.createMarket(address(daiToken), "Lendefi DAI Market", "lfDAI");

        IPROTOCOL.Market memory daiMarket = marketFactoryInstance.getMarketInfo(address(daiToken));
        LendefiCore daiCore = LendefiCore(daiMarket.core);
        LendefiMarketVault daiVault = LendefiMarketVault(daiMarket.baseVault);

        // Grant ecosystem role and set core address
        vm.startPrank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, address(daiCore));
        assetsInstance.setCoreAddress(address(daiCore));
        vm.stopPrank();

        // Supply liquidity to DAI market
        uint256 daiAmount = 100_000 ether;
        deal(address(daiToken), alice, daiAmount);

        vm.startPrank(alice);
        daiToken.approve(address(daiCore), daiAmount);
        daiCore.depositLiquidity(daiAmount, daiVault.previewDeposit(daiAmount), 100);
        vm.stopPrank();

        // Create position in DAI market
        vm.prank(bob);
        daiCore.createPosition(address(wethInstance), false);

        // Supply collateral
        deal(address(wethInstance), bob, 1 ether);
        vm.startPrank(bob);
        wethInstance.approve(address(daiCore), 1 ether);
        daiCore.supplyCollateral(address(wethInstance), 1 ether, 0);

        // Borrow DAI
        uint256 borrowAmount = 1000 ether;
        daiCore.borrow(0, borrowAmount, daiCore.calculateCreditLimit(bob, 0), 100);
        vm.stopPrank();

        // Verify cross-market independence
        assertEq(daiVault.totalBorrow(), borrowAmount);
        assertEq(marketVaultInstance.totalBorrow(), 0); // USDC market unaffected

        // Verify both markets track collateral independently
        (uint256 daiTvl,,) = daiCore.getAssetTVL(address(wethInstance));
        (uint256 usdcTvl,,) = marketCoreInstance.getAssetTVL(address(wethInstance));
        assertEq(daiTvl, 1 ether);
        assertEq(usdcTvl, 0);
    }

    // ============ Upgrade Tests ============

    function testRevert_FactoryUpgrade() public {
        // Deploy new implementation
        LendefiMarketFactory newImpl = new LendefiMarketFactory();
        // Upgrade should only work from timelock
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", alice, LendefiConstants.UPGRADER_ROLE
            )
        );
        vm.prank(alice);
        marketFactoryInstance.upgradeToAndCall(address(newImpl), "");

        // Upgrade from timelock
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("UpgradeNotScheduled()"));
        marketFactoryInstance.upgradeToAndCall(address(newImpl), "");
    }

    function test_CancelUpgrade() public {
        // Deploy new implementation
        LendefiMarketFactory newImpl = new LendefiMarketFactory();

        // Schedule an upgrade first
        vm.prank(address(timelockInstance));
        marketFactoryInstance.scheduleUpgrade(address(newImpl));

        // Verify upgrade is scheduled
        (address impl,, bool exists) = marketFactoryInstance.pendingUpgrade();
        assertTrue(exists, "Upgrade should be scheduled");
        assertEq(impl, address(newImpl), "Implementation should match");

        // Cancel the upgrade
        vm.prank(address(timelockInstance));
        vm.expectEmit(true, true, false, true);
        emit UpgradeCancelled(address(timelockInstance), address(newImpl));
        marketFactoryInstance.cancelUpgrade();

        // Verify upgrade is cancelled
        (address implAfter,, bool existsAfter) = marketFactoryInstance.pendingUpgrade();
        assertFalse(existsAfter, "Upgrade should be cancelled");
        assertEq(implAfter, address(0), "Implementation should be cleared");
    }

    function test_Revert_CancelUpgrade_NotScheduled() public {
        // Try to cancel when no upgrade is scheduled
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("UpgradeNotScheduled()"));
        marketFactoryInstance.cancelUpgrade();
    }

    function test_Revert_CancelUpgrade_Unauthorized() public {
        // Deploy new implementation and schedule upgrade
        LendefiMarketFactory newImpl = new LendefiMarketFactory();
        vm.prank(address(timelockInstance));
        marketFactoryInstance.scheduleUpgrade(address(newImpl));

        // Try to cancel from unauthorized account
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", alice, LendefiConstants.UPGRADER_ROLE
            )
        );
        vm.prank(alice);
        marketFactoryInstance.cancelUpgrade();
    }

    function test_UpgradeTimelockRemaining() public {
        // No upgrade scheduled - should return 0
        assertEq(marketFactoryInstance.upgradeTimelockRemaining(), 0, "Should return 0 when no upgrade scheduled");

        // Deploy new implementation and schedule upgrade
        LendefiMarketFactory newImpl = new LendefiMarketFactory();
        uint256 scheduleTime = block.timestamp;

        vm.prank(address(timelockInstance));
        marketFactoryInstance.scheduleUpgrade(address(newImpl));

        // Should return the full timelock duration immediately after scheduling
        uint256 expectedRemaining = LendefiConstants.UPGRADE_TIMELOCK_DURATION;
        assertEq(
            marketFactoryInstance.upgradeTimelockRemaining(), expectedRemaining, "Should return full timelock duration"
        );

        // Fast forward 1 day
        vm.warp(block.timestamp + 1 days);
        expectedRemaining = LendefiConstants.UPGRADE_TIMELOCK_DURATION - 1 days;
        assertEq(
            marketFactoryInstance.upgradeTimelockRemaining(),
            expectedRemaining,
            "Should return remaining time after 1 day"
        );

        // Fast forward 2 more days (total 3 days = full timelock period)
        vm.warp(scheduleTime + LendefiConstants.UPGRADE_TIMELOCK_DURATION);
        assertEq(marketFactoryInstance.upgradeTimelockRemaining(), 0, "Should return 0 when timelock expires");

        // Fast forward past expiration
        vm.warp(scheduleTime + LendefiConstants.UPGRADE_TIMELOCK_DURATION + 1 hours);
        assertEq(marketFactoryInstance.upgradeTimelockRemaining(), 0, "Should return 0 after timelock expires");
    }

    function test_UpgradeTimelockRemaining_AfterCancel() public {
        // Deploy new implementation and schedule upgrade
        LendefiMarketFactory newImpl = new LendefiMarketFactory();

        vm.prank(address(timelockInstance));
        marketFactoryInstance.scheduleUpgrade(address(newImpl));

        // Verify timelock is active
        assertGt(marketFactoryInstance.upgradeTimelockRemaining(), 0, "Should have remaining time");

        // Cancel the upgrade
        vm.prank(address(timelockInstance));
        marketFactoryInstance.cancelUpgrade();

        // Should return 0 after cancellation
        assertEq(marketFactoryInstance.upgradeTimelockRemaining(), 0, "Should return 0 after cancellation");
    }

    function test_Revert_SetImplementations_ZeroAddress() public {
        // Test zero core implementation
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        marketFactoryInstance.setImplementations(address(0), address(0x1), address(0x2));

        // Test zero vault implementation
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        marketFactoryInstance.setImplementations(address(0x1), address(0), address(0x2));

        // Test zero position vault implementation
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        marketFactoryInstance.setImplementations(address(0x1), address(0x2), address(0));
    }

    function test_Revert_AuthorizeUpgrade_ImplementationMismatch() public {
        // Deploy two different implementations
        LendefiMarketFactory newImpl1 = new LendefiMarketFactory();
        LendefiMarketFactory newImpl2 = new LendefiMarketFactory();

        // Schedule upgrade with first implementation
        vm.prank(address(timelockInstance));
        marketFactoryInstance.scheduleUpgrade(address(newImpl1));

        // Fast forward past timelock
        vm.warp(block.timestamp + LendefiConstants.UPGRADE_TIMELOCK_DURATION + 1);

        // Try to upgrade with different implementation
        vm.prank(address(timelockInstance));
        vm.expectRevert(
            abi.encodeWithSignature("ImplementationMismatch(address,address)", address(newImpl1), address(newImpl2))
        );
        marketFactoryInstance.upgradeToAndCall(address(newImpl2), "");
    }

    function test_Revert_AuthorizeUpgrade_TimelockActive() public {
        // Deploy new implementation
        LendefiMarketFactory newImpl = new LendefiMarketFactory();

        // Schedule upgrade
        vm.prank(address(timelockInstance));
        marketFactoryInstance.scheduleUpgrade(address(newImpl));

        // Try to upgrade immediately (before timelock expires)
        vm.prank(address(timelockInstance));
        vm.expectRevert(
            abi.encodeWithSignature("UpgradeTimelockActive(uint256)", LendefiConstants.UPGRADE_TIMELOCK_DURATION)
        );
        marketFactoryInstance.upgradeToAndCall(address(newImpl), "");

        // Fast forward 1 day (still within timelock)
        vm.warp(block.timestamp + 1 days);

        vm.prank(address(timelockInstance));
        vm.expectRevert(
            abi.encodeWithSignature(
                "UpgradeTimelockActive(uint256)", LendefiConstants.UPGRADE_TIMELOCK_DURATION - 1 days
            )
        );
        marketFactoryInstance.upgradeToAndCall(address(newImpl), "");
    }

    // Add missing events
    event UpgradeCancelled(address indexed canceller, address indexed implementation);
}
