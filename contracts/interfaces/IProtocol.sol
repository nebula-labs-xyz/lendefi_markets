// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IASSETS} from "../interfaces/IASSETS.sol";

interface IProtocol {
    // ========== ENUMS ==========

    /**
     * @notice Current status of a borrowing position
     * @dev Used to track position lifecycle and determine valid operations
     */
    enum PositionStatus {
        INACTIVE,   // Default state, never used
        ACTIVE,     // Position is active and can be modified
        CLOSED,     // Position has been voluntarily closed by the user
        LIQUIDATED  // Position has been liquidated
    }

    // ========== STRUCTS ==========

    /**
     * @notice Configuration parameters for protocol operations and rewards
     * @dev Centralized storage for all adjustable protocol parameters
     */
    struct ProtocolConfig {
        uint256 profitTargetRate;      // Target profit rate (min 0.25%)
        uint256 borrowRate;            // Base borrow rate (min 1%)
        uint256 rewardAmount;          // Target reward amount (max 10,000 tokens)
        uint256 rewardInterval;        // Reward interval in seconds (min 90 days)
        uint256 rewardableSupply;      // Minimum rewardable supply (min 20,000 USDC)
        uint256 liquidatorThreshold;   // Minimum liquidator token threshold (min 10 tokens)
    }

    /**
     * @notice User borrowing position data
     * @dev Core data structure tracking user's debt and position configuration
     */
    struct UserPosition {
        address vault;                 // Address of the vault contract for this position
        uint256 debtAmount;           // Current debt principal without interest
        uint256 lastInterestAccrual;  // Timestamp of last interest accrual
        PositionStatus status;        // Current lifecycle status of the position
        bool isIsolated;             // Whether position uses isolation mode
    }

    /**
     * @notice Market configuration and addresses
     * @dev Contains all market-specific contract addresses
     */
    struct Market {
        string name;             // Market name (e.g. "USDC Market")
        address baseAsset;       // Base asset address (e.g. USDC)
        address baseVault;       // Vault handling base asset
        address core;            // Core lending logic contract
        address vaultFactory;    // Factory for creating position vaults
        address assets;          // Assets registry contract
    }

    // ========== EVENTS ==========

    /**
     * @notice Emitted when protocol is initialized
     * @param admin Address of the admin who initialized the contract
     */
    event Initialized(address indexed admin);

    /**
     * @notice Emitted when market is initialized
     * @param baseAsset Address of the base asset
     * @param baseVault Address of the base vault
     */
    event MarketInitialized(address indexed baseAsset, address indexed baseVault);

    /**
     * @notice Emitted when protocol Config is updated
     */
    event ProtocolConfigUpdated(
        uint256 profitTargetRate,
        uint256 borrowRate,
        uint256 rewardAmount,
        uint256 interval,
        uint256 supplyAmount,
        uint256 liquidatorAmount
    );

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
     * @param user Address of the share holder
     * @param shares Amount of shares redeemed
     * @param amount Amount of base asset received
     */
    event RedeemShares(address indexed user, uint256 shares, uint256 amount);

    /**
     * @notice Emitted when a user mints shares by depositing base asset
     * @param user Address of the depositor
     * @param amount Amount of base asset deposited
     * @param shares Amount of shares minted
     */
    event MintShares(address indexed user, uint256 amount, uint256 shares);

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
     * @notice Emitted when a new borrowing position is created
     * @param user Address of the position owner
     * @param positionId ID of the newly created position
     * @param isIsolated Whether the position was created in isolation mode
     */
    event PositionCreated(address indexed user, uint256 indexed positionId, bool isIsolated);

    /**
     * @notice Emitted when a position is closed
     * @param user Address of the position owner
     * @param positionId ID of the closed position
     */
    event PositionClosed(address indexed user, uint256 indexed positionId);

    /**
     * @notice Emitted when a user borrows from a position
     * @param user Address of the position owner
     * @param positionId ID of the position
     * @param amount Amount borrowed
     */
    event Borrow(address indexed user, uint256 indexed positionId, uint256 amount);

    /**
     * @notice Emitted when debt is repaid
     * @param user Address of the position owner
     * @param positionId ID of the position
     * @param amount Amount repaid
     */
    event Repay(address indexed user, uint256 indexed positionId, uint256 amount);

    /**
     * @notice Emitted when interest is accrued on a position
     * @param user Address of the position owner
     * @param positionId ID of the position
     * @param amount Interest amount accrued
     */
    event InterestAccrued(address indexed user, uint256 indexed positionId, uint256 amount);

    /**
     * @notice Emitted when rewards are distributed
     * @param user Address of the reward recipient
     * @param amount Reward amount distributed
     */
    event Reward(address indexed user, uint256 amount);

    /**
     * @notice Emitted when a position is liquidated
     * @param user The address of the position owner
     * @param positionId The ID of the inactive position
     * @param liquidator The address of the liquidator
     */
    event Liquidated(address indexed user, uint256 indexed positionId, address indexed liquidator);

    /**
     * @notice Emitted when an asset's total value locked (TVL) is updated
     * @param asset The address of the asset that was updated
     * @param amount The new TVL amount
     */
    event TVLUpdated(address indexed asset, uint256 amount);

    /**
     * @notice Event emitted when a new vault is created
     * @param user Owner of the position
     * @param positionId ID of the position
     * @param vault Address of the created vault
     */
    event VaultCreated(address indexed user, uint256 indexed positionId, address vault);

    // ========== ERRORS ==========

    /// @notice Thrown when attempting to set a critical address to the zero address
    error ZeroAddressNotAllowed();

    /// @notice Thrown when clone deployment fails
    error CloneDeploymentFailed();

    /**
     * @notice Thrown when attempting to create more positions than the protocol limit
     * @dev The protocol enforces a maximum number of positions per user
     */
    error MaxPositionLimitReached();

    /**
     * @notice Thrown when attempting to interact with a non-existent position
     * @dev Functions that require a valid position ID will throw this error
     */
    error InvalidPosition();

    /**
     * @notice Thrown when attempting to modify a position that is closed or liquidated
     * @dev Operations are only allowed on positions with ACTIVE status
     */
    error InactivePosition();

    /**
     * @notice Thrown when attempting to use an asset that isn't listed in the protocol
     * @dev Assets must be configured through governance before they can be used
     */
    error NotListed();

    /**
     * @notice Thrown when an operation is attempted with a zero amount
     * @dev Used in borrow, repay, supply and withdraw operations
     */
    error ZeroAmount();

    /**
     * @notice Thrown when the protocol does not have enough liquidity for an operation
     * @dev Used in borrow operations
     */
    error LowLiquidity();

    /**
     * @notice Thrown when attempting to supply an asset beyond its protocol-wide capacity
     * @dev Each asset has a maximum supply limit for risk management
     */
    error AssetCapacityReached();

    /**
     * @notice Thrown when attempting to violate isolation mode rules
     * @dev Isolated assets cannot be used in cross-collateralized positions
     */
    error IsolatedAssetViolation();

    /**
     * @notice Thrown when attempting to add an incompatible asset to an isolated position
     * @dev Isolated positions can only contain one asset type
     */
    error InvalidAssetForIsolation();

    /**
     * @notice Thrown when attempting to add more assets than the position limit
     * @dev Each position has a maximum number of different asset types it can hold
     */
    error MaximumAssetsReached();

    /**
     * @notice Thrown when attempting to withdraw more than the available balance
     * @dev Used in withdrawCollateral operations
     */
    error LowBalance();

    /**
     * @notice Thrown when a liquidator doesn't hold enough governance tokens
     * @dev Liquidators must meet a minimum governance token threshold
     */
    error NotEnoughGovernanceTokens();

    /**
     * @notice Thrown when attempting to liquidate a healthy position
     * @dev Positions must be below liquidation threshold to be liquidated
     */
    error NotLiquidatable();

    /**
     * @notice Thrown when attempting to set an invalid profit target
     * @dev Profit target must be above the minimum threshold
     */
    error InvalidProfitTarget();

    /**
     * @notice Thrown when attempting to set an invalid borrow rate
     * @dev Borrow rate must be above the minimum threshold
     */
    error InvalidBorrowRate();

    /**
     * @notice Thrown when attempting to set an invalid reward amount
     * @dev Reward amount must be within allowed limits
     */
    error InvalidRewardAmount();

    /**
     * @notice Thrown when attempting to set an invalid reward interval
     * @dev Reward interval must be above the minimum threshold
     */
    error InvalidInterval();

    /**
     * @notice Thrown when attempting to set an invalid rewardable supply amount
     * @dev Rewardable supply must be above the minimum threshold
     */
    error InvalidSupplyAmount();

    /**
     * @notice Thrown when attempting to set an invalid liquidator threshold
     * @dev Liquidator threshold must be above the minimum value
     */
    error InvalidLiquidatorThreshold();

    /**
     * @notice Thrown when attempting to borrow beyond an isolated asset's debt cap
     * @dev Isolated assets have maximum protocol-wide debt limits
     */
    error IsolationDebtCapExceeded();

    /**
     * @notice Thrown when attempting to borrow or withdraw beyond a position's credit limit
     * @dev The operation would make the position undercollateralized
     */
    error CreditLimitExceeded();

    /**
     * @notice Thrown when a user tries to deposit a collateral asset amount greater than 3% of total uniswap pool liquidity
     * @dev Used in operations that require positions to be liquidatable
     */
    error PoolLiquidityLimitReached();

    /// @notice Thrown when a transaction exceeds the maximum slippage allowed for MEV protection
    error MEVSlippageExceeded();

    // ========== CORE FUNCTIONS ==========

    /**
     * @notice Initializes the protocol with core dependencies and parameters
     * @param _baseAsset The address of the base asset (e.g., USDC)
     * @param _govToken The address of the governance token
     * @param _treasury The address of the treasury contract
     * @param _timelock The address of the timelock contract
     * @param _marketFactory The address of the market factory
     * @param _cVault The address of the cloneable vault implementation
     * @param _pauser The address with pausing capability
     */
    function initialize(
        address _baseAsset,
        address _govToken,
        address _treasury,
        address _timelock,
        address _marketFactory,
        address _cVault,
        address _pauser
    ) external;

    /**
     * @notice Initializes the market with vault and assets module
     * @param _baseVault The address of the base vault
     * @param _assets The address of the assets module
     */
    function initializeMarket(address _baseVault, address _assets) external;

    /**
     * @notice Loads a new protocol configuration
     * @param config The new protocol configuration to apply
     */
    function loadProtocolConfig(ProtocolConfig memory config) external;

    /**
     * @notice Pauses all protocol operations in case of emergency
     * @dev Can only be called by authorized governance roles
     */
    function pause() external;

    /**
     * @notice Unpauses the protocol to resume normal operations
     * @dev Can only be called by authorized governance roles
     */
    function unpause() external;

    // Liquidity Management Functions

    /**
     * @notice Deposits liquidity into the protocol and receives shares
     * @param amount The amount of base asset to deposit
     * @param minShares Minimum shares to receive (MEV protection)
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
    function depositLiquidity(uint256 amount, uint256 minShares, uint32 maxSlippageBps) external;

    /**
     * @notice Mints specific amount of shares by depositing base asset
     * @param shares The amount of shares to mint
     * @param maxAssets Maximum assets to deposit (MEV protection)
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
    function mintShares(uint256 shares, uint256 maxAssets, uint32 maxSlippageBps) external;

    /**
     * @notice Redeems shares for base asset
     * @param shares The amount of shares to redeem
     * @param minAssets Minimum assets to receive (MEV protection)
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
    function redeemLiquidityShares(uint256 shares, uint256 minAssets, uint32 maxSlippageBps) external;

    /**
     * @notice Withdraws specific amount of base asset by burning shares
     * @param assets The amount of base asset to withdraw
     * @param maxShares Maximum shares to burn (MEV protection)
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
    function withdrawLiquidity(uint256 assets, uint256 maxShares, uint32 maxSlippageBps) external;

    // Position Management Functions

    /**
     * @notice Creates a new borrowing position for the caller
     * @param asset The address of the initial collateral asset
     * @param isIsolated Whether to create the position in isolation mode
     */
    function createPosition(address asset, bool isIsolated) external;

    /**
     * @notice Allows users to supply collateral assets to a borrowing position
     * @param asset The address of the collateral asset to supply
     * @param amount The amount of the asset to supply
     * @param positionId The ID of the position to supply collateral to
     */
    function supplyCollateral(address asset, uint256 amount, uint256 positionId) external;

    /**
     * @notice Allows users to withdraw collateral assets from a borrowing position
     * @param asset The address of the collateral asset to withdraw
     * @param amount The amount of the asset to withdraw
     * @param positionId The ID of the position to withdraw from
     * @dev Will revert if withdrawal would make position undercollateralized
     */
    function withdrawCollateral(address asset, uint256 amount, uint256 positionId) external;

    /**
     * @notice Allows borrowing stablecoins against collateral in a position
     * @param positionId The ID of the position to borrow against
     * @param amount The amount of stablecoins to borrow
     * @param expectedCreditLimit Expected credit limit value for MEV protection
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
    function borrow(uint256 positionId, uint256 amount, uint256 expectedCreditLimit, uint32 maxSlippageBps) external;

    /**
     * @notice Allows users to repay debt on a borrowing position
     * @param positionId The ID of the position to repay debt for
     * @param amount The amount of debt to repay
     * @param expectedDebt Expected debt amount before repayment
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
    function repay(uint256 positionId, uint256 amount, uint256 expectedDebt, uint32 maxSlippageBps) external;

    /**
     * @notice Closes a position after all debt is repaid and withdraws remaining collateral
     * @param positionId The ID of the position to close
     * @param expectedDebt Expected debt amount before closure
     * @param maxSlippageBps Maximum allowed slippage in basis points
     * @dev Position must have zero debt to be closed
     */
    function exitPosition(uint256 positionId, uint256 expectedDebt, uint32 maxSlippageBps) external;

    /**
     * @notice Liquidates an undercollateralized position
     * @param user The address of the position owner
     * @param positionId The ID of the position to liquidate
     * @param expectedCost Expected total liquidation cost
     * @param maxSlippageBps Maximum allowed slippage in basis points
     * @dev Caller must hold sufficient governance tokens to be eligible as a liquidator
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
    function WAD() external view returns (uint256);
    function version() external view returns (uint256);

    // Market Information
    function market() external view returns (Market memory);
    function mainConfig() external view returns (ProtocolConfig memory);
    function getConfig() external view returns (ProtocolConfig memory);

    // Asset Information
    function assetTVL(address asset) external view returns (uint256);
    function assetDebtIsolated(address asset) external view returns (uint256);

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
    function calculateLimits(address user, uint256 positionId) external view returns (uint256 credit, uint256 liqLevel, uint256 value);
    function healthFactor(address user, uint256 positionId) external view returns (uint256);
    function getPositionLiquidationFee(address user, uint256 positionId) external view returns (uint256);
    function getPositionTier(address user, uint256 positionId) external view returns (IASSETS.CollateralTier);

    // Protocol Status
    function isLiquidatable(address user, uint256 positionId) external view returns (bool);
    function isCollateralized() external view returns (bool, uint256);
    function utilization() external view returns (uint256);
    function getSupplyRate() external view returns (uint256);
    function getBorrowRate(IASSETS.CollateralTier tier) external view returns (uint256);
}