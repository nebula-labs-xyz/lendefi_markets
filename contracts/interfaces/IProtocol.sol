// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IASSETS} from "../interfaces/IASSETS.sol";

interface IPROTOCOL {
    // ========== ENUMS ==========

    /**
     * @notice Current status of a borrowing position
     * @dev Used to track position lifecycle and determine valid operations
     */
    enum PositionStatus {
        INACTIVE,   // Default state, never used
        ACTIVE,     // Position is active and can be modified
        LIQUIDATED, // Position has been liquidated
        CLOSED      // Position has been voluntarily closed by the user
    }

    /**
     * @notice Represents the risk tier of collateral assets
     * @dev Used to determine borrow rates and liquidation parameters
     */
    enum CollateralTier {
        STABLE,     // Stablecoins with minimal volatility
        CROSS_A,    // Major cryptocurrencies with low-medium volatility
        CROSS_B,    // Altcoins with medium-high volatility
        ISOLATED    // High-risk assets that must be isolated
    }

    /**
     * @notice Supported oracle types for price feeds
     * @dev Determines which oracle to use for asset pricing
     */
    enum OracleType {
        CHAINLINK,
        UNISWAP_V3_TWAP
    }

    // ========== STRUCTS ==========

    /**
     * @notice Configuration parameters for protocol operations and rewards
     * @dev Centralized storage for all adjustable protocol parameters
     */
    struct ProtocolConfig {
        uint256 profitTargetRate;      // Rate in 1e6
        uint256 borrowRate;            // Rate in 1e6
        uint256 rewardAmount;          // Amount of governance tokens
        uint256 rewardInterval;        // Reward interval in blocks
        uint256 rewardableSupply;      // Minimum rewardable supply
        uint256 liquidatorThreshold;   // Minimum liquidator token threshold
    }

    /**
     * @notice User borrowing position data
     * @dev Core data structure tracking user's debt and position configuration
     */
    struct UserPosition {
        address vault;                 // Address of the vault contract for this position
        bool isIsolated;              // Whether position uses isolation mode
        PositionStatus status;         // Current lifecycle status of the position
        uint256 debtAmount;           // Current debt principal without interest
        uint256 lastInterestAccrual;  // Timestamp of last interest accrual
    }

    /**
     * @notice Uniswap V3 pool configuration for TWAP oracle
     * @dev Contains pool address and TWAP parameters for price feeds
     */
    struct UniswapPoolConfig {
        address pool;                 // Uniswap V3 pool address
        uint32 twapPeriod;           // Time period for TWAP calculation
        uint8 active;                // Whether this oracle is active
    }

    /**
     * @notice Chainlink oracle configuration for price feeds
     * @dev Contains Chainlink aggregator addresses and activation status
     */
    struct ChainlinkOracleConfig {
        address oracleUSD;           // Chainlink aggregator for USD price
        uint8 active;                // Whether this oracle is active
    }

    /**
     * @notice Complete asset configuration including oracle and risk parameters
     * @dev Comprehensive asset data structure for collateral management
     */
    struct Asset {
        uint8 active;                    // Whether asset is active for lending
        uint8 decimals;                  // Token decimals
        uint16 borrowThreshold;          // LTV ratio for borrowing (basis points)
        uint16 liquidationThreshold;     // Liquidation threshold (basis points)
        uint256 maxSupplyThreshold;      // Maximum supply allowed
        uint256 isolationDebtCap;        // Maximum debt in isolation mode
        uint8 assetMinimumOracles;       // Minimum number of oracles required
        address porFeed;                 // Proof of Reserve feed address
        OracleType primaryOracleType;    // Primary oracle type to use
        CollateralTier tier;             // Risk tier classification
        ChainlinkOracleConfig chainlinkConfig;     // Chainlink configuration
        UniswapPoolConfig poolConfig;              // Uniswap V3 configuration
    }

    /**
     * @notice Market configuration and addresses
     * @dev Contains all market-specific contract addresses and metadata
     */
    struct Market {
        address core;                // Core lending logic contract
        address baseVault;           // Vault handling base asset
        address baseAsset;           // Base asset address (e.g. USDC)
        address porFeed;             // Proof of Reserve feed
        uint256 decimals;            // Base asset decimals
        string name;                 // Market name (e.g. "USDC Market")
        string symbol;               // Market symbol
        uint256 createdAt;           // Creation timestamp
        bool active;                 // Whether market is active
    }

    // ========== EVENTS ==========

    /**
     * @notice Emitted when market is initialized
     * @param baseAsset Address of the base asset
     */
    event Initialized(address indexed baseAsset);

    /**
     * @notice Emitted when collateral is supplied to a position
     * @param user Address of the position owner
     * @param positionId ID of the position
     * @param asset Address of the supplied collateral asset
     * @param amount Amount of collateral supplied
     */
    event SupplyCollateral(address indexed user, uint256 indexed positionId, address indexed asset, uint256 amount);

    /**
     * @notice Emitted when collateral is withdrawn from a position
     * @param user Address of the position owner
     * @param positionId ID of the position
     * @param asset Address of the withdrawn collateral asset
     * @param amount Amount of collateral withdrawn
     */
    event WithdrawCollateral(address indexed user, uint256 indexed positionId, address indexed asset, uint256 amount);

    /**
     * @notice Emitted when a user borrows against their position
     * @param user Address of the borrower
     * @param positionId ID of the position
     * @param amount Amount of base asset borrowed
     */
    event Borrow(address indexed user, uint256 indexed positionId, uint256 amount);

    /**
     * @notice Emitted when a user repays their debt
     * @param user Address of the borrower
     * @param positionId ID of the position
     * @param amount Amount of base asset repaid
     */
    event Repay(address indexed user, uint256 indexed positionId, uint256 amount);

    /**
     * @notice Emitted when a new position is created
     * @param user Address of the position owner
     * @param positionId ID of the newly created position
     * @param isIsolated Whether the position is in isolation mode
     */
    event PositionCreated(address indexed user, uint256 indexed positionId, bool isIsolated);

    /**
     * @notice Emitted when a vault is created for a position
     * @param user Address of the position owner
     * @param positionId ID of the position
     * @param vault Address of the created vault
     */
    event VaultCreated(address indexed user, uint256 indexed positionId, address vault);

    /**
     * @notice Emitted when a position is closed
     * @param user Address of the position owner
     * @param positionId ID of the closed position
     */
    event PositionClosed(address indexed user, uint256 indexed positionId);

    /**
     * @notice Emitted when a position is liquidated
     * @param user Address of the position owner
     * @param positionId ID of the liquidated position
     * @param liquidator Address of the liquidator
     */
    event Liquidated(address indexed user, uint256 indexed positionId, address indexed liquidator);

    /**
     * @notice Emitted when interest is accrued on a position
     * @param user Address of the position owner
     * @param positionId ID of the position
     * @param interest Amount of interest accrued
     */
    event InterestAccrued(address indexed user, uint256 indexed positionId, uint256 interest);

    /**
     * @notice Emitted when a user deposits liquidity into the protocol
     * @param user Address of the liquidity provider
     * @param amount Amount of base asset deposited
     */
    event DepositLiquidity(address indexed user, uint256 amount);

    /**
     * @notice Emitted when a user withdraws liquidity from the protocol
     * @param user Address of the liquidity provider
     * @param amount Amount of base asset withdrawn
     */
    event WithdrawLiquidity(address indexed user, uint256 amount);

    /**
     * @notice Emitted when a user redeems shares for base asset
     * @param user Address of the liquidity provider
     * @param shares Amount of shares redeemed
     * @param amount Amount of base asset received
     */
    event RedeemShares(address indexed user, uint256 shares, uint256 amount);

    /**
     * @notice Emitted when a user mints shares
     * @param user Address of the liquidity provider
     * @param shares Amount of shares minted
     */
    event MintShares(address indexed user, uint256 shares);

    /**
     * @notice Emitted when protocol configuration is updated
     */
    event ProtocolConfigUpdated(
        uint256 profitTargetRate,
        uint256 borrowRate,
        uint256 rewardAmount,
        uint256 rewardInterval,
        uint256 rewardableSupply,
        uint256 liquidatorThreshold
    );

    /**
     * @notice Emitted when TVL is updated for an asset
     * @param asset Address of the asset
     * @param amount New TVL amount
     */
    event TVLUpdated(address indexed asset, uint256 amount);

    // ========== ERRORS ==========

    /// @notice Thrown when an amount parameter is zero
    error ZeroAmount();

    /// @notice Thrown when an address parameter is zero
    error ZeroAddressNotAllowed();

    /// @notice Thrown when a position doesn't exist
    error InvalidPosition();

    /// @notice Thrown when trying to operate on an inactive position
    error InactivePosition();

    /// @notice Thrown when user tries to create more positions than allowed
    error MaxPositionLimitReached();

    /// @notice Thrown when an asset is not listed in the protocol
    error NotListed();

    /// @notice Thrown when asset supply capacity is reached
    error AssetCapacityReached();

    /// @notice Thrown when violating isolated asset rules
    error IsolatedAssetViolation();

    /// @notice Thrown when using wrong asset for isolated position
    error InvalidAssetForIsolation();

    /// @notice Thrown when position has reached maximum number of assets
    error MaximumAssetsReached();

    /// @notice Thrown when user has insufficient balance
    error LowBalance();

    /// @notice Thrown when operation would exceed credit limit
    error CreditLimitExceeded();

    /// @notice Thrown when insufficient liquidity for operation
    error LowLiquidity();

    /// @notice Thrown when isolation debt cap would be exceeded
    error IsolationDebtCapExceeded();

    /// @notice Thrown when position has no debt to repay
    error NoDebt();

    /// @notice Thrown when user lacks required governance tokens
    error NotEnoughGovernanceTokens();

    /// @notice Thrown when position is not liquidatable
    error NotLiquidatable();

    /// @notice Thrown when caller lacks required permissions
    error Unauthorized();

    /// @notice Thrown when deposit exceeds pool liquidity limits
    error PoolLiquidityLimitReached();

    /// @notice Thrown when profit target rate is invalid
    error InvalidProfitTarget();

    /// @notice Thrown when borrow rate is invalid
    error InvalidBorrowRate();

    /// @notice Thrown when reward amount is invalid
    error InvalidRewardAmount();

    /// @notice Thrown when interval is invalid
    error InvalidInterval();

    /// @notice Thrown when MEV protection detects same-block operation
    error MEVSameBlockOperation();

    /// @notice Thrown when transaction exceeds maximum slippage allowed
    error MEVSlippageExceeded();

    /// @notice Thrown when supply amount is invalid
    error InvalidSupplyAmount();

    /// @notice Thrown when liquidator threshold is invalid
    error InvalidLiquidatorThreshold();

    /// @notice Thrown when clone deployment fails
    error CloneDeploymentFailed();

    // ========== INITIALIZATION FUNCTIONS ==========

    /**
     * @notice Initializes the protocol with core dependencies and parameters
     * @param admin Address of the admin
     * @param govToken_ The address of the governance token
     * @param assetsModule_ The address of the assets module
     * @param treasury_ The address of the treasury contract
     */
    function initialize(
        address admin,
        address govToken_,
        address assetsModule_,
        address treasury_
    ) external;

    /**
     * @notice Initializes the market with market info
     * @param marketInfo Market configuration struct
     */
    function initializeMarket(Market calldata marketInfo) external;

    /**
     * @notice Loads a new protocol configuration
     * @param config The new protocol configuration to apply
     */
    function loadProtocolConfig(ProtocolConfig calldata config) external;

    // ========== LIQUIDITY MANAGEMENT FUNCTIONS ==========

    /**
     * @notice Deposits liquidity into the protocol and receives shares
     * @param amount The amount of base asset to deposit
     * @param expectedShares Expected shares to receive (MEV protection)
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
    function depositLiquidity(uint256 amount, uint256 expectedShares, uint32 maxSlippageBps) external;

    /**
     * @notice Mints shares by depositing base asset
     * @param shares The number of shares to mint
     * @param expectedAmount Expected amount to pay (MEV protection)
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
    function mintShares(uint256 shares, uint256 expectedAmount, uint32 maxSlippageBps) external;

    /**
     * @notice Redeems shares for base asset (share-based operation)
     * @param shares The number of shares to redeem
     * @param expectedAmount Expected amount to receive (MEV protection)
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
    function redeemLiquidityShares(uint256 shares, uint256 expectedAmount, uint32 maxSlippageBps) external;

    /**
     * @notice Withdraws liquidity from the protocol (amount-based operation)
     * @param amount The amount of base asset to withdraw
     * @param expectedShares Expected shares to burn (MEV protection)
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
    function withdrawLiquidity(uint256 amount, uint256 expectedShares, uint32 maxSlippageBps) external;

    // ========== POSITION MANAGEMENT FUNCTIONS ==========

    /**
     * @notice Creates a new borrowing position
     * @param asset The collateral asset for the position
     * @param isIsolated Whether to create an isolated position
     */
    function createPosition(address asset, bool isIsolated) external;

    /**
     * @notice Closes a position by repaying all debt and withdrawing all collateral
     * @param positionId The ID of the position to close
     * @param expectedDebt Expected debt amount (MEV protection)
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
    function exitPosition(uint256 positionId, uint256 expectedDebt, uint32 maxSlippageBps) external;

    /**
     * @notice Supplies collateral to a position
     * @param asset The address of the collateral asset
     * @param amount The amount of collateral to supply
     * @param positionId The ID of the position
     */
    function supplyCollateral(address asset, uint256 amount, uint256 positionId) external;

    /**
     * @notice Withdraws collateral from a position
     * @param asset The address of the collateral asset
     * @param amount The amount of collateral to withdraw
     * @param positionId The ID of the position
     */
    function withdrawCollateral(address asset, uint256 amount, uint256 positionId) external;

    /**
     * @notice Borrows base asset against a position
     * @param positionId The ID of the position
     * @param amount The amount to borrow
     * @param expectedCreditLimit Expected credit limit (MEV protection)
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
    function borrow(uint256 positionId, uint256 amount, uint256 expectedCreditLimit, uint32 maxSlippageBps) external;

    /**
     * @notice Repays debt for a position
     * @param positionId The ID of the position
     * @param amount The amount to repay
     * @param expectedDebt Expected debt amount (MEV protection)
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
    function repay(uint256 positionId, uint256 amount, uint256 expectedDebt, uint32 maxSlippageBps) external;

    /**
     * @notice Liquidates an unhealthy position
     * @param user The address of the position owner
     * @param positionId The ID of the position to liquidate
     * @param expectedCost Expected liquidation cost (MEV protection)
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
    function liquidate(address user, uint256 positionId, uint256 expectedCost, uint32 maxSlippageBps) external;

    // ========== VIEW FUNCTIONS ==========

    // State Variables
    function govToken() external view returns (address);
    function treasury() external view returns (address);
    function baseAsset() external view returns (address);
    function marketFactory() external view returns (address);
    function cVault() external view returns (address);
    function totalBorrow() external view returns (uint256);
    function totalAccruedBorrowerInterest() external view returns (uint256);
    function baseDecimals() external view returns (uint256);
    function market() external view returns (Market memory);
    function mainConfig() external view returns (ProtocolConfig memory);
    function assetTVL(address asset) external view returns (uint256);

    // Configuration
    function getConfig() external view returns (ProtocolConfig memory);

    // Position Information
    function getUserPositionsCount(address user) external view returns (uint256);
    function getUserPositions(address user) external view returns (UserPosition[] memory);
    function getUserPosition(address user, uint256 positionId) external view returns (UserPosition memory);
    function getPositionCollateralAssets(address user, uint256 positionId) external view returns (address[] memory);
    function getCollateralAmount(address user, uint256 positionId, address asset) external view returns (uint256);

    // Calculations
    function calculateDebtWithInterest(address user, uint256 positionId) external view returns (uint256);
    function calculateCreditLimit(address user, uint256 positionId) external view returns (uint256);
    function calculateCollateralValue(address user, uint256 positionId) external view returns (uint256);
    function calculateLimits(address user, uint256 positionId) 
        external 
        view 
        returns (uint256 credit, uint256 liqLevel, uint256 value);
    function healthFactor(address user, uint256 positionId) external view returns (uint256);
    function getPositionLiquidationFee(address user, uint256 positionId) external view returns (uint256);
    function getPositionTier(address user, uint256 positionId) external view returns (IASSETS.CollateralTier);

    // Protocol Status
    function isLiquidatable(address user, uint256 positionId) external view returns (bool);
    function isCollateralized() external view returns (bool, uint256);
    function getSupplyRate() external view returns (uint256);
    function getBorrowRate(IASSETS.CollateralTier tier) external view returns (uint256);
}