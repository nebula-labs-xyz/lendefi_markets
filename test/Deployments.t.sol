// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./BasicDeploy.sol"; // solhint-disable-line
import {LendefiCore} from "../contracts/markets/LendefiCore.sol";
import {LendefiMarketVaultV2} from "../contracts/upgrades/LendefiMarketVaultV2.sol";

contract BasicDeployTest is BasicDeploy {
    function test_001_TokenDeploy() public {
        deployTokenUpgrade();
    }

    function test_002_EcosystemDeploy() public {
        deployEcosystemUpgrade();
    }

    function test_003_TreasuryDeploy() public {
        deployTreasuryUpgrade();
    }

    function test_004_TimelockDeploy() public {
        deployTimelockUpgrade();
    }

    function test_005_GovernorDeploy() public {
        deployGovernorUpgrade();
    }

    function test_006_CompleteDAODeploy() public {
        deployComplete();
        console2.log("token:    ", address(tokenInstance));
        console2.log("ecosystem:", address(ecoInstance));
        console2.log("treasury: ", address(treasuryInstance));
        console2.log("governor: ", address(govInstance));
        console2.log("timelock: ", address(timelockInstance));
    }

    function test_007_InvestmentManagerDeploy() public {
        deployComplete();
        _deployInvestmentManager();

        assertFalse(
            address(managerInstance) == Upgrades.getImplementationAddress(address(managerInstance)),
            "Implementation should be different from proxy"
        );
    }

    function test_008_DeployIMUpgrade() public {
        deployIMUpgrade();
    }

    function test_009_TGE() public {
        deployComplete();
        assertEq(tokenInstance.totalSupply(), 0);
        // this is the TGE
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        uint256 ecoBal = tokenInstance.balanceOf(address(ecoInstance));
        uint256 treasuryBal = tokenInstance.balanceOf(address(treasuryInstance));
        uint256 guardianBal = tokenInstance.balanceOf(guardian);

        assertEq(ecoBal, 22_000_000 ether);
        assertEq(treasuryBal, 27_400_000 ether);
        assertEq(guardianBal, 600_000 ether);
        assertEq(tokenInstance.totalSupply(), ecoBal + treasuryBal + guardianBal);
    }

    function test_010_deployTeamManager() public {
        deployComplete();
        _deployTeamManager();
    }

    function test_011_deployTeamManagerUpgrade() public {
        deployTeamManagerUpgrade();
    }

    function test_012_deployMarketsWithUSDC() public {
        deployMarketsWithUSDC();

        // Verify all components are deployed
        assertTrue(address(tokenInstance) != address(0), "Token should be deployed");
        assertTrue(address(ecoInstance) != address(0), "Ecosystem should be deployed");
        assertTrue(address(treasuryInstance) != address(0), "Treasury should be deployed");
        assertTrue(address(marketFactoryInstance) != address(0), "Market Factory should be deployed");
        assertTrue(address(timelockInstance) != address(0), "Timelock should be deployed");
        assertTrue(address(assetsInstance) != address(0), "Assets should be deployed");
        assertTrue(address(usdcInstance) != address(0), "USDC mock should be deployed");
        assertTrue(address(marketCoreInstance) != address(0), "Market Core should be deployed");
        assertTrue(address(marketVaultInstance) != address(0), "Market Vault should be deployed");

        // Log addresses for reference
        console2.log("===== Complete Markets System Deployment =====");
        console2.log("GovToken:     ", address(tokenInstance));
        console2.log("Ecosystem:    ", address(ecoInstance));
        console2.log("Treasury:     ", address(treasuryInstance));
        console2.log("MarketFactory:", address(marketFactoryInstance));
        console2.log("Timelock:     ", address(timelockInstance));
        console2.log("Assets:       ", address(assetsInstance));
        console2.log("USDC:         ", address(usdcInstance));
        console2.log("MarketCore:   ", address(marketCoreInstance));
        console2.log("MarketVault:  ", address(marketVaultInstance));
    }

    function test_013_deployAssetsModuleUpgrade() public {
        deployAssetsModuleUpgrade();

        // Check version after upgrade
        assertEq(assetsInstance.version(), 2, "Version should be 2 after upgrade");
    }

    // ============ Markets Layer Tests ============

    function test_014_deployMarketFactory() public {
        deployMarketsWithUSDC();
        _deployMarketFactory();

        // Verify market factory deployment
        assertTrue(address(marketFactoryInstance) != address(0), "Market factory should be deployed");
        assertTrue(
            marketFactoryInstance.assetsModuleImplementation() != address(0),
            "Assets module implementation should be set"
        );
        assertEq(marketFactoryInstance.govToken(), address(tokenInstance), "Gov token should be set");
        assertEq(marketFactoryInstance.timelock(), address(timelockInstance), "Timelock should be set");

        // Check implementations are set
        assertTrue(marketFactoryInstance.coreImplementation() != address(0), "Core implementation should be set");
        assertTrue(marketFactoryInstance.vaultImplementation() != address(0), "Vault implementation should be set");

        console2.log("Market Factory: ", address(marketFactoryInstance));
        console2.log("Core Impl:      ", marketFactoryInstance.coreImplementation());
        console2.log("Vault Impl:     ", marketFactoryInstance.vaultImplementation());
    }

    function test_015_deployMarket() public {
        deployMarketsWithUSDC();
        _deployMarketFactory();

        // Deploy a USDC market
        _deployMarket(address(usdcInstance), "Lendefi USDC Market", "lfUSDC");

        // Verify market deployment
        assertTrue(address(marketCoreInstance) != address(0), "Market core should be deployed");
        assertTrue(address(marketVaultInstance) != address(0), "Market vault should be deployed");

        // Check market info - charlie is the market owner (from BasicDeploy._deployMarket)
        IPROTOCOL.Market memory marketInfo = marketFactoryInstance.getMarketInfo(charlie, address(usdcInstance));
        assertEq(marketInfo.baseAsset, address(usdcInstance), "Base asset should be USDC");
        assertEq(marketInfo.core, address(marketCoreInstance), "Core should match");
        assertEq(marketInfo.baseVault, address(marketVaultInstance), "Vault should match");
        assertEq(marketInfo.name, "Lendefi USDC Market", "Name should match");
        assertEq(marketInfo.symbol, "lfUSDC", "Symbol should match");
        assertTrue(marketInfo.active, "Market should be active");

        console2.log("Market Core:    ", address(marketCoreInstance));
        console2.log("Market Vault:   ", address(marketVaultInstance));
    }

    function test_016_deployMarketsWithUSDC() public {
        deployMarketsWithUSDC();

        // Verify complete markets deployment
        assertTrue(address(tokenInstance) != address(0), "Token should be deployed");
        assertTrue(address(ecoInstance) != address(0), "Ecosystem should be deployed");
        assertTrue(address(treasuryInstance) != address(0), "Treasury should be deployed");
        assertTrue(address(assetsInstance) != address(0), "Assets should be deployed");
        assertTrue(address(marketFactoryInstance) != address(0), "Market factory should be deployed");
        assertTrue(address(marketCoreInstance) != address(0), "Market core should be deployed");
        assertTrue(address(marketVaultInstance) != address(0), "Market vault should be deployed");

        // Check market is active - charlie is the market owner
        assertTrue(marketFactoryInstance.isMarketActive(charlie, address(usdcInstance)), "USDC market should be active");

        // Check core contract initialization
        assertEq(address(marketCoreInstance.baseAsset()), address(usdcInstance), "Core base asset should be USDC");

        // Check vault contract initialization
        assertEq(marketVaultInstance.asset(), address(usdcInstance), "Vault asset should be USDC");
        assertEq(marketVaultInstance.name(), "Lendefi Yield Token", "Vault name should match");
        assertEq(marketVaultInstance.symbol(), "LYTUSDC", "Vault symbol should match");
        assertEq(marketVaultInstance.version(), 1, "Vault version should be 1");

        console2.log("===== Complete Markets Deployment =====");
        console2.log("Market Factory: ", address(marketFactoryInstance));
        console2.log("Market Core:    ", address(marketCoreInstance));
        console2.log("Market Vault:   ", address(marketVaultInstance));
        console2.log("USDC:           ", address(usdcInstance));
    }

    function test_017_deployMarketFactoryUpgrade() public {
        deployMarketsWithUSDC();
        deployMarketFactoryUpgrade();
    }

    function test_018_deployLendefiCoreUpgrade() public {
        deployLendefiCoreUpgrade();
    }

    function test_019_deployMarketVaultUpgrade() public {
        // Deploy the market vault upgrade
        deployMarketVaultUpgrade();

        // Additional verification that the upgrade was successful
        assertEq(marketVaultInstance.version(), 2, "Market vault version should be 2 after upgrade");

        // Verify basic functionality still works after upgrade
        assertTrue(address(marketVaultInstance) != address(0), "Market vault should be deployed");
        assertEq(marketVaultInstance.asset(), address(usdcInstance), "Asset should still be USDC");

        // Log successful upgrade
        console2.log("Market Vault upgraded to V2 successfully");
        console2.log("New version: ", marketVaultInstance.version());
    }
}
