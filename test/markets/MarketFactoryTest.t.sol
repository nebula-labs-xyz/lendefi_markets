// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";

contract MarketFactoryTest is BasicDeploy {
    TokenMock public baseAsset1;
    TokenMock public baseAsset2;

    function setUp() public {
        // Deploy basic infrastructure first
        deployMarketsWithUSDC();
        
        // Create additional test assets
        baseAsset1 = new TokenMock("Test Token 1", "TEST1");
        baseAsset2 = new TokenMock("Test Token 2", "TEST2");
        
        // Setup TGE for proper functionality
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
    }

    function testCreateMarket() public {
        // Create market with first test asset
        vm.prank(address(timelockInstance));
        marketFactoryInstance.createMarket(address(baseAsset1), "Test Market 1", "TM1");

        // Verify market creation
        LendefiCore.Market memory createdMarket = marketFactoryInstance.getMarketInfo(address(baseAsset1));
        assertEq(createdMarket.baseAsset, address(baseAsset1));
        assertEq(createdMarket.name, "Test Market 1");
        assertEq(createdMarket.symbol, "TM1");
        assertTrue(createdMarket.active);
        assertEq(createdMarket.decimals, 18);
        assertTrue(createdMarket.createdAt > 0);
        assertTrue(createdMarket.core != address(0));
        assertTrue(createdMarket.baseVault != address(0));

        // Check market exists in arrays
        address[] memory activeMarkets = marketFactoryInstance.getAllActiveMarkets();
        assertGe(activeMarkets.length, 1);
        
        // Should contain our new market
        bool found = false;
        for (uint i = 0; i < activeMarkets.length; i++) {
            if (activeMarkets[i] == address(baseAsset1)) {
                found = true;
                break;
            }
        }
        assertTrue(found);
    }

    function testCannotCreateMarketWithZeroAddress() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        marketFactoryInstance.createMarket(address(0), "Test Market", "TMKT");
    }

    function testCannotCreateDuplicateMarket() public {
        // Create first market
        vm.prank(address(timelockInstance));
        marketFactoryInstance.createMarket(address(baseAsset1), "Test Market", "TMKT");

        // Try to create duplicate
        vm.expectRevert(abi.encodeWithSignature("MarketAlreadyExists()"));
        vm.prank(address(timelockInstance));
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
        vm.prank(address(timelockInstance));
        marketFactoryInstance.createMarket(address(baseAsset1), "Test Market 1", "TM1");

        // Create second market
        vm.prank(address(timelockInstance));
        marketFactoryInstance.createMarket(address(baseAsset2), "Test Market 2", "TM2");

        // Get all active markets
        address[] memory activeMarkets = marketFactoryInstance.getAllActiveMarkets();
        assertEq(activeMarkets.length, initialMarkets + 2);
        
        // Check that our markets are included
        bool found1 = false;
        bool found2 = false;
        for (uint i = 0; i < activeMarkets.length; i++) {
            if (activeMarkets[i] == address(baseAsset1)) found1 = true;
            if (activeMarkets[i] == address(baseAsset2)) found2 = true;
        }
        assertTrue(found1);
        assertTrue(found2);
    }
}
