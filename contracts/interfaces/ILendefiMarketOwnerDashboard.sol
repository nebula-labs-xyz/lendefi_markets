// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IASSETS} from "./IASSETS.sol";

/**
 * @title ILendefiMarketOwnerDashboard
 * @notice Interface for the Lendefi Market Owner Dashboard contract
 * @dev Provides owner-specific function signatures and struct definitions for market owner dashboard functionality
 */
interface ILendefiMarketOwnerDashboard {
    // ========== STRUCTS ==========

    /**
     * @notice Owner's market overview with detailed metrics
     */
    struct OwnerMarketOverview {
        // Market Identity
        address baseAsset;
        string baseAssetSymbol;
        uint8 baseAssetDecimals;
        string marketName;
        string marketSymbol;
        uint256 createdAt;
        bool active;
        // Market Contracts
        address coreContract;
        address vaultContract;
        address assetsModule;
        address porFeed;
        // Financial Metrics
        uint256 totalSuppliedLiquidity;
        uint256 totalBorrowed;
        uint256 totalCollateralValueUSD;
        uint256 utilization;
        uint256 supplyRate;
        uint256 borrowRate;
        // Vault Metrics
        uint256 totalShares;
        uint256 totalAssets;
        uint256 sharePrice;
        uint256 totalLiquidityProviders;
        // Revenue & Performance
        uint256 totalFeesEarned;
        uint256 protocolRevenue;
        uint256 ownerRevenue;
        uint256 performanceScore; // 0-1000
        // Risk Metrics
        uint256 averageHealthFactor;
        uint256 totalPositions;
        uint256 liquidationThreshold;
        uint256 riskScore; // 0-1000, higher = riskier
    }

    /**
     * @notice Aggregated statistics for all of owner's markets
     */
    struct OwnerPortfolioStats {
        // Portfolio Overview
        uint256 totalMarkets;
        address[] managedBaseAssets;
        uint256 portfolioCreationDate;
        // Financial Aggregates
        uint256 totalPortfolioTVL;
        uint256 totalPortfolioDebt;
        uint256 totalCollateralUSD;
        uint256 averageUtilization;
        // Revenue & Performance
        uint256 totalFeesEarned;
        uint256 totalProtocolRevenue;
        uint256 totalOwnerRevenue;
        uint256 portfolioPerformanceScore; // 0-1000
        // Risk & Health
        uint256 portfolioHealthScore; // 0-1000
        uint256 totalLiquidations;
        uint256 averageRiskScore;
        // User Engagement
        uint256 totalLiquidityProviders;
        uint256 totalBorrowers;
        uint256 averagePositionSize;
    }

    /**
     * @notice Detailed borrower information for owner's markets
     */
    struct BorrowerInfo {
        // Borrower Identity
        address borrower;
        // Market Activity
        address[] marketsUsed; // Which of owner's markets this borrower uses
        uint256 totalPositions;
        uint256 firstInteractionDate;
        uint256 lastInteractionDate;
        // Financial Data
        uint256 totalDebtAcrossMarkets;
        uint256 totalCollateralUSD;
        uint256 averageHealthFactor;
        uint256 creditLimit;
        uint256 utilizationRate;
        // Risk Assessment
        uint256 riskScore; // 0-1000
        bool isLiquidatable;
        uint256 liquidationRisk; // 0-1000
        // Performance
        uint256 totalInterestPaid;
        uint256 totalLiquidationsPaid;
        bool isReliableBorrower;
    }

    /**
     * @notice Liquidity provider information for owner's markets
     */
    struct LiquidityProviderInfo {
        // Provider Identity
        address provider;
        // Market Activity
        address[] marketsUsed; // Which of owner's markets this provider uses
        uint256 firstDepositDate;
        uint256 lastActivityDate;
        // Financial Data
        uint256 totalLPTokens;
        uint256 totalLPValue;
        uint256 totalDeposited;
        uint256 totalWithdrawn;
        uint256 netPosition;
        // Rewards & Performance
        uint256 totalRewardsEarned;
        uint256 averageAPY;
        bool isRewardEligible;
        uint256 pendingRewards;
        // Engagement
        uint256 transactionCount;
        bool isActiveLiquidityProvider;
    }

    /**
     * @notice Performance analytics for a specific market
     */
    struct MarketPerformanceAnalytics {
        // Market Identity
        address baseAsset;
        string marketName;
        // Time-based Performance
        uint256 dailyVolumeUSD;
        uint256 weeklyVolumeUSD;
        uint256 monthlyVolumeUSD;
        uint256 tvlGrowthRate; // Basis points
        // Revenue Analytics
        uint256 dailyRevenue;
        uint256 weeklyRevenue;
        uint256 monthlyRevenue;
        uint256 revenueGrowthRate; // Basis points
        // User Analytics
        uint256 newLiquidityProviders;
        uint256 newBorrowers;
        uint256 retentionRate; // Basis points
        uint256 avgSessionDuration;
        // Risk Analytics
        uint256 liquidationEvents;
        uint256 avgHealthFactor;
        uint256 riskTrend; // 0=decreasing, 1=stable, 2=increasing
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Gets comprehensive overview of all markets owned by a specific owner
     * @param owner Address of the market owner
     * @return Array of OwnerMarketOverview structs for all owner's markets
     */
    function getOwnerMarketOverviews(address owner) external view returns (OwnerMarketOverview[] memory);

    /**
     * @notice Gets overview for a specific market owned by the owner
     * @param owner Address of the market owner
     * @param baseAsset Address of the base asset
     * @return OwnerMarketOverview struct for the specified market
     */
    function getOwnerMarketOverview(address owner, address baseAsset)
        external
        view
        returns (OwnerMarketOverview memory);

    /**
     * @notice Gets aggregated portfolio statistics for all of owner's markets
     * @param owner Address of the market owner
     * @return OwnerPortfolioStats struct containing portfolio-wide metrics
     */
    function getOwnerPortfolioStats(address owner) external view returns (OwnerPortfolioStats memory);

    /**
     * @notice Gets detailed information about all borrowers across owner's markets
     * @param owner Address of the market owner
     * @return Array of BorrowerInfo for all borrowers in owner's markets
     */
    function getOwnerBorrowers(address owner) external view returns (BorrowerInfo[] memory);

    /**
     * @notice Gets detailed information about all liquidity providers across owner's markets
     * @param owner Address of the market owner
     * @return Array of LiquidityProviderInfo for all LPs in owner's markets
     */
    function getOwnerLiquidityProviders(address owner) external view returns (LiquidityProviderInfo[] memory);

    /**
     * @notice Gets borrowers for a specific market owned by the owner
     * @param owner Address of the market owner
     * @param baseAsset Address of the base asset
     * @return Array of BorrowerInfo for borrowers in the specific market
     */
    function getMarketBorrowers(address owner, address baseAsset) external view returns (BorrowerInfo[] memory);

    /**
     * @notice Gets liquidity providers for a specific market owned by the owner
     * @param owner Address of the market owner
     * @param baseAsset Address of the base asset
     * @return Array of LiquidityProviderInfo for LPs in the specific market
     */
    function getMarketLiquidityProviders(address owner, address baseAsset)
        external
        view
        returns (LiquidityProviderInfo[] memory);

    /**
     * @notice Gets performance analytics for a specific market
     * @param owner Address of the market owner
     * @param baseAsset Address of the base asset
     * @return MarketPerformanceAnalytics struct with detailed performance metrics
     */
    function getMarketPerformanceAnalytics(address owner, address baseAsset)
        external
        view
        returns (MarketPerformanceAnalytics memory);

    /**
     * @notice Gets performance analytics for all of owner's markets
     * @param owner Address of the market owner
     * @return Array of MarketPerformanceAnalytics for all owner's markets
     */
    function getOwnerMarketAnalytics(address owner) external view returns (MarketPerformanceAnalytics[] memory);

    /**
     * @notice Gets top borrowers by debt amount across owner's markets
     * @param owner Address of the market owner
     * @param limit Maximum number of borrowers to return
     * @return Array of BorrowerInfo sorted by total debt (descending)
     */
    function getTopBorrowersByDebt(address owner, uint256 limit) external view returns (BorrowerInfo[] memory);

    /**
     * @notice Gets top liquidity providers by LP value across owner's markets
     * @param owner Address of the market owner
     * @param limit Maximum number of providers to return
     * @return Array of LiquidityProviderInfo sorted by LP value (descending)
     */
    function getTopLiquidityProviders(address owner, uint256 limit)
        external
        view
        returns (LiquidityProviderInfo[] memory);

    /**
     * @notice Gets borrowers at risk of liquidation across owner's markets
     * @param owner Address of the market owner
     * @return Array of BorrowerInfo for borrowers with high liquidation risk
     */
    function getAtRiskBorrowers(address owner) external view returns (BorrowerInfo[] memory);

    // ========== IMMUTABLE GETTERS ==========

    /**
     * @notice Returns the market factory contract address
     * @return Address of the market factory
     */
    function marketFactory() external view returns (address);

    /**
     * @notice Returns the ecosystem contract address
     * @return Address of the ecosystem contract
     */
    function ecosystem() external view returns (address);
}
