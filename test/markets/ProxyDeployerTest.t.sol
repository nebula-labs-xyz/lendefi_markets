// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../BasicDeploy.sol";
import {ProxyDeployer} from "../../contracts/markets/helper/ProxyDeployer.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";

contract ProxyDeployerTest is BasicDeploy {
    ProxyDeployer public proxyDeployer;
    TokenMock public testToken;

    function setUp() public {
        // Deploy base contracts
        deployComplete();
        _deployAssetsModule();

        // Deploy proxy deployer
        proxyDeployer = new ProxyDeployer();

        // Deploy test token
        testToken = new TokenMock("Test Token", "TEST");

        // Setup TGE
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
    }

    function test_deployMarketVaultProxy() public {
        // Call the function
        address vaultProxy = proxyDeployer.deployMarketVaultProxy(
            address(testToken),
            address(timelockInstance),
            address(tokenInstance),
            address(ecoInstance),
            address(assetsInstance),
            "Test Vault",
            "TV"
        );

        // Validate it returns a valid address
        assertTrue(vaultProxy != address(0), "Should return valid address");

        // Verify it's a contract
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(vaultProxy)
        }
        assertTrue(codeSize > 0, "Should deploy a contract");
    }
}
