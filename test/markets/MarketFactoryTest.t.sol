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

        // Setup TGE for proper functionality
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
    }

    function testCreateMarket() public {
        // Create market with first test asset
        vm.prank(address(timelockInstance));
        marketFactoryInstance.createMarket(address(baseAsset1), "Test Market 1", "TM1");

        // Verify market creation
        IPROTOCOL.Market memory createdMarket = marketFactoryInstance.getMarketInfo(address(baseAsset1));
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
        for (uint256 i = 0; i < activeMarkets.length; i++) {
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
        for (uint256 i = 0; i < activeMarkets.length; i++) {
            if (activeMarkets[i] == address(baseAsset1)) found1 = true;
            if (activeMarkets[i] == address(baseAsset2)) found2 = true;
        }
        assertTrue(found1);
        assertTrue(found2);
    }

    // ============ ZeroAddress Error Tests ============

    function test_Revert_Initialize_ZeroTimelock() public {
        LendefiPoRFeed porFeedImpl = new LendefiPoRFeed();
        LendefiMarketFactory factoryImpl = new LendefiMarketFactory();
        
        // Try to deploy proxy with zero timelock in init data
        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            address(0), // zero timelock
            address(treasuryInstance),
            address(assetsInstance),
            address(tokenInstance),
            address(porFeedImpl),
            address(ecoInstance)
        );
        
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(factoryImpl), initData);
    }

    function test_Revert_Initialize_ZeroTreasury() public {
        LendefiPoRFeed porFeedImpl = new LendefiPoRFeed();
        LendefiMarketFactory factoryImpl = new LendefiMarketFactory();
        
        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            address(timelockInstance),
            address(0), // zero treasury
            address(assetsInstance),
            address(tokenInstance),
            address(porFeedImpl),
            address(ecoInstance)
        );
        
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(factoryImpl), initData);
    }

    function test_Revert_Initialize_ZeroAssetsModule() public {
        LendefiPoRFeed porFeedImpl = new LendefiPoRFeed();
        LendefiMarketFactory factoryImpl = new LendefiMarketFactory();
        
        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            address(timelockInstance),
            address(treasuryInstance),
            address(0), // zero assets module
            address(tokenInstance),
            address(porFeedImpl),
            address(ecoInstance)
        );
        
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(factoryImpl), initData);
    }

    function test_Revert_Initialize_ZeroGovToken() public {
        LendefiPoRFeed porFeedImpl = new LendefiPoRFeed();
        LendefiMarketFactory factoryImpl = new LendefiMarketFactory();
        
        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            address(timelockInstance),
            address(treasuryInstance),
            address(assetsInstance),
            address(0), // zero gov token
            address(porFeedImpl),
            address(ecoInstance)
        );
        
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(factoryImpl), initData);
    }

    function test_Revert_Initialize_ZeroPoRFeed() public {
        LendefiMarketFactory factoryImpl = new LendefiMarketFactory();
        
        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            address(timelockInstance),
            address(treasuryInstance),
            address(assetsInstance),
            address(tokenInstance),
            address(0), // zero PoR feed
            address(ecoInstance)
        );
        
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(factoryImpl), initData);
    }

    function test_Revert_Initialize_ZeroEcosystem() public {
        LendefiPoRFeed porFeedImpl = new LendefiPoRFeed();
        LendefiMarketFactory factoryImpl = new LendefiMarketFactory();
        
        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            address(timelockInstance),
            address(treasuryInstance),
            address(assetsInstance),
            address(tokenInstance),
            address(porFeedImpl),
            address(0) // zero ecosystem
        );
        
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(factoryImpl), initData);
    }
}
