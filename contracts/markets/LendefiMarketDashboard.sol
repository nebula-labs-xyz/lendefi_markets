// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

/**
 * ═══════════[ Composable Lending Markets ]═══════════
 *
 * ██╗     ███████╗███╗   ██╗██████╗ ███████╗███████╗██╗
 * ██║     ██╔════╝████╗  ██║██╔══██╗██╔════╝██╔════╝██║
 * ██║     █████╗  ██╔██╗ ██║██║  ██║█████╗  █████╗  ██║
 * ██║     ██╔══╝  ██║╚██╗██║██║  ██║██╔══╝  ██╔══╝  ██║
 * ███████╗███████╗██║ ╚████║██████╔╝███████╗██║     ██║
 * ╚══════╝╚══════╝╚═╝  ╚═══╝╚═════╝ ╚══════╝╚═╝     ╚═╝
 *
 * ═══════════[ Composable Lending Markets ]═══════════
 * @title Lendefi Market Dashboard
 * @author alexei@nebula-labs(dot)xyz
 * @notice Comprehensive dashboard view for all Lendefi markets providing aggregated data for UIs
 * @dev Provides read-only functions to aggregate market data across all markets for dashboard visualization
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */
import {IPROTOCOL} from "../interfaces/IProtocol.sol";
import {IASSETS} from "../interfaces/IASSETS.sol";
import {ILendefiMarketFactory} from "../interfaces/ILendefiMarketFactory.sol";
import {ILendefiMarketVault} from "../interfaces/ILendefiMarketVault.sol";
import {IECOSYSTEM} from "../interfaces/IEcosystem.sol";
import {ILendefiMarketDashboard} from "../interfaces/ILendefiMarketDashboard.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract LendefiMarketDashboard is ILendefiMarketDashboard {
    // ========== STATE VARIABLES ==========

    /// @notice Market factory contract reference
    ILendefiMarketFactory private immutable _marketFactory;

    /// @notice Ecosystem contract reference for rewards calculation
    IECOSYSTEM private immutable _ecosystem;

    // Note: Struct definitions are inherited from ILendefiMarketDashboard interface

    // ========== CONSTRUCTOR ==========

    /**
     * @notice Initializes the dashboard with required contract references
     * @param marketFactoryAddr Address of the market factory contract
     * @param ecosystemAddr Address of the ecosystem contract
     */
    constructor(address marketFactoryAddr, address ecosystemAddr) {
        require(marketFactoryAddr != address(0) && ecosystemAddr != address(0), "ZERO_ADDRESS");

        _marketFactory = ILendefiMarketFactory(marketFactoryAddr);
        _ecosystem = IECOSYSTEM(ecosystemAddr);
    }

    // ========== MAIN DASHBOARD FUNCTIONS ==========

    /**
     * @notice Gets comprehensive overview of all active markets
     * @dev Primary function for market dashboard display
     * @return Array of MarketOverview structs for all active markets
     */
    function getAllMarketOverviews() external view returns (MarketOverview[] memory) {
        IPROTOCOL.Market[] memory markets = _marketFactory.getAllActiveMarkets();
        uint256 marketCount = markets.length;

        MarketOverview[] memory overviews = new MarketOverview[](marketCount);

        for (uint256 i = 0; i < marketCount; i++) {
            overviews[i] = _getMarketOverview(markets[i]);
        }

        return overviews;
    }

    /**
     * @notice Gets overview for a specific market
     * @param marketOwner Address of the market owner
     * @param baseAsset Address of the base asset
     * @return MarketOverview struct for the specified market
     */
    function getMarketOverview(address marketOwner, address baseAsset) external view returns (MarketOverview memory) {
        IPROTOCOL.Market memory market = _marketFactory.getMarketInfo(marketOwner, baseAsset);
        return _getMarketOverview(market);
    }

    /**
     * @notice Gets aggregated statistics across the entire protocol
     * @return ProtocolStats struct containing protocol-wide metrics
     */
    function getProtocolStats() external view returns (ProtocolStats memory) {
        IPROTOCOL.Market[] memory allMarkets = _marketFactory.getAllActiveMarkets();

        uint256 totalTVL = 0;
        uint256 totalDebt = 0;
        uint256 totalCollateral = 0;
        uint256 totalUtilization = 0;
        uint256 activeMarkets = 0;

        // Aggregate metrics across all markets
        for (uint256 i = 0; i < allMarkets.length; i++) {
            if (allMarkets[i].active) {
                activeMarkets++;

                ILendefiMarketVault vault = ILendefiMarketVault(allMarkets[i].baseVault);

                // Add TVL (total assets in vault)
                totalTVL += vault.totalAssets();

                // Add total borrowed
                totalDebt += vault.totalBorrow();

                // Add utilization (weighted by TVL)
                uint256 marketTVL = vault.totalAssets();
                if (marketTVL > 0) {
                    totalUtilization += (vault.utilization() * marketTVL);
                }

                // TODO: Add collateral value calculation when available
                // This would require iterating through all positions in the market
            }
        }

        // Calculate weighted average utilization
        uint256 averageUtilization = totalTVL > 0 ? totalUtilization / totalTVL : 0;

        return ProtocolStats({
            totalMarkets: allMarkets.length,
            totalMarketOwners: _marketFactory.getMarketOwnersCount(),
            supportedBaseAssets: _marketFactory.getAllowedBaseAssets(),
            totalProtocolTVL: totalTVL,
            totalProtocolDebt: totalDebt,
            totalCollateralUSD: totalCollateral, // TODO: Implement collateral calculation
            averageUtilization: averageUtilization,
            governanceToken: _marketFactory.govToken(),
            totalRewardsDistributed: 0, // TODO: Get from ecosystem
            currentRewardRate: 0, // TODO: Get current reward rate
            protocolHealthScore: _calculateProtocolHealth(totalTVL, totalDebt),
            totalLiquidations: 0 // TODO: Track liquidations
        });
    }

    /**
     * @notice Gets user-specific data across all markets
     * @param user Address of the user
     * @return Array of UserMarketData for markets where user has activity
     */
    function getUserMarketData(address user) external view returns (UserMarketData[] memory) {
        IPROTOCOL.Market[] memory allMarkets = _marketFactory.getAllActiveMarkets();

        // First pass: count markets where user has activity
        uint256 activeMarketsCount = 0;
        for (uint256 i = 0; i < allMarkets.length; i++) {
            if (_userHasActivity(user, allMarkets[i])) {
                activeMarketsCount++;
            }
        }

        // Second pass: populate user data for active markets
        UserMarketData[] memory userData = new UserMarketData[](activeMarketsCount);
        uint256 index = 0;

        for (uint256 i = 0; i < allMarkets.length; i++) {
            if (_userHasActivity(user, allMarkets[i])) {
                userData[index] = _getUserMarketData(user, allMarkets[i]);
                index++;
            }
        }

        return userData;
    }

    /**
     * @notice Gets detailed metrics for all supported assets
     * @return Array of AssetMetrics for all assets in the allowlist
     */
    function getAssetMetrics() external view returns (AssetMetrics[] memory) {
        address[] memory allowedAssets = _marketFactory.getAllowedBaseAssets();
        AssetMetrics[] memory metrics = new AssetMetrics[](allowedAssets.length);

        for (uint256 i = 0; i < allowedAssets.length; i++) {
            metrics[i] = _getAssetMetrics(allowedAssets[i]);
        }

        return metrics;
    }

    // ========== INTERFACE GETTERS ==========

    /**
     * @notice Returns the market factory contract address
     * @return Address of the market factory
     */
    function marketFactory() external view returns (address) {
        return address(_marketFactory);
    }

    /**
     * @notice Returns the ecosystem contract address
     * @return Address of the ecosystem contract
     */
    function ecosystem() external view returns (address) {
        return address(_ecosystem);
    }

    // ========== INTERNAL HELPER FUNCTIONS ==========

    /**
     * @dev Internal function to create MarketOverview for a given market
     */
    function _getMarketOverview(IPROTOCOL.Market memory market) internal view returns (MarketOverview memory) {
        ILendefiMarketVault vault = ILendefiMarketVault(market.baseVault);
        IPROTOCOL core = IPROTOCOL(market.core);
        IERC20Metadata baseToken = IERC20Metadata(market.baseAsset);

        // Get financial metrics
        uint256 totalAssets = vault.totalAssets();
        uint256 totalShares = vault.totalSupply();
        uint256 sharePrice = totalShares > 0 ? (totalAssets * 1e18) / totalShares : 1e18;

        return MarketOverview({
            // Market Identity
            marketOwner: _findMarketOwner(market),
            baseAsset: market.baseAsset,
            baseAssetSymbol: baseToken.symbol(),
            baseAssetDecimals: baseToken.decimals(),
            marketName: market.name,
            marketSymbol: market.symbol,
            createdAt: market.createdAt,
            active: market.active,
            // Market Contracts
            coreContract: market.core,
            vaultContract: market.baseVault,
            assetsModule: market.assetsModule,
            porFeed: market.porFeed,
            // Financial Metrics
            totalSuppliedLiquidity: vault.totalSuppliedLiquidity(),
            totalBorrowed: vault.totalBorrow(),
            totalCollateralValueUSD: 0, // TODO: Calculate from all positions
            utilization: vault.utilization(),
            supplyRate: core.getSupplyRate(),
            borrowRate: core.getBorrowRate(IASSETS.CollateralTier.CROSS_A),
            // Vault Metrics
            totalShares: totalShares,
            totalAssets: totalAssets,
            sharePrice: sharePrice,
            // Protocol Health
            averageHealthFactor: 0, // TODO: Calculate from all positions
            totalPositions: 0, // TODO: Get from core
            liquidationThreshold: 850 // TODO: Get from assets module
        });
    }

    /**
     * @dev Finds the market owner for a given market
     */
    function _findMarketOwner(IPROTOCOL.Market memory market) internal view returns (address) {
        uint256 ownerCount = _marketFactory.getMarketOwnersCount();

        for (uint256 i = 0; i < ownerCount; i++) {
            address owner = _marketFactory.getMarketOwnerByIndex(i);
            if (_marketFactory.isMarketActive(owner, market.baseAsset)) {
                IPROTOCOL.Market memory ownerMarket = _marketFactory.getMarketInfo(owner, market.baseAsset);
                if (ownerMarket.core == market.core) {
                    return owner;
                }
            }
        }
        return address(0);
    }

    /**
     * @dev Checks if user has any activity in the given market
     */
    function _userHasActivity(address user, IPROTOCOL.Market memory market) internal view returns (bool) {
        ILendefiMarketVault vault = ILendefiMarketVault(market.baseVault);

        // Check if user has LP tokens
        if (vault.balanceOf(user) > 0) {
            return true;
        }

        // TODO: Check if user has positions in this market
        // This would require calling the core contract to check positions

        return false;
    }

    /**
     * @dev Gets user-specific data for a given market
     */
    function _getUserMarketData(address user, IPROTOCOL.Market memory market)
        internal
        view
        returns (UserMarketData memory)
    {
        ILendefiMarketVault vault = ILendefiMarketVault(market.baseVault);
        IERC20Metadata baseToken = IERC20Metadata(market.baseAsset);

        uint256 lpBalance = vault.balanceOf(user);
        uint256 lpValue = lpBalance > 0 ? vault.previewRedeem(lpBalance) : 0;

        return UserMarketData({
            marketOwner: _findMarketOwner(market),
            baseAsset: market.baseAsset,
            baseAssetSymbol: baseToken.symbol(),
            marketName: market.name,
            lpTokenBalance: lpBalance,
            lpTokenValue: lpValue,
            isRewardEligible: vault.isRewardable(user),
            pendingRewards: 0, // TODO: Calculate pending rewards
            positionIds: new uint256[](0), // TODO: Get user's position IDs
            totalDebt: 0, // TODO: Calculate from positions
            totalCollateral: 0, // TODO: Calculate from positions
            averageHealthFactor: 0, // TODO: Calculate from positions
            availableCredit: 0, // TODO: Calculate available credit
            lastInteractionBlock: 0, // TODO: Get from core
            hasActivePositions: false // TODO: Check for active positions
        });
    }

    /**
     * @dev Gets detailed metrics for a specific asset
     */
    function _getAssetMetrics(address assetAddress) internal view returns (AssetMetrics memory) {
        IERC20Metadata token = IERC20Metadata(assetAddress);

        return AssetMetrics({
            assetAddress: assetAddress,
            symbol: token.symbol(),
            decimals: token.decimals(),
            active: true, // TODO: Get from assets module
            borrowThreshold: 800, // TODO: Get from assets module
            liquidationThreshold: 850, // TODO: Get from assets module
            maxSupplyThreshold: 1000000 * 10 ** token.decimals(), // TODO: Get from assets module
            tier: IASSETS.CollateralTier.CROSS_A, // TODO: Get from assets module
            primaryOracleType: IASSETS.OracleType.CHAINLINK, // TODO: Get from assets module
            hasChainlinkOracle: true, // TODO: Check assets module
            hasUniswapV3Oracle: true, // TODO: Check assets module
            currentPriceUSD: 1e18, // TODO: Get current price from oracle
            totalSupplied: 0, // TODO: Calculate across all markets
            totalBorrowed: 0, // TODO: Calculate across all markets
            utilizationRate: 0 // TODO: Calculate utilization
        });
    }

    /**
     * @dev Calculates overall protocol health score (0-1000)
     */
    function _calculateProtocolHealth(uint256 totalTVL, uint256 totalDebt) internal pure returns (uint256) {
        if (totalTVL == 0) return 1000; // Perfect health if no TVL

        uint256 utilizationRate = (totalDebt * 1000) / totalTVL;

        // Health decreases as utilization increases
        // 0% utilization = 1000 health
        // 50% utilization = 500 health
        // 100% utilization = 0 health
        return utilizationRate > 1000 ? 0 : 1000 - utilizationRate;
    }
}
