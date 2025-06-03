// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";
import {LendefiCore} from "../../contracts/markets/LendefiCore.sol";
import {LendefiMarketVault} from "../../contracts/markets/LendefiMarketVault.sol";
import {LendefiPositionVault} from "../../contracts/markets/LendefiPositionVault.sol";
import {LendefiPoRFeed} from "../../contracts/markets/LendefiPoRFeed.sol";
import {LendefiMarketFactory} from "../../contracts/markets/LendefiMarketFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MarketFactoryTest is BasicDeploy {
    TokenMock public baseAsset1;
    TokenMock public baseAsset2;

    function setUp() public {
        // Deploy basic infrastructure first
        deployMarketsWithUSDC();

        // Create additional test assets
        baseAsset1 = new TokenMock("Test Token 1", "TEST1");
        baseAsset2 = new TokenMock("Test Token 2", "TEST2");

        // Add test assets to allowlist (gnosisSafe has MANAGER_ROLE)
        vm.startPrank(gnosisSafe);
        marketFactoryInstance.addAllowedBaseAsset(address(baseAsset1));
        marketFactoryInstance.addAllowedBaseAsset(address(baseAsset2));
        vm.stopPrank();

        // Setup TGE for proper functionality
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
    }

    function testCreateMarket() public {
        // Create market with first test asset (charlie has MARKET_OWNER_ROLE from BasicDeploy)
        vm.prank(charlie);
        marketFactoryInstance.createMarket(address(baseAsset1), "Test Market 1", "TM1");

        // Verify market creation
        IPROTOCOL.Market memory createdMarket = marketFactoryInstance.getMarketInfo(charlie, address(baseAsset1));
        assertEq(createdMarket.baseAsset, address(baseAsset1));
        assertEq(createdMarket.name, "Test Market 1");
        assertEq(createdMarket.symbol, "TM1");
        assertTrue(createdMarket.active);
        assertEq(createdMarket.decimals, 18);
        assertTrue(createdMarket.createdAt > 0);
        assertTrue(createdMarket.core != address(0));
        assertTrue(createdMarket.baseVault != address(0));

        // Check market exists in arrays
        IPROTOCOL.Market[] memory activeMarkets = marketFactoryInstance.getAllActiveMarkets();
        assertGe(activeMarkets.length, 1);

        // Should contain our new market
        bool found = false;
        for (uint256 i = 0; i < activeMarkets.length; i++) {
            if (activeMarkets[i].baseAsset == address(baseAsset1)) {
                found = true;
                break;
            }
        }
        assertTrue(found);
    }

    function testCannotCreateMarketWithZeroAddress() public {
        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSignature("BaseAssetNotAllowed()"));
        marketFactoryInstance.createMarket(address(0), "Test Market", "TMKT");
    }

    function testCannotCreateDuplicateMarket() public {
        // Create first market
        vm.prank(charlie);
        marketFactoryInstance.createMarket(address(baseAsset1), "Test Market", "TMKT");

        // Try to create duplicate
        vm.expectRevert(abi.encodeWithSignature("MarketAlreadyExists()"));
        vm.prank(charlie);
        marketFactoryInstance.createMarket(address(baseAsset1), "Test Market", "TMKT");
    }

    function testCannotCreateMarketNonAdmin() public {
        // Try to create market as non-admin
        vm.expectRevert();
        marketFactoryInstance.createMarket(address(baseAsset1), "Test Market", "TMKT");
    }

    function testGetAllActiveMarkets() public {
        uint256 initialMarkets = marketFactoryInstance.getAllActiveMarkets().length;

        // Create first market
        vm.prank(charlie);
        marketFactoryInstance.createMarket(address(baseAsset1), "Test Market 1", "TM1");

        // Create second market
        vm.prank(charlie);
        marketFactoryInstance.createMarket(address(baseAsset2), "Test Market 2", "TM2");

        // Get all active markets
        IPROTOCOL.Market[] memory activeMarkets = marketFactoryInstance.getAllActiveMarkets();
        assertEq(activeMarkets.length, initialMarkets + 2);

        // Check that our markets are included
        bool found1 = false;
        bool found2 = false;
        for (uint256 i = 0; i < activeMarkets.length; i++) {
            if (activeMarkets[i].baseAsset == address(baseAsset1)) found1 = true;
            if (activeMarkets[i].baseAsset == address(baseAsset2)) found2 = true;
        }
        assertTrue(found1);
        assertTrue(found2);
    }

    // ============ ZeroAddress Error Tests ============

    function test_Revert_Initialize_ZeroTimelock() public {
        LendefiMarketFactory factoryImpl = new LendefiMarketFactory();

        // Try to deploy proxy with zero timelock in init data
        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            address(0), // zero timelock
            address(tokenInstance),
            address(gnosisSafe),
            address(ecoInstance)
        );

        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(factoryImpl), initData);
    }

    function test_Revert_Initialize_ZeroGovToken() public {
        LendefiMarketFactory factoryImpl = new LendefiMarketFactory();

        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            address(timelockInstance),
            address(0),
            address(gnosisSafe),
            address(ecoInstance)
        );

        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(factoryImpl), initData);
    }

    function test_Revert_Initialize_ZeroEcosystem() public {
        LendefiMarketFactory factoryImpl = new LendefiMarketFactory();

        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            address(timelockInstance),
            address(tokenInstance),
            address(gnosisSafe),
            address(0)
        );

        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(factoryImpl), initData);
    }

    function test_Revert_Initialize_ZeroMultisig() public {
        LendefiMarketFactory factoryImpl = new LendefiMarketFactory();

        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            address(timelockInstance),
            address(tokenInstance),
            address(0),
            address(ecoInstance)
        );

        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(factoryImpl), initData);
    }
}
