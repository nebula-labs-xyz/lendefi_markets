// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IASSETS} from "./IASSETS.sol";

/**
 * @title ILendefiMarketDashboard
 * @notice Interface for the Lendefi Market Dashboard contract
 * @dev Provides function signatures and struct definitions for dashboard functionality
 */
interface ILendefiMarketDashboard {
    // ========== STRUCTS ==========

    /**
     * @notice Comprehensive market overview for dashboard display
     */
    struct MarketOverview {
        // Market Identity
        address marketOwner;
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
        // Protocol Health
        uint256 averageHealthFactor;
        uint256 totalPositions;
        uint256 liquidationThreshold;
    }

    /**
     * @notice Aggregated protocol statistics across all markets
     */
    struct ProtocolStats {
        // Market Statistics
        uint256 totalMarkets;
        uint256 totalMarketOwners;
        address[] supportedBaseAssets;
        // Financial Aggregates
        uint256 totalProtocolTVL;
        uint256 totalProtocolDebt;
        uint256 totalCollateralUSD;
        uint256 averageUtilization;
        // Governance & Rewards
        address governanceToken;
        uint256 totalRewardsDistributed;
        uint256 currentRewardRate;
        // Risk Metrics
        uint256 protocolHealthScore;
        uint256 totalLiquidations;
    }

    /**
     * @notice User-specific market data for personalized dashboard
     */
    struct UserMarketData {
        // Market Identity
        address marketOwner;
        address baseAsset;
        string baseAssetSymbol;
        string marketName;
        // User Liquidity Provision
        uint256 lpTokenBalance;
        uint256 lpTokenValue;
        bool isRewardEligible;
        uint256 pendingRewards;
        // User Borrowing
        uint256[] positionIds;
        uint256 totalDebt;
        uint256 totalCollateral;
        uint256 averageHealthFactor;
        uint256 availableCredit;
        // User Activity
        uint256 lastInteractionBlock;
        bool hasActivePositions;
    }

    /**
     * @notice Asset configuration and metrics for market analysis
     */
    struct AssetMetrics {
        // Asset Identity
        address assetAddress;
        string symbol;
        uint8 decimals;
        // Configuration
        bool active;
        uint16 borrowThreshold;
        uint16 liquidationThreshold;
        uint256 maxSupplyThreshold;
        IASSETS.CollateralTier tier;
        // Oracle Information
        IASSETS.OracleType primaryOracleType;
        bool hasChainlinkOracle;
        bool hasUniswapV3Oracle;
        uint256 currentPriceUSD;
        // Usage Statistics
        uint256 totalSupplied;
        uint256 totalBorrowed;
        uint256 utilizationRate;
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Gets comprehensive overview of all active markets
     * @return Array of MarketOverview structs for all active markets
     */
    function getAllMarketOverviews() external view returns (MarketOverview[] memory);

    /**
     * @notice Gets overview for a specific market
     * @param marketOwner Address of the market owner
     * @param baseAsset Address of the base asset
     * @return MarketOverview struct for the specified market
     */
    function getMarketOverview(address marketOwner, address baseAsset) external view returns (MarketOverview memory);

    /**
     * @notice Gets aggregated statistics across the entire protocol
     * @return ProtocolStats struct containing protocol-wide metrics
     */
    function getProtocolStats() external view returns (ProtocolStats memory);

    /**
     * @notice Gets user-specific data across all markets
     * @param user Address of the user
     * @return Array of UserMarketData for markets where user has activity
     */
    function getUserMarketData(address user) external view returns (UserMarketData[] memory);

    /**
     * @notice Gets detailed metrics for all supported assets
     * @return Array of AssetMetrics for all assets in the allowlist
     */
    function getAssetMetrics() external view returns (AssetMetrics[] memory);

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
