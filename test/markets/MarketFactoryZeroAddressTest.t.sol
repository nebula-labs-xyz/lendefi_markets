// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {LendefiMarketFactory} from "../../contracts/markets/LendefiMarketFactory.sol";
import {LendefiPoRFeed} from "../../contracts/markets/LendefiPoRFeed.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title MarketFactoryZeroAddressTest
 * @notice Tests to ensure ZeroAddress() error is triggered in MarketFactory initialization
 * @dev Standalone test file to avoid FFI issues from BasicDeploy
 */
contract MarketFactoryZeroAddressTest is Test {
    // Mock addresses for valid parameters
    address constant VALID_ADDRESS = address(0x1234567890123456789012345678901234567890);
    address constant TIMELOCK = address(0x1111111111111111111111111111111111111111);
    address constant TREASURY = address(0x2222222222222222222222222222222222222222);
    address constant ASSETS = address(0x3333333333333333333333333333333333333333);
    address constant GOV_TOKEN = address(0x4444444444444444444444444444444444444444);
    address constant ECOSYSTEM = address(0x5555555555555555555555555555555555555555);
    
    function test_Revert_Initialize_ZeroTimelock() public {
        LendefiPoRFeed porFeedImpl = new LendefiPoRFeed();
        LendefiMarketFactory factoryImpl = new LendefiMarketFactory();
        
        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            address(0), // zero timelock
            TREASURY,
            ASSETS,
            GOV_TOKEN,
            address(porFeedImpl),
            ECOSYSTEM
        );
        
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(factoryImpl), initData);
    }

    function test_Revert_Initialize_ZeroTreasury() public {
        LendefiPoRFeed porFeedImpl = new LendefiPoRFeed();
        LendefiMarketFactory factoryImpl = new LendefiMarketFactory();
        
        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            TIMELOCK,
            address(0), // zero treasury
            ASSETS,
            GOV_TOKEN,
            address(porFeedImpl),
            ECOSYSTEM
        );
        
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(factoryImpl), initData);
    }

    function test_Revert_Initialize_ZeroAssetsModule() public {
        LendefiPoRFeed porFeedImpl = new LendefiPoRFeed();
        LendefiMarketFactory factoryImpl = new LendefiMarketFactory();
        
        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            TIMELOCK,
            TREASURY,
            address(0), // zero assets module
            GOV_TOKEN,
            address(porFeedImpl),
            ECOSYSTEM
        );
        
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(factoryImpl), initData);
    }

    function test_Revert_Initialize_ZeroGovToken() public {
        LendefiPoRFeed porFeedImpl = new LendefiPoRFeed();
        LendefiMarketFactory factoryImpl = new LendefiMarketFactory();
        
        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            TIMELOCK,
            TREASURY,
            ASSETS,
            address(0), // zero gov token
            address(porFeedImpl),
            ECOSYSTEM
        );
        
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(factoryImpl), initData);
    }

    function test_Revert_Initialize_ZeroPoRFeed() public {
        LendefiMarketFactory factoryImpl = new LendefiMarketFactory();
        
        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            TIMELOCK,
            TREASURY,
            ASSETS,
            GOV_TOKEN,
            address(0), // zero PoR feed
            ECOSYSTEM
        );
        
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(factoryImpl), initData);
    }

    function test_Revert_Initialize_ZeroEcosystem() public {
        LendefiPoRFeed porFeedImpl = new LendefiPoRFeed();
        LendefiMarketFactory factoryImpl = new LendefiMarketFactory();
        
        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            TIMELOCK,
            TREASURY,
            ASSETS,
            GOV_TOKEN,
            address(porFeedImpl),
            address(0) // zero ecosystem
        );
        
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(factoryImpl), initData);
    }

    function test_Successful_Initialize_AllValidAddresses() public {
        LendefiPoRFeed porFeedImpl = new LendefiPoRFeed();
        LendefiMarketFactory factoryImpl = new LendefiMarketFactory();
        
        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            TIMELOCK,
            TREASURY,
            ASSETS,
            GOV_TOKEN,
            address(porFeedImpl),
            ECOSYSTEM
        );
        
        // This should succeed
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        LendefiMarketFactory factory = LendefiMarketFactory(address(proxy));
        
        // Verify initialization
        assertEq(factory.timelock(), TIMELOCK);
        assertEq(factory.treasury(), TREASURY);
        assertEq(factory.assetsModule(), ASSETS);
        assertEq(factory.govToken(), GOV_TOKEN);
        assertEq(factory.porFeed(), address(porFeedImpl));
        assertEq(factory.ecosystem(), ECOSYSTEM);
    }
}