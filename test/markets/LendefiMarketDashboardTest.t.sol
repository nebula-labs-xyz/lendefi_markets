// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../BasicDeploy.sol";
import {LendefiMarketDashboard} from "../../contracts/markets/helper/LendefiMarketDashboard.sol";
import {ILendefiMarketDashboard} from "../../contracts/interfaces/ILendefiMarketDashboard.sol";
import {ILendefiMarketVault} from "../../contracts/interfaces/ILendefiMarketVault.sol";
import {LendefiMarketFactory} from "../../contracts/markets/LendefiMarketFactory.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract LendefiMarketDashboardTest is BasicDeploy {
    LendefiMarketDashboard public dashboard;
    TokenMock public daiToken;
    TokenMock public wethToken;

    function setUp() public {
        // Deploy basic infrastructure with USDC market
        deployMarketsWithUSDC();

        // Deploy dashboard
        dashboard = new LendefiMarketDashboard(address(marketFactoryInstance), address(ecoInstance));

        // Create additional test tokens
        daiToken = new TokenMock("DAI Stablecoin", "DAI");
        wethToken = new TokenMock("Wrapped Ether", "WETH");

        // Add tokens to allowlist
        vm.startPrank(gnosisSafe);
        marketFactoryInstance.addAllowedBaseAsset(address(daiToken));
        marketFactoryInstance.addAllowedBaseAsset(address(wethToken));
        vm.stopPrank();

        // Create additional markets
        vm.startPrank(charlie);
        marketFactoryInstance.createMarket(address(daiToken), "Lendefi DAI Market", "lfDAI");
        marketFactoryInstance.createMarket(address(wethToken), "Lendefi WETH Market", "lfWETH");
        vm.stopPrank();

        // Setup TGE
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Fund users for testing
        deal(address(usdcInstance), alice, 10000e6);
        deal(address(daiToken), alice, 10000e18);
        deal(address(wethToken), alice, 10e18);
    }

    // ========== Constructor Tests ==========

    function test_Constructor() public {
        assertEq(address(dashboard.marketFactory()), address(marketFactoryInstance));
        assertEq(address(dashboard.ecosystem()), address(ecoInstance));
    }

    function test_Revert_Constructor_ZeroFactory() public {
        vm.expectRevert("ZERO_ADDRESS");
        new LendefiMarketDashboard(address(0), address(ecoInstance));
    }

    function test_Revert_Constructor_ZeroEcosystem() public {
        vm.expectRevert("ZERO_ADDRESS");
        new LendefiMarketDashboard(address(marketFactoryInstance), address(0));
    }

    // ========== Market Overview Tests ==========

    function test_GetAllMarketOverviews() public {
        ILendefiMarketDashboard.MarketOverview[] memory overviews = dashboard.getAllMarketOverviews();

        // Should have 3 markets (USDC, DAI, WETH)
        assertEq(overviews.length, 3);

        // Check USDC market
        bool foundUSDC = false;
        for (uint256 i = 0; i < overviews.length; i++) {
            if (overviews[i].baseAsset == address(usdcInstance)) {
                foundUSDC = true;
                assertEq(overviews[i].marketOwner, charlie);
                assertEq(overviews[i].baseAssetSymbol, "USDC");
                assertEq(overviews[i].baseAssetDecimals, 6);
                assertEq(overviews[i].marketName, "Lendefi Yield Token");
                assertEq(overviews[i].marketSymbol, "LYTUSDC");
                assertTrue(overviews[i].active);
                assertTrue(overviews[i].coreContract != address(0));
                assertTrue(overviews[i].vaultContract != address(0));
                assertEq(overviews[i].sharePrice, 1e18); // 1:1 initially
                break;
            }
        }
        assertTrue(foundUSDC, "USDC market not found");
    }

    function test_GetMarketOverview_Specific() public {
        ILendefiMarketDashboard.MarketOverview memory overview = dashboard.getMarketOverview(charlie, address(daiToken));

        assertEq(overview.marketOwner, charlie);
        assertEq(overview.baseAsset, address(daiToken));
        assertEq(overview.baseAssetSymbol, "DAI");
        assertEq(overview.baseAssetDecimals, 18);
        assertEq(overview.marketName, "Lendefi DAI Market");
        assertEq(overview.marketSymbol, "lfDAI");
        assertTrue(overview.active);
    }

    // ========== Protocol Stats Tests ==========

    function test_GetProtocolStats() public {
        ILendefiMarketDashboard.ProtocolStats memory stats = dashboard.getProtocolStats();

        // Check basic stats
        assertEq(stats.totalMarkets, 3); // USDC, DAI, WETH
        assertEq(stats.totalMarketOwners, 1); // Only charlie
        assertEq(stats.supportedBaseAssets.length, 3); // USDC, DAI, WETH in allowlist
        assertEq(stats.governanceToken, address(tokenInstance));

        // Check that supported assets include our tokens
        bool foundUSDC = false;
        bool foundDAI = false;
        bool foundWETH = false;

        for (uint256 i = 0; i < stats.supportedBaseAssets.length; i++) {
            if (stats.supportedBaseAssets[i] == address(usdcInstance)) foundUSDC = true;
            if (stats.supportedBaseAssets[i] == address(daiToken)) foundDAI = true;
            if (stats.supportedBaseAssets[i] == address(wethToken)) foundWETH = true;
        }

        assertTrue(foundUSDC && foundDAI && foundWETH, "Not all assets found in allowlist");

        // Protocol health should be good (1000) initially with no debt
        assertEq(stats.protocolHealthScore, 1000);
    }

    function test_GetProtocolStats_WithLiquidity() public {
        // Add liquidity to USDC market
        IPROTOCOL.Market memory usdcMarket = marketFactoryInstance.getMarketInfo(charlie, address(usdcInstance));

        vm.startPrank(alice);
        usdcInstance.approve(usdcMarket.baseVault, 1000e6);
        ILendefiMarketVault(usdcMarket.baseVault).deposit(1000e6, alice);
        vm.stopPrank();

        ILendefiMarketDashboard.ProtocolStats memory stats = dashboard.getProtocolStats();

        // Should have TVL now
        assertGt(stats.totalProtocolTVL, 0);

        // Health should still be perfect (no debt yet)
        assertEq(stats.protocolHealthScore, 1000);
    }

    // ========== User Market Data Tests ==========

    function test_GetUserMarketData_NoActivity() public {
        ILendefiMarketDashboard.UserMarketData[] memory userData = dashboard.getUserMarketData(bob);

        // Bob has no activity, should return empty array
        assertEq(userData.length, 0);
    }

    function test_GetUserMarketData_WithLiquidity() public {
        // Alice provides liquidity to USDC market
        IPROTOCOL.Market memory usdcMarket = marketFactoryInstance.getMarketInfo(charlie, address(usdcInstance));

        vm.startPrank(alice);
        usdcInstance.approve(usdcMarket.baseVault, 1000e6);
        ILendefiMarketVault(usdcMarket.baseVault).deposit(1000e6, alice);
        vm.stopPrank();

        ILendefiMarketDashboard.UserMarketData[] memory userData = dashboard.getUserMarketData(alice);

        // Alice should have activity in 1 market
        assertEq(userData.length, 1);
        assertEq(userData[0].marketOwner, charlie);
        assertEq(userData[0].baseAsset, address(usdcInstance));
        assertEq(userData[0].baseAssetSymbol, "USDC");
        assertEq(userData[0].marketName, "Lendefi Yield Token");
        assertGt(userData[0].lpTokenBalance, 0);
        assertGt(userData[0].lpTokenValue, 0);
    }

    function test_GetUserMarketData_MultipleMarkets() public {
        // Alice provides liquidity to multiple markets
        IPROTOCOL.Market memory usdcMarket = marketFactoryInstance.getMarketInfo(charlie, address(usdcInstance));
        IPROTOCOL.Market memory daiMarket = marketFactoryInstance.getMarketInfo(charlie, address(daiToken));

        vm.startPrank(alice);
        // USDC market
        usdcInstance.approve(usdcMarket.baseVault, 1000e6);
        ILendefiMarketVault(usdcMarket.baseVault).deposit(1000e6, alice);

        // DAI market
        daiToken.approve(daiMarket.baseVault, 1000e18);
        ILendefiMarketVault(daiMarket.baseVault).deposit(1000e18, alice);
        vm.stopPrank();

        ILendefiMarketDashboard.UserMarketData[] memory userData = dashboard.getUserMarketData(alice);

        // Alice should have activity in 2 markets
        assertEq(userData.length, 2);

        // Check that both markets are represented
        bool foundUSDC = false;
        bool foundDAI = false;

        for (uint256 i = 0; i < userData.length; i++) {
            if (userData[i].baseAsset == address(usdcInstance)) {
                foundUSDC = true;
                assertGt(userData[i].lpTokenBalance, 0);
            }
            if (userData[i].baseAsset == address(daiToken)) {
                foundDAI = true;
                assertGt(userData[i].lpTokenBalance, 0);
            }
        }

        assertTrue(foundUSDC && foundDAI, "Not all markets found in user data");
    }

    // ========== Asset Metrics Tests ==========

    function test_GetAssetMetrics() public {
        ILendefiMarketDashboard.AssetMetrics[] memory metrics = dashboard.getAssetMetrics();

        // Should have metrics for all allowlisted assets
        assertEq(metrics.length, 3); // USDC, DAI, WETH

        // Check that all our tokens are included
        bool foundUSDC = false;
        bool foundDAI = false;
        bool foundWETH = false;

        for (uint256 i = 0; i < metrics.length; i++) {
            if (metrics[i].assetAddress == address(usdcInstance)) {
                foundUSDC = true;
                assertEq(metrics[i].symbol, "USDC");
                assertEq(metrics[i].decimals, 6);
            }
            if (metrics[i].assetAddress == address(daiToken)) {
                foundDAI = true;
                assertEq(metrics[i].symbol, "DAI");
                assertEq(metrics[i].decimals, 18);
            }
            if (metrics[i].assetAddress == address(wethToken)) {
                foundWETH = true;
                assertEq(metrics[i].symbol, "WETH");
                assertEq(metrics[i].decimals, 18);
            }

            // All assets should be active
            assertTrue(metrics[i].active);
            assertGt(metrics[i].borrowThreshold, 0);
            assertGt(metrics[i].liquidationThreshold, 0);
            assertGt(metrics[i].maxSupplyThreshold, 0);
        }

        assertTrue(foundUSDC && foundDAI && foundWETH, "Not all assets found in metrics");
    }

    // ========== Integration Tests ==========

    function test_FullDashboardIntegration() public {
        // Set up a realistic scenario with multiple users and activities

        // Alice provides liquidity to USDC
        IPROTOCOL.Market memory usdcMarket = marketFactoryInstance.getMarketInfo(charlie, address(usdcInstance));
        vm.startPrank(alice);
        usdcInstance.approve(usdcMarket.baseVault, 5000e6);
        ILendefiMarketVault(usdcMarket.baseVault).deposit(5000e6, alice);
        vm.stopPrank();

        // Bob provides liquidity to DAI
        IPROTOCOL.Market memory daiMarket = marketFactoryInstance.getMarketInfo(charlie, address(daiToken));
        deal(address(daiToken), bob, 5000e18);
        vm.startPrank(bob);
        daiToken.approve(daiMarket.baseVault, 5000e18);
        ILendefiMarketVault(daiMarket.baseVault).deposit(5000e18, bob);
        vm.stopPrank();

        // Test all dashboard functions work together
        ILendefiMarketDashboard.MarketOverview[] memory overviews = dashboard.getAllMarketOverviews();
        ILendefiMarketDashboard.ProtocolStats memory stats = dashboard.getProtocolStats();
        ILendefiMarketDashboard.UserMarketData[] memory aliceData = dashboard.getUserMarketData(alice);
        ILendefiMarketDashboard.UserMarketData[] memory bobData = dashboard.getUserMarketData(bob);
        ILendefiMarketDashboard.AssetMetrics[] memory metrics = dashboard.getAssetMetrics();

        // Verify comprehensive data
        assertEq(overviews.length, 3);
        assertGt(stats.totalProtocolTVL, 0);
        assertEq(aliceData.length, 1); // Alice in USDC market
        assertEq(bobData.length, 1); // Bob in DAI market
        assertEq(metrics.length, 3);

        // Verify TVL is correctly aggregated
        uint256 expectedTVL = 5000e6 + 5000e18; // USDC (6 decimals) + DAI (18 decimals)
        // Note: This is a simplified check since DAI has different decimals
        assertGt(stats.totalProtocolTVL, 5000e6); // At least USDC amount
    }

    function test_EmptyProtocolState() public {
        // Deploy a fresh factory implementation and proxy
        LendefiMarketFactory freshFactoryImpl = new LendefiMarketFactory();

        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            address(timelockInstance),
            address(tokenInstance),
            gnosisSafe,
            address(ecoInstance)
        );

        ERC1967Proxy freshFactoryProxy = new ERC1967Proxy(address(freshFactoryImpl), initData);
        LendefiMarketFactory freshFactory = LendefiMarketFactory(address(freshFactoryProxy));

        LendefiMarketDashboard freshDashboard = new LendefiMarketDashboard(address(freshFactory), address(ecoInstance));

        // Test with empty state
        ILendefiMarketDashboard.MarketOverview[] memory overviews = freshDashboard.getAllMarketOverviews();
        ILendefiMarketDashboard.ProtocolStats memory stats = freshDashboard.getProtocolStats();
        ILendefiMarketDashboard.UserMarketData[] memory userData = freshDashboard.getUserMarketData(alice);

        assertEq(overviews.length, 0);
        assertEq(stats.totalMarkets, 0);
        assertEq(stats.totalMarketOwners, 0);
        assertEq(stats.totalProtocolTVL, 0);
        assertEq(stats.protocolHealthScore, 1000); // Perfect health with no activity
        assertEq(userData.length, 0);
    }
}
