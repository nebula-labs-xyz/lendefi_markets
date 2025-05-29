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
 *
 * @title Lendefi Protocol Core
 * @notice Core lending protocol focused on collateral management and lending calculations
 * @author alexei@nebula-labs(dot)xyz
 * @dev Asset-agnostic core - base currency tokenization handled by ERC4626 wrappers
 * @dev Implements a secure and upgradeable collateralized lending protocol with Yield Token
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {LendefiRates} from "./lib/LendefiRates.sol";
import {LendefiConstants} from "./lib/LendefiConstants.sol";
import {IVAULT} from "../interfaces/IVAULT.sol";
import {IASSETS} from "../interfaces/IASSETS.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {LendefiVault} from "./LendefiVault.sol";
import {ILendefiMarketVault} from "../interfaces/ILendefiMarketVault.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @custom:oz-upgrades
contract LendefiCore is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using Clones for address;
    using SafeERC20 for IERC20;
    using LendefiRates for *;
    using LendefiConstants for *;
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    enum PositionStatus {
        INACTIVE,
        ACTIVE,
        LIQUIDATED,
        CLOSED
    }
    enum CollateralTier {
        STABLE,
        CROSS_A,
        CROSS_B,
        ISOLATED
    }

    /**
     * @notice Oracle types
     */
    enum OracleType {
        CHAINLINK,
        UNISWAP_V3_TWAP
    }

    // ========== STRUCTS ==========
    struct ProtocolConfig {
        uint256 profitTargetRate; // Rate in 1e6
        uint256 borrowRate; // Rate in 1e6
        uint256 rewardAmount; // Amount of governance tokens
        uint256 rewardInterval; // Duration in blocks
        uint256 rewardableSupply; // Amount of base asset
        uint256 liquidatorThreshold; // Amount of governance tokens
    }

    struct UserPosition {
        address vault; // Address of the vault
        bool isIsolated; // Whether position is isolated
        PositionStatus status; // Current status
        uint256 debtAmount; // Amount of debt
        uint256 lastInterestAccrual; // Last interest accrual timestamp
    }

    /**
     * @notice Configuration for Uniswap V3 pool-based oracle
     */
    struct UniswapPoolConfig {
        address pool;
        uint32 twapPeriod;
        uint8 active;
    }

    /**
     * @notice Configuration for Chainlink oracle
     */
    struct ChainlinkOracleConfig {
        address oracleUSD;
        uint8 active;
    }

    /**
     * @notice Asset configuration
     */
    struct Asset {
        uint8 active;
        uint8 decimals;
        uint16 borrowThreshold;
        uint16 liquidationThreshold;
        uint256 maxSupplyThreshold;
        uint256 isolationDebtCap;
        uint8 assetMinimumOracles;
        address porFeed;
        OracleType primaryOracleType;
        CollateralTier tier;
        ChainlinkOracleConfig chainlinkConfig;
        UniswapPoolConfig poolConfig;
    }

    struct Market {
        address core; // Address of the core contract
        address baseVault; // Address of the wrapper contract
        address baseAsset; // Address of the base asset
        address porFeed; // Proof of Reserve feed
        uint256 decimals; // Base asset decimals
        string name; // Market name
        string symbol; // Market symbol
        uint256 createdAt; // Creation timestamp
        bool active; // Whether the market is active
    }

    // ========== STATE VARIABLES ==========

    address public govToken;
    address public treasury;
    address public baseAsset;
    address public marketFactory;
    address public cVault;

    uint256 public totalBorrow;
    uint256 public totalAccruedBorrowerInterest;
    uint256 public baseDecimals;

    /// @notice Information about the currently pending upgrade
    Market public market;
    ProtocolConfig public mainConfig;

    IASSETS public assetsModule;
    ILendefiMarketVault public baseVault;

    ///////////////////////////////////////////////////////
    // -------------------Mappings ----------------------//
    ///////////////////////////////////////////////////////
    /// @notice Total value locked per asset in USD
    EnumerableMap.AddressToUintMap internal assetTVLinUSD;
    mapping(address => uint256) public assetTVL;

    mapping(address => UserPosition[]) internal positions;
    mapping(address => mapping(uint256 => EnumerableMap.AddressToUintMap)) internal positionCollateral;

    uint256[10] private __gap;

    // ========== EVENTS ==========
    event Initialized(address indexed baseAsset);
    event SupplyCollateral(address indexed user, uint256 indexed positionId, address indexed asset, uint256 amount);
    event WithdrawCollateral(address indexed user, uint256 indexed positionId, address indexed asset, uint256 amount);
    event Borrow(address indexed user, uint256 indexed positionId, uint256 amount);
    event Repay(address indexed user, uint256 indexed positionId, uint256 amount);
    event PositionCreated(address indexed user, uint256 indexed positionId, bool isIsolated);
    event VaultCreated(address indexed user, uint256 indexed positionId, address vault);
    event PositionClosed(address indexed user, uint256 indexed positionId);
    event Liquidated(address indexed user, uint256 indexed positionId, address indexed liquidator);
    event InterestAccrued(address indexed user, uint256 indexed positionId, uint256 interest);
    event DepositLiquidity(address indexed user, uint256 amount);
    event WithdrawLiquidity(address indexed user, uint256 amount);
    event RedeemShares(address indexed user, uint256 shares, uint256 amount);
    event MintShares(address indexed user, uint256 shares);
    event ProtocolConfigUpdated(
        uint256 profitTargetRate,
        uint256 borrowRate,
        uint256 rewardAmount,
        uint256 rewardInterval,
        uint256 rewardableSupply,
        uint256 liquidatorThreshold
    );

    /**
     * @notice Emitted when an asset's total value locked (TVL) is updated
     * @param asset The address of the asset that was updated
     * @param amount The new TVL amount
     */
    event TVLUpdated(address indexed asset, uint256 amount);

    // ========== ERRORS ==========
    error ZeroAmount();
    error ZeroAddressNotAllowed();
    error InvalidPosition();
    error InactivePosition();
    error MaxPositionLimitReached();
    error NotListed();
    error AssetCapacityReached();
    error IsolatedAssetViolation();
    error InvalidAssetForIsolation();
    error MaximumAssetsReached();
    error LowBalance();
    error CreditLimitExceeded();
    error LowLiquidity();
    error IsolationDebtCapExceeded();

    error NoDebt();
    error NotEnoughGovernanceTokens();
    error NotLiquidatable();
    error Unauthorized();
    error PoolLiquidityLimitReached();
    error InvalidProfitTarget();
    error InvalidBorrowRate();
    error InvalidRewardAmount();
    error InvalidInterval();
    error MEVSameBlockOperation();
    error MEVSlippageExceeded();
    error InvalidSupplyAmount();
    error InvalidLiquidatorThreshold();
    error CloneDeploymentFailed();

    // ========== MODIFIERS ==========
    modifier validPosition(address user, uint256 positionId) {
        if (positionId >= positions[user].length) revert InvalidPosition();
        _;
    }

    modifier activePosition(address user, uint256 positionId) {
        if (positionId >= positions[user].length) revert InvalidPosition();
        if (positions[user][positionId].status != PositionStatus.ACTIVE) revert InactivePosition();
        _;
    }

    modifier validAsset(address asset) {
        if (!assetsModule.isAssetValid(asset)) revert NotListed();
        _;
    }

    modifier validAmount(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }

    // ========== CONSTRUCTOR ==========
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ========== INITIALIZATION ==========
    function initialize(address admin, address govToken_, address assetsModule_, address treasury_)
        external
        initializer
    {
        if (admin == address(0)) revert ZeroAddressNotAllowed();
        if (treasury_ == address(0)) revert ZeroAddressNotAllowed();
        if (assetsModule_ == address(0)) revert ZeroAddressNotAllowed();
        if (govToken_ == address(0)) revert ZeroAddressNotAllowed();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(LendefiConstants.MANAGER_ROLE, admin);
        _grantRole(LendefiConstants.PAUSER_ROLE, admin);
        _grantRole(LendefiConstants.UPGRADER_ROLE, admin);

        treasury = treasury_;
        assetsModule = IASSETS(assetsModule_);
        marketFactory = msg.sender;
        govToken = govToken_;

        // Initialize default parameters using dynamic baseDecimals
        mainConfig = ProtocolConfig({
            profitTargetRate: 0.01e6, // 1%
            borrowRate: 0.06e6, // 6%
            rewardAmount: 2_000 ether, // 2,000 governance tokens
            rewardInterval: 180 * 24 * 60 * 5, // 180 days in blocks
            rewardableSupply: 100_000 * baseDecimals, // 100,000 base asset units
            liquidatorThreshold: 20_000 ether // 20,000 governance tokens
        });

        // Create vault implementation
        cVault = address(new LendefiVault(address(this)));
    }

    /**
     * @notice Initializes the market with the provided market info
     * @dev This function handles the initialization of the market, which includes:
     *      1. Validating the market info
     *      2. Setting the market info in the market struct
     *      3. Setting the base asset in the baseAsset struct
     *      4. Setting the base vault in the baseVault struct
     *      5. Setting the baseDecimals value based on the asset decimals
     *      6. Emitting the initialized event
     *
     * The function ensures that the market is initialized successfully and emits the appropriate events.
     *
     * @param marketInfo Market info to be initialized
     *
     * @custom:requirements
     *   - Market info must be valid
     *   - Base asset must be valid
     *   - Base vault must be valid
     *
     * @custom:state-changes
     *   - Sets the market info in the market struct
     *   - Sets the base asset in the baseAsset struct
     *   - Sets the base vault in the baseVault struct
     *   - Sets the baseDecimals value based on the asset decimals
     *
     * @custom:emits
     *   - Initialized(baseAsset)
     */
    function initializeMarket(Market calldata marketInfo) external {
        if (msg.sender != marketFactory) revert Unauthorized();

        if (marketInfo.baseAsset == address(0)) revert ZeroAddressNotAllowed();
        if (marketInfo.porFeed == address(0)) revert ZeroAddressNotAllowed();
        if (marketInfo.baseVault == address(0)) revert ZeroAddressNotAllowed();
        if (marketInfo.core != address(this)) revert ZeroAddressNotAllowed();

        market = marketInfo;
        baseAsset = marketInfo.baseAsset;
        baseVault = ILendefiMarketVault(marketInfo.baseVault);
        uint8 assetDecimals = IERC20Metadata(baseAsset).decimals();
        baseDecimals = 10 ** assetDecimals;
        emit Initialized(marketInfo.baseAsset);
    }

    /**
     * @notice Updates protocol parameters from a configuration struct
     * @dev Validates all parameters against minimum/maximum constraints before applying
     * @param config The new protocol configuration to apply
     * @custom:access-control Restricted to LendefiConstants.MANAGER_ROLE
     * @custom:events Emits a ProtocolConfigUpdated event
     * @custom:error-cases
     *   - InvalidProfitTarget: Thrown when profit target rate is below minimum
     *   - InvalidBorrowRate: Thrown when borrow rate is below minimum
     *   - InvalidRewardAmount: Thrown when reward amount exceeds maximum
     *   - InvalidInterval: Thrown when interval is below minimum
     *   - InvalidSupplyAmount: Thrown when supply amount is below minimum
     *   - InvalidLiquidatorThreshold: Thrown when liquidator threshold is below minimum
     */
    function loadProtocolConfig(ProtocolConfig calldata config) external onlyRole(LendefiConstants.MANAGER_ROLE) {
        // Validate all parameters
        if (config.profitTargetRate < 0.0025e6) revert InvalidProfitTarget();
        if (config.borrowRate < 0.01e6) revert InvalidBorrowRate();
        if (config.rewardAmount > 10_000 ether) revert InvalidRewardAmount();
        if (config.rewardInterval < 90 days) revert InvalidInterval();
        if (config.rewardableSupply < 20_000 * baseDecimals) revert InvalidSupplyAmount();
        if (config.liquidatorThreshold < 10 ether) revert InvalidLiquidatorThreshold();

        // Update the mainConfig struct
        mainConfig = config;

        // Emit a single consolidated event
        emit ProtocolConfigUpdated(
            config.profitTargetRate,
            config.borrowRate,
            config.rewardAmount,
            config.rewardInterval,
            config.rewardableSupply,
            config.liquidatorThreshold
        );
    }

    /**
     * @notice Supplies liquidity to the protocol
     * @dev This function handles the supply of liquidity to the protocol, which includes:
     *      1. Validating the amount and expected value
     *      2. Preventing MEV attacks via liquidity accrue time index
     *      3. Transferring tokens from user to this contract
     *      4. Approving vault to spend tokens
     *      5. Previewing the deposit amount
     *      6. Slippage protection on shares received
     *      7. Updating the liquidity accrue time index
     *      8. Emitting the supply liquidity event
     *      9. Depositing the liquidity into the base vault
     *
     * The function ensures that the liquidity is supplied successfully and emits the appropriate events.
     *
     * @param amount Amount of base asset to supply
     * @param expectedShares Expected shares to receive
     * @param maxSlippageBps Maximum slippage percentage allowed
     *
     * @custom:requirements
     *   - Amount must be valid
     *   - Expected shares must be valid
     *   - Max slippage must be valid
     *
     * @custom:state-changes
     *   - Updates the liquidity accrue time index
     *   - Deposits the liquidity into the base vault
     *
     * @custom:emits
     *   - DepositLiquidity(msg.sender, amount)
     */
    function depositLiquidity(uint256 amount, uint256 expectedShares, uint32 maxSlippageBps)
        external
        validAmount(amount)
        validAmount(expectedShares)
        validAmount(maxSlippageBps)
        nonReentrant
        whenNotPaused
    {
        // Transfer tokens from user to this contract
        IERC20(baseAsset).safeTransferFrom(msg.sender, address(this), amount);

        // Approve vault to spend tokens
        IERC20(baseAsset).forceApprove(address(baseVault), amount);

        emit DepositLiquidity(msg.sender, amount);
        uint256 sharesOut = baseVault.deposit(amount, msg.sender);
        _validateSlippage(sharesOut, expectedShares, maxSlippageBps);
    }

    /**
     * @notice Mints shares for the LP
     * @dev This function handles the minting of shares for the user, which includes:
     *      1. Validating the shares amount and expected value
     *      2. Preventing MEV attacks via liquidity accrue time index
     *      3. Slippage protection on base asset received
     *      4. Updating the liquidity accrue time index
     *      5. Minting shares from the vault
     *
     * @param shares Amount of shares to mint
     * @param expectedAmount Expected amount of base asset to receive
     * @param maxSlippageBps Maximum slippage percentage allowed
     */
    function mintShares(uint256 shares, uint256 expectedAmount, uint32 maxSlippageBps)
        external
        validAmount(shares)
        validAmount(expectedAmount)
        validAmount(maxSlippageBps)
        nonReentrant
        whenNotPaused
    {
        // Mint shares from vault - tokens go directly to user
        uint256 actualAmount = baseVault.mint(shares, msg.sender);
        _validateSlippage(actualAmount, expectedAmount, maxSlippageBps);
        emit MintShares(msg.sender, shares);
    }

    /**
     * @notice Redeems shares for base asset from the protocol
     * @dev This function handles the redemption of shares from the protocol, which includes:
     *      1. Validating the shares amount and expected value
     *      2. Preventing MEV attacks via liquidity accrue time index
     *      3. Slippage protection on base asset received
     *      4. Updating the liquidity accrue time index
     *      5. Redeeming from the vault
     *
     * @param shares Amount of shares to redeem
     * @param expectedAmount Expected amount of base asset to receive
     * @param maxSlippageBps Maximum slippage percentage allowed
     */
    function redeemLiquidityShares(uint256 shares, uint256 expectedAmount, uint32 maxSlippageBps)
        external
        validAmount(shares)
        validAmount(expectedAmount)
        validAmount(maxSlippageBps)
        nonReentrant
        whenNotPaused
    {
        // Withdraw from vault - tokens go directly to user
        uint256 actualAmount = baseVault.redeem(shares, msg.sender, msg.sender);
        // Slippage protection on base asset received
        _validateSlippage(actualAmount, expectedAmount, maxSlippageBps);
        emit RedeemShares(msg.sender, shares, actualAmount);
    }

    /**
     * @notice Withdraws a specific amount of base asset from the protocol
     * @dev This function handles the withdrawal of a specific amount of base asset from the protocol, which includes:
     *      1. Validating the amount and expected shares
     *      2. Preventing MEV attacks via liquidity accrue time index
     *      3. Slippage protection on shares burned
     *      4. Updating the liquidity accrue time index
     *      5. Withdrawing from the vault
     *
     * @param amount Amount of base asset to withdraw
     * @param expectedShares Expected number of shares to burn
     * @param maxSlippageBps Maximum slippage percentage allowed
     */
    function withdrawLiquidity(uint256 amount, uint256 expectedShares, uint32 maxSlippageBps)
        external
        validAmount(amount)
        validAmount(expectedShares)
        validAmount(maxSlippageBps)
        nonReentrant
        whenNotPaused
    {
        // Withdraw from vault - tokens go directly to user
        uint256 actualShares = baseVault.withdraw(amount, msg.sender, msg.sender);
        _validateSlippage(actualShares, expectedShares, maxSlippageBps);
        emit WithdrawLiquidity(msg.sender, amount);
    }

    // ========== POSITION MANAGEMENT ==========
    /**
     * @notice Creates a new position for the user
     * @dev This function handles the creation of a new position, which includes:
     *      1. Validating the asset and position limit
     *      2. Creating a new position in the positions array
     *      3. Creating a new vault for the position
     *      4. Setting the position status to ACTIVE
     *      5. Emitting the position created event
     *
     * The function ensures that the position is created successfully and emits the appropriate events.
     *
     * @param asset Address of the asset to be used in the position
     * @param isIsolated Boolean indicating whether the position is isolated
     *
     * @custom:requirements
     *   - Asset must be valid
     *   - User must not exceed the maximum position limit
     *
     * @custom:state-changes
     *   - Creates a new position in the positions array
     *   - Creates a new vault for the position
     *   - Sets the position status to ACTIVE
     *
     * @custom:emits
     *   - PositionCreated(msg.sender, positionId, isIsolated)
     */
    function createPosition(address asset, bool isIsolated) external validAsset(asset) nonReentrant whenNotPaused {
        if (positions[msg.sender].length >= 1000) revert MaxPositionLimitReached(); // Max position limit
        UserPosition storage newPosition = positions[msg.sender].push();
        uint256 positionId = positions[msg.sender].length - 1;

        address vault = Clones.clone(cVault);
        // Verify clone was successful
        if (vault == address(0)) revert CloneDeploymentFailed();
        if (vault.code.length == 0) revert CloneDeploymentFailed();

        IVAULT(vault).setOwner(msg.sender);
        newPosition.vault = vault;
        newPosition.isIsolated = isIsolated;
        newPosition.status = PositionStatus.ACTIVE;

        if (isIsolated) {
            EnumerableMap.AddressToUintMap storage collaterals =
                positionCollateral[msg.sender][positions[msg.sender].length - 1];
            collaterals.set(asset, 0); // Register the asset with zero initial amount
        }

        emit VaultCreated(msg.sender, positionId, vault);
        emit PositionCreated(msg.sender, positionId, isIsolated);
    }

    /**
     * @notice Exits a position by repaying the debt and withdrawing all collateral
     * @dev This function handles the complete exit of a position, which includes:
     *      1. Repaying the debt via _processRepay (validation and state updates)
     *      2. Setting the position status to CLOSED
     *      3. Transferring the assets from the protocol to the caller
     *      4. Emitting the position closed event
     *
     * The function ensures that the position is repaid in full and all collateral is withdrawn.
     *
     * @param positionId ID of the position to exit
     * @param expectedDebt Expected debt amount before repayment
     * @param maxSlippageBps Maximum slippage percentage allowed
     *
     * @custom:requirements
     *   - Position must exist and be in ACTIVE status
     *   - Current balance must be greater than or equal to the repayment amount
     *   - Position must remain sufficiently collateralized after repayment
     *
     * @custom:state-changes
     *   - Sets position.status to CLOSED
     *   - Transfers asset tokens from the contract to msg.sender
     *
     * @custom:emits
     *   - PositionClosed(msg.sender, positionId)
     */
    function exitPosition(uint256 positionId, uint256 expectedDebt, uint32 maxSlippageBps)
        external
        nonReentrant
        whenNotPaused
    {
        UserPosition storage position = positions[msg.sender][positionId];
        uint256 actualAmount = _processRepay(positionId, type(uint256).max, position, expectedDebt, maxSlippageBps);
        position.status = PositionStatus.CLOSED;
        if (actualAmount > 0) {
            // Transfer from user to core
            IERC20(baseAsset).safeTransferFrom(msg.sender, address(this), actualAmount);
            // Approve vault to pull tokens
            IERC20(baseAsset).forceApprove(address(baseVault), actualAmount);
            // Repay to vault
            baseVault.repay(actualAmount, msg.sender);
        }

        EnumerableMap.AddressToUintMap storage collaterals = positionCollateral[msg.sender][positionId];
        address vault = positions[msg.sender][positionId].vault;

        // Process all assets before clearing the mapping
        uint256 length = collaterals.length();
        for (uint256 i = 0; i < length; i++) {
            (address asset, uint256 amount) = collaterals.at(i);

            if (amount > 0) {
                uint256 newTVL = assetTVL[asset] - amount;
                assetTVL[asset] = newTVL;
                uint256 usdValue = assetsModule.updateAssetPoRFeed(asset, newTVL);
                assetTVLinUSD.set(asset, usdValue);
                emit TVLUpdated(asset, newTVL);
                emit WithdrawCollateral(msg.sender, positionId, asset, amount);
                IVAULT(vault).withdrawToken(asset, amount);
            }
        }

        // Clear all entries at once
        collaterals.clear();
        emit PositionClosed(msg.sender, positionId);
    }

    /**
     * @notice Supplies collateral assets to a position
     * @dev This function handles adding collateral to an existing position, which includes:
     *      1. Processing the deposit via _processDeposit (validation and state updates)
     *      2. Emitting the supply event
     *      3. Transferring the assets from the caller to the protocol
     *
     * The collateral can be used to either open new borrowing capacity or
     * strengthen the collateralization ratio of an existing debt position.
     *
     * For isolated positions, only the initial asset type can be supplied.
     * For cross-collateral positions, multiple asset types can be added
     * (up to a maximum of 20 different assets per position).
     *
     * @param asset Address of the collateral asset to supply
     * @param amount Amount of the asset to supply as collateral
     * @param positionId ID of the position to receive the collateral
     *
     * @custom:requirements
     *   - Protocol must not be paused
     *   - Position must exist and be in ACTIVE status
     *   - Asset must be whitelisted in the protocol
     *   - Asset must not be at its global capacity limit
     *   - For isolated positions: asset must match the position's initial asset
     *   - For isolated assets: position must be in isolation mode
     *   - Position must have fewer than 20 different asset types (if adding a new asset type)
     *
     * @custom:state-changes
     *   - Increases positionCollateralAmounts[msg.sender][positionId][asset] by amount
     *   - Adds asset to positionCollateralAssets[msg.sender][positionId] if not already present
     *   - Updates protocol-wide TVL for the asset
     *   - Transfers asset tokens from msg.sender to the contract
     *
     * @custom:emits
     *   - SupplyCollateral(msg.sender, positionId, asset, amount)
     *
     * @custom:access-control Available to position owners when protocol is not paused
     * @custom:error-cases
     *   - ZeroAmount: Thrown when amount is zero
     *   - InvalidPosition: Thrown when position doesn't exist
     *   - InactivePosition: Thrown when position is not in ACTIVE status
     *   - NotListed: Thrown when asset is not whitelisted
     *   - AssetCapacityReached: Thrown when asset has reached global capacity limit
     *   - IsolatedAssetViolation: Thrown when supplying isolated-tier asset to a cross position
     *   - InvalidAssetForIsolation: Thrown when supplying an asset that doesn't match the isolated position's asset
     *   - MaximumAssetsReached: Thrown when position already has 20 different asset types
     */
    function supplyCollateral(address asset, uint256 amount, uint256 positionId)
        external
        validAmount(amount)
        nonReentrant
        whenNotPaused
    {
        _processDeposit(asset, amount, positionId);
        address vault = positions[msg.sender][positionId].vault;
        emit SupplyCollateral(msg.sender, positionId, asset, amount);
        IERC20(asset).safeTransferFrom(msg.sender, vault, amount);
    }

    /**
     * @notice Withdraws collateral assets from a position
     * @dev This function handles removing collateral from an existing position, which includes:
     *      1. Processing the withdrawal via _processWithdrawal (validation and state updates)
     *      2. Emitting the withdrawal event
     *      3. Transferring the assets from the protocol to the caller
     *
     * The function ensures that the position remains sufficiently collateralized
     * after the withdrawal by checking that the remaining credit limit exceeds
     * the outstanding debt.
     *
     * @param asset Address of the collateral asset to withdraw
     * @param amount Amount of the asset to withdraw
     * @param positionId ID of the position from which to withdraw
     *
     * @custom:requirements
     *   - Protocol must not be paused
     *   - Position must exist and be in ACTIVE status
     *   - For isolated positions: asset must match the position's initial asset
     *   - Current balance must be greater than or equal to the withdrawal amount
     *   - Position must remain sufficiently collateralized after withdrawal
     *
     * @custom:state-changes
     *   - Decreases positionCollateralAmounts[msg.sender][positionId][asset] by amount
     *   - Updates protocol-wide TVL for the asset
     *   - For non-isolated positions: Removes asset entirely if balance becomes zero
     *   - Transfers asset tokens from the contract to msg.sender
     *
     * @custom:emits
     *   - WithdrawCollateral(msg.sender, positionId, asset, amount)
     *
     * @custom:access-control Available to position owners when protocol is not paused
     * @custom:error-cases
     *   - ZeroAmount: Thrown when amount is zero
     *   - InvalidPosition: Thrown when position doesn't exist
     *   - InactivePosition: Thrown when position is not in ACTIVE status
     *   - InvalidAssetForIsolation: Thrown when withdrawing an asset that doesn't match the isolated position's asset
     *   - LowBalance: Thrown when not enough collateral balance to withdraw
     *   - CreditLimitExceeded: Thrown when withdrawal would leave position undercollateralized
     */
    function withdrawCollateral(address asset, uint256 amount, uint256 positionId)
        external
        validAmount(amount)
        nonReentrant
        whenNotPaused
    {
        _processWithdrawal(asset, amount, positionId);
        // Transfer from vault to user
        address vault = positions[msg.sender][positionId].vault;
        IVAULT(vault).withdrawToken(asset, amount);
        emit WithdrawCollateral(msg.sender, positionId, asset, amount);
    }

    /**
     * @notice Borrows assets from the protocol
     * @dev This function handles the borrowing of assets from the protocol, which includes:
     *      1. Validating the amount and expected credit limit
     *      2. Preventing MEV attacks via last interest accrual
     *      3. Calculating the current debt with interest
     *      4. Slippage protection on debt amount
     *      5. Updating the last interest accrual
     *      6. Emitting the borrow event
     *      7. Transferring the assets from the protocol to the caller
     *
     * The function ensures that the assets are borrowed successfully and emits the appropriate events.
     *
     * @param positionId ID of the position to borrow from
     * @param amount Amount of assets to borrow
     * @param expectedCreditLimit Expected credit limit before borrowing
     * @param maxSlippageBps Maximum slippage percentage allowed
     *
     * @custom:requirements
     *   - Amount must be valid
     *   - Expected credit limit must be valid
     *   - Max slippage must be valid
     *
     * @custom:state-changes
     *   - Updates the last interest accrual
     *   - Transfers assets from the protocol to msg.sender
     *
     * @custom:emits
     *   - Borrow(msg.sender, positionId, amount)
     */
    function borrow(uint256 positionId, uint256 amount, uint256 expectedCreditLimit, uint32 maxSlippageBps)
        external
        validAmount(amount)
        activePosition(msg.sender, positionId)
        nonReentrant
        whenNotPaused
    {
        uint256 currentDebt = 0;
        uint256 accruedInterest = 0;
        UserPosition storage position = positions[msg.sender][positionId];

        // MEV protection: prevent same-block operations
        if (position.lastInterestAccrual >= block.timestamp) revert MEVSameBlockOperation();

        if (position.debtAmount > 0) {
            currentDebt = calculateDebtWithInterest(msg.sender, positionId);
            accruedInterest = currentDebt - position.debtAmount;
            totalAccruedBorrowerInterest += accruedInterest;
            emit InterestAccrued(msg.sender, positionId, accruedInterest);
        }

        // Check protocol liquidity from vault
        uint256 availableLiquidity = baseVault.totalAssets() - baseVault.totalBorrow();
        if (accruedInterest + amount > availableLiquidity) revert LowLiquidity();

        // Check isolation debt cap if position is isolated
        if (position.isIsolated) {
            EnumerableMap.AddressToUintMap storage collaterals = positionCollateral[msg.sender][positionId];
            (address posAsset,) = collaterals.at(0);
            uint256 isolationDebtCap = assetsModule.getIsolationDebtCap(posAsset);
            if (currentDebt + amount > isolationDebtCap) revert IsolationDebtCapExceeded();
        }

        // Check credit limit
        uint256 creditLimit = calculateCreditLimit(msg.sender, positionId);
        _validateSlippage(creditLimit, expectedCreditLimit, maxSlippageBps);
        if (currentDebt + amount > creditLimit) revert CreditLimitExceeded();

        // Update position and protocol state
        totalBorrow += accruedInterest + amount;
        position.debtAmount = currentDebt + amount;
        position.lastInterestAccrual = block.timestamp;

        emit Borrow(msg.sender, positionId, amount);
        baseVault.borrow(amount, msg.sender);
    }

    // ========== REPAYMENT FUNCTIONS ==========
    /**
     * @notice Repays a borrow position
     * @dev This function handles repaying a borrow position, which includes:
     *      1. Processing the repayment via _processRepay (validation and state updates)
     *      2. Emitting the repayment event
     *      3. Transferring the assets from the caller to the protocol
     *
     * The function ensures that the position remains sufficiently collateralized
     * after the repayment by checking that the remaining credit limit exceeds
     * the outstanding debt.
     *
     * @param positionId ID of the position to repay
     * @param amount Amount of the asset to repay
     * @param expectedDebt Expected debt amount before repayment
     * @param maxSlippageBps Maximum slippage percentage allowed
     *
     * @custom:requirements
     *   - Protocol must not be paused
     *   - Position must exist and be in ACTIVE status
     *   - Current balance must be greater than or equal to the repayment amount
     *   - Position must remain sufficiently collateralized after repayment
     *
     * @custom:state-changes
     *   - Decreases positionCollateralAmounts[msg.sender][positionId][asset] by amount
     *   - Updates protocol-wide TVL for the asset
     *   - For non-isolated positions: Removes asset entirely if balance becomes zero
     *   - Transfers asset tokens from the contract to msg.sender
     *
     * @custom:emits
     *   - Repay(msg.sender, positionId, amount)
     *
     * @custom:access-control Available to position owners when protocol is not paused
     * @custom:error-cases
     *   - ZeroAmount: Thrown when amount is zero
     *   - InvalidPosition: Thrown when position doesn't exist
     *   - InactivePosition: Thrown when position is not in ACTIVE status
     *   - LowBalance: Thrown when not enough collateral balance to repay
     *   - CreditLimitExceeded: Thrown when repayment would leave position undercollateralized
     */
    function repay(uint256 positionId, uint256 amount, uint256 expectedDebt, uint32 maxSlippageBps)
        external
        nonReentrant
        whenNotPaused
    {
        UserPosition storage position = positions[msg.sender][positionId];
        uint256 actualAmount = _processRepay(positionId, amount, position, expectedDebt, maxSlippageBps);
        if (actualAmount > 0) {
            // Transfer from user to core
            IERC20(baseAsset).safeTransferFrom(msg.sender, address(this), actualAmount);
            // Approve vault to pull tokens
            IERC20(baseAsset).forceApprove(address(baseVault), actualAmount);
            // Repay to vault
            baseVault.repay(actualAmount, msg.sender);
        }
    }

    /**
     * @dev Liquidates a borrow position
     * @param user Address of the user
     * @param positionId ID of the position to liquidate
     * @param expectedCost Expected liquidation cost
     * @param maxSlippageBps Maximum slippage percentage allowed
     *
     * @custom:requirements
     *   - Protocol must not be paused
     *   - Position must exist and be in ACTIVE status
     *   - Current balance must be greater than or equal to the liquidation cost
     *   - Position must remain sufficiently collateralized after liquidation
     *
     * @custom:state-changes
     *   - Decreases positionCollateralAmounts[msg.sender][positionId][asset] by amount
     *   - Updates protocol-wide TVL for the asset
     *   - For non-isolated positions: Removes asset entirely if balance becomes zero
     *   - Transfers asset tokens from the contract to msg.sender
     *
     * @custom:emits
     *   - Liquidated(msg.sender, positionId)
     *
     * @custom:access-control Available to position owners when protocol is not paused
     * @custom:error-cases
     *   - NotEnoughGovernanceTokens: Thrown when caller doesn't have enough governance tokens
     *   - NotLiquidatable: Thrown when position's health factor is above 1.0
     *   - InvalidPosition: Thrown when position doesn't exist
     *   - InactivePosition: Thrown when position is not in ACTIVE status
     */
    function liquidate(address user, uint256 positionId, uint256 expectedCost, uint32 maxSlippageBps)
        external
        activePosition(user, positionId)
        nonReentrant
        whenNotPaused
    {
        if (IERC20(govToken).balanceOf(msg.sender) < mainConfig.liquidatorThreshold) {
            revert NotEnoughGovernanceTokens();
        }
        if (!isLiquidatable(user, positionId)) revert NotLiquidatable();

        UserPosition storage position = positions[user][positionId];
        uint256 debtWithInterest = calculateDebtWithInterest(user, positionId);

        uint256 interestAccrued = debtWithInterest - position.debtAmount;
        totalAccruedBorrowerInterest += interestAccrued;

        uint256 liquidationFee = getPositionLiquidationFee(user, positionId);
        uint256 fee = ((debtWithInterest * liquidationFee) / baseDecimals);
        uint256 totalCost = debtWithInterest + fee;

        // Slippage protection on total liquidation cost
        _validateSlippage(totalCost, expectedCost, maxSlippageBps);

        totalBorrow -= position.debtAmount;
        position.debtAmount = 0;
        position.status = PositionStatus.LIQUIDATED;

        // Get the position's vault
        address vault = positions[user][positionId].vault;
        // Transfer all assets from vault to liquidator
        IVAULT(vault).liquidate(getPositionCollateralAssets(user, positionId), msg.sender);
        // Clear all collateral assets
        positionCollateral[user][positionId].clear();

        emit InterestAccrued(user, positionId, interestAccrued);
        emit Liquidated(user, positionId, msg.sender);

        // Transfer liquidation payment from liquidator
        IERC20(baseAsset).safeTransferFrom(msg.sender, address(this), totalCost);
        // Repay the debt
        IERC20(baseAsset).forceApprove(address(baseVault), totalCost);
        baseVault.repay(totalCost, user);
    }

    /**
     * @notice Calculates the current debt including accrued interest for a position
     * @dev Uses the appropriate interest rate based on the position's collateral tier
     * @param user Address of the position owner
     * @param positionId ID of the position to calculate debt for
     * @return The total debt amount including principal and accrued interest
     */
    function calculateDebtWithInterest(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (uint256)
    {
        UserPosition storage position = positions[user][positionId];
        if (position.debtAmount == 0) return 0;

        IASSETS.CollateralTier tier = getPositionTier(user, positionId);
        uint256 borrowRate = getBorrowRate(tier);
        uint256 timeElapsed = block.timestamp - position.lastInterestAccrual;

        return LendefiRates.calculateDebtWithInterest(position.debtAmount, borrowRate, timeElapsed);
    }

    /**
     * @notice Calculates the credit limit for a position
     * @dev Uses the appropriate interest rate based on the position's collateral tier
     * @param user Address of the position owner
     * @param positionId ID of the position to calculate credit limit for
     * @return The credit limit for the position
     */
    function calculateCreditLimit(address user, uint256 positionId) public view returns (uint256) {
        (, uint256 liqLevel,) = calculateLimits(user, positionId);
        return liqLevel;
    }

    /**
     * @notice Calculates the total USD value of all collateral in a position
     * @dev Uses oracle prices to convert collateral amounts to USD value
     * @param user Address of the position owner
     * @param positionId ID of the position to calculate value for
     * @return value - The total USD value of all collateral assets in the position
     */
    function calculateCollateralValue(address user, uint256 positionId) public view returns (uint256 value) {
        (,, value) = calculateLimits(user, positionId);
    }

    /**
     * @notice Calculates the health factor of a position
     * @dev Health factor is the ratio of weighted collateral to debt, below 1.0 is liquidatable
     * @param user Address of the position owner
     * @param positionId ID of the position to calculate health for
     * @return The position's health factor in baseDecimals format (1.0 = 1e6)
     * @custom:error-cases
     *   - InvalidPosition: Thrown when position doesn't exist
     */
    function healthFactor(address user, uint256 positionId) public view returns (uint256) {
        uint256 debt = calculateDebtWithInterest(user, positionId);
        if (debt == 0) return type(uint256).max;
        (, uint256 liqLevel,) = calculateLimits(user, positionId);
        return (liqLevel * baseDecimals) / debt;
    }

    /**
     * @notice Calculates the credit limit, liquidation level, and collateral value for a position
     * @dev Uses oracle prices to convert collateral amounts to USD value
     * @param user Address of the position owner
     * @param positionId ID of the position to calculate limits for
     * @return credit - The maximum amount of USDC that can be borrowed against the position
     * @return liqLevel - The collateral value level where liquidation will occur
     * @return value - The total USD value of all collateral assets in the position
     */
    function calculateLimits(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (uint256 credit, uint256 liqLevel, uint256 value)
    {
        EnumerableMap.AddressToUintMap storage collaterals = positionCollateral[user][positionId];
        uint256 len = collaterals.length();

        for (uint256 i; i < len; i++) {
            (address asset, uint256 amount) = collaterals.at(i);
            if (amount == 0) continue;

            IASSETS.AssetCalculationParams memory params = assetsModule.getAssetCalculationParams(asset);
            IASSETS.AssetCalculationParams memory paramsBase = assetsModule.getAssetCalculationParams(baseAsset);

            // Use FullMath.mulDiv for maximum precision without overflow
            // First calculate the base value conversion
            uint256 assetValueInbaseDecimals =
                FullMath.mulDiv(amount * params.price, baseDecimals, paramsBase.price * (10 ** params.decimals));

            value += assetValueInbaseDecimals;

            // Calculate credit with full precision using mulDiv
            credit += FullMath.mulDiv(assetValueInbaseDecimals, params.borrowThreshold, 1000);

            // Calculate liquidation level with full precision using mulDiv
            liqLevel += FullMath.mulDiv(assetValueInbaseDecimals, params.liquidationThreshold, 1000);
        }
    }

    /**
     * @notice Gets the number of positions owned by a user
     * @dev Includes all positions regardless of status (active, closed, liquidated)
     * @param user Address of the user to query
     * @return The number of positions created by the user
     */
    function getUserPositionsCount(address user) public view returns (uint256) {
        return positions[user].length;
    }

    /**
     * @notice Gets all positions owned by a user
     * @dev Returns the full array of position structs for the user
     * @param user Address of the user to query
     * @return Array of UserPosition structs for all the user's positions
     */
    function getUserPositions(address user) public view returns (UserPosition[] memory) {
        return positions[user];
    }

    /**
     * @notice Gets a specific position for a user
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return The user position data
     */
    function getUserPosition(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (UserPosition memory)
    {
        return positions[user][positionId];
    }

    /**
     * @notice Gets the liquidation fee percentage for a position
     * @dev Based on the highest risk tier among the position's collateral assets
     * @param user Address of the position owner
     * @param positionId ID of the position to query
     * @return The liquidation fee percentage in baseDecimals format (e.g., 0.05e6 = 5%)
     */
    function getPositionLiquidationFee(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (uint256)
    {
        IASSETS.CollateralTier tier = getPositionTier(user, positionId);
        return assetsModule.getLiquidationFee(tier);
    }

    /**
     * @notice Determines the collateral tier of a position
     * @dev For cross-collateral positions, returns the highest risk tier among assets
     * @param user Address of the position owner
     * @param positionId ID of the position to check
     * @return tier The position's collateral tier (STABLE, CROSS_A, CROSS_B, or ISOLATED)
     */
    function getPositionTier(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (IASSETS.CollateralTier tier)
    {
        EnumerableMap.AddressToUintMap storage collaterals = positionCollateral[user][positionId];
        uint256 len = collaterals.length();
        tier = IASSETS.CollateralTier.STABLE;

        for (uint256 i; i < len; i++) {
            (address asset, uint256 amount) = collaterals.at(i);

            if (amount > 0) {
                IASSETS.CollateralTier assetTier = assetsModule.getAssetTier(asset);
                if (uint8(assetTier) > uint8(tier)) {
                    tier = assetTier;
                }
            }
        }
    }

    /**
     * @notice Returns the protocol configuration
     * @return The protocol configuration
     */
    function getConfig() public view returns (ProtocolConfig memory) {
        return mainConfig;
    }

    /**
     * @notice Returns the collateral assets for a specific position
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return An array of collateral assets
     */
    function getPositionCollateralAssets(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (address[] memory)
    {
        return positionCollateral[user][positionId].keys();
    }

    /**
     * @notice Gets the collateral amount for a specific asset in a position
     * @param user Address of the position owner
     * @param positionId ID of the position
     * @param asset Address of the collateral asset
     * @return The amount of the specified asset in the position
     */
    function getCollateralAmount(address user, uint256 positionId, address asset)
        public
        view
        validPosition(user, positionId)
        returns (uint256)
    {
        (bool exists, uint256 amount) = positionCollateral[user][positionId].tryGet(asset);
        return exists ? amount : 0;
    }

    /**
     * @notice Calculates the current supply interest rate for liquidity providers
     * @dev Based on utilization, protocol fees, and available liquidity
     * @return The current annual supply interest rate in baseDecimals format
     */
    function getSupplyRate() public view returns (uint256) {
        return LendefiRates.getSupplyRate(
            baseVault.totalSupply(),
            totalBorrow,
            baseVault.totalSuppliedLiquidity(),
            mainConfig.profitTargetRate,
            baseVault.totalAssets()
        );
    }

    /**
     * @notice Calculates the current borrow interest rate for a specific collateral tier
     * @dev Based on utilization, base rate, supply rate, and tier-specific jump rate
     * @param tier The collateral tier to calculate the borrow rate for
     * @return The current annual borrow interest rate in baseDecimals format
     */
    function getBorrowRate(IASSETS.CollateralTier tier) public view returns (uint256) {
        return LendefiRates.getBorrowRate(
            baseVault.utilization(),
            mainConfig.borrowRate,
            mainConfig.profitTargetRate,
            getSupplyRate(),
            assetsModule.getTierJumpRate(tier)
        );
    }

    /**
     * @notice Determines if a position is eligible for liquidation
     * @dev Checks if health factor is below 1.0, indicating undercollateralization
     * @param user Address of the position owner
     * @param positionId ID of the position to check
     * @return True if the position can be liquidated, false otherwise
     */
    function isLiquidatable(address user, uint256 positionId)
        public
        view
        activePosition(user, positionId)
        returns (bool)
    {
        if (positions[user][positionId].debtAmount == 0) return false;
        // Use the health factor which properly accounts for liquidation thresholds
        // Health factor < 1.0 means position is undercollateralized based on liquidation parameters
        uint256 healthFactorValue = healthFactor(user, positionId);

        // Compare against baseDecimals (1.0 in fixed-point representation)
        return healthFactorValue < baseDecimals;
    }

    /**
     * @notice Checks if the protocol is solvent based on total asset value and borrow amount
     * @dev Ensures that the total asset value exceeds the total borrow amount
     * @return True if the protocol is solvent, false otherwise, and amount of total asset value
     */
    function isCollateralized() public view returns (bool, uint256) {
        uint256 totalAssetValue = baseVault.totalAssets() - totalBorrow;
        uint256 length = assetTVLinUSD.length();

        for (uint256 i = 0; i < length; i++) {
            (, uint256 value) = assetTVLinUSD.at(i);
            totalAssetValue += value;
        }

        return (totalAssetValue >= totalBorrow, totalAssetValue);
    }
    // ========== INTERNAL FUNCTIONS ==========

    /**
     * @notice Processes collateral deposit operations with validation and state updates
     * @dev Internal function that handles the core logic for adding collateral to a position,
     *      enforcing protocol rules about isolation mode, asset capacity limits, and asset counts.
     *      This function is called by both supplyCollateral and interpositionalTransfer.
     *
     * The function performs several validations to ensure the deposit complies with
     * protocol rules:
     * 1. Verifies the asset hasn't reached its global capacity limit
     * 2. Enforces isolation mode rules (isolated assets can't be added to cross positions)
     * 3. Ensures isolated positions only contain a single asset type
     * 4. Limits positions to a maximum of 20 different asset types
     *
     * @param asset Address of the collateral asset to deposit
     * @param amount Amount of the asset to deposit (in the asset's native units)
     * @param positionId ID of the position to receive the collateral
     *
     * @custom:requirements
     *   - Asset must be whitelisted in the protocol (validated by validAsset modifier)
     *   - Position must exist and be in ACTIVE status (validated by activePosition modifier)
     *   - Asset must not be at its global capacity limit
     *   - For isolated assets: position must not be a cross-collateral position
     *   - For isolated positions: asset must match the position's initial asset (if any exists)
     *   - Position must have fewer than 20 different asset types (if adding a new asset type)
     *
     * @custom:state-changes
     *   - Adds asset to positionCollateralAssets[msg.sender][positionId] if not already present
     *   - Increases positionCollateralAmounts[msg.sender][positionId][asset] by amount
     *   - Increases global assetTVL[asset] by amount
     *
     * @custom:emits
     *   - TVLUpdated(asset, newTVL)
     *
     * @custom:error-cases
     *   - NotListed: Thrown when asset is not whitelisted
     *   - InvalidPosition: Thrown when position doesn't exist
     *   - InactivePosition: Thrown when position is not in ACTIVE status
     *   - AssetCapacityReached: Thrown when asset has reached its global capacity limit
     *   - IsolatedAssetViolation: Thrown when supplying isolated-tier asset to a cross position
     *   - InvalidAssetForIsolation: Thrown when asset doesn't match isolated position's asset
     *   - MaximumAssetsReached: Thrown when position already has 20 different asset types
     */
    function _processDeposit(address asset, uint256 amount, uint256 positionId)
        internal
        validAsset(asset)
        activePosition(msg.sender, positionId)
    {
        if (assetsModule.isAssetAtCapacity(asset, amount)) revert AssetCapacityReached(); // Asset capacity reached

        UserPosition storage position = positions[msg.sender][positionId];
        // Check if the position is isolated
        EnumerableMap.AddressToUintMap storage collaterals = positionCollateral[msg.sender][positionId];
        if (assetsModule.getAssetTier(asset) == IASSETS.CollateralTier.ISOLATED && !position.isIsolated) {
            revert IsolatedAssetViolation();
        }

        // For isolated positions, check we're using the correct asset
        if (position.isIsolated && collaterals.length() > 0) {
            (address firstAsset,) = collaterals.at(0);
            if (asset != firstAsset) revert InvalidAssetForIsolation();
        }

        // Check or add the asset
        (bool exists, uint256 currentAmount) = collaterals.tryGet(asset);
        if (!exists) {
            if (!exists && collaterals.length() >= 20) revert MaximumAssetsReached(); // Maximum assets reached
            if (assetsModule.poolLiquidityLimit(asset, amount)) revert PoolLiquidityLimitReached();
            collaterals.set(asset, amount);
        } else {
            if (assetsModule.poolLiquidityLimit(asset, currentAmount + amount)) revert PoolLiquidityLimitReached();
            collaterals.set(asset, currentAmount + amount);
        }

        uint256 newTVL = assetTVL[asset] + amount;
        assetTVL[asset] = newTVL;
        // Update PoR feed
        uint256 usdValue = assetsModule.updateAssetPoRFeed(asset, newTVL);
        assetTVLinUSD.set(asset, usdValue);
        emit TVLUpdated(address(asset), newTVL);
    }

    /**
     * @notice Processes a collateral withdrawal operation with validation and state updates
     * @dev Internal function that handles the core logic for removing collateral from a position,
     *      enforcing position solvency and validating withdrawal amounts.
     *      This function is called by both withdrawCollateral and interpositionalTransfer.
     *
     * The function performs several validations to ensure the withdrawal complies with
     * protocol rules:
     * 1. For isolated positions, verifies the asset matches the position's designated asset
     * 2. Checks that the position has sufficient balance of the asset
     * 3. Updates the position's collateral tracking based on withdrawal amount
     * 4. Ensures the position remains sufficiently collateralized after withdrawal
     *
     * @param asset Address of the collateral asset to withdraw
     * @param amount Amount of the asset to withdraw (in the asset's native units)
     * @param positionId ID of the position to withdraw from
     *
     * @custom:requirements
     *   - Position must exist and be in ACTIVE status (validated by activePosition modifier)
     *   - For isolated positions: asset must match the position's designated asset
     *   - Position must have sufficient balance of the specified asset
     *   - After withdrawal, position must maintain sufficient collateral for any outstanding debt
     *
     * @custom:state-changes
     *   - Decreases positionCollateralAmounts[msg.sender][positionId][asset] by amount
     *   - For non-isolated positions: Removes asset entirely if balance becomes zero
     *   - Decreases global assetTVL[asset] by amount
     *
     * @custom:emits
     *   - TVLUpdated(asset, newTVL)
     *
     * @custom:error-cases
     *   - InvalidAssetForIsolation: Thrown when trying to withdraw an asset that doesn't match the isolated position's asset
     *   - LowBalance: Thrown when position doesn't have sufficient balance of the asset
     *   - CreditLimitExceeded: Thrown when withdrawal would leave position undercollateralized
     */
    function _processWithdrawal(address asset, uint256 amount, uint256 positionId)
        internal
        activePosition(msg.sender, positionId)
    {
        UserPosition storage position = positions[msg.sender][positionId];
        EnumerableMap.AddressToUintMap storage collaterals = positionCollateral[msg.sender][positionId];

        // Check and update balance
        (bool exists, uint256 currentAmount) = collaterals.tryGet(asset);
        if (!exists || currentAmount < amount) revert LowBalance(); // Insufficient balance

        uint256 newAmount = currentAmount - amount;
        if (newAmount == 0 && !position.isIsolated) {
            collaterals.remove(asset);
        } else {
            collaterals.set(asset, newAmount);
        }

        uint256 newTVL = assetTVL[asset] - amount;
        assetTVL[asset] = newTVL;
        // Verify collateralization after withdrawal
        if (calculateCreditLimit(msg.sender, positionId) < position.debtAmount) revert CreditLimitExceeded(); // Credit limit maxed out
        uint256 usdValue = assetsModule.updateAssetPoRFeed(asset, newTVL);
        assetTVLinUSD.set(asset, usdValue);
        emit TVLUpdated(address(asset), newTVL);
    }

    /**
     * @notice Processes a repayment for a specific position
     * @dev Internal function used to handle repayment of debt for a position
     * @param positionId ID of the position to repay
     * @param proposedAmount Amount of debt to repay (proposed)
     * @param position Storage reference to the position
     * @param expectedDebt Expected debt amount for slippage protection
     * @param maxSlippageBps Maximum slippage percentage allowed
     * @return actualAmount Actual amount repaid (capped at total debt)
     */
    function _processRepay(
        uint256 positionId,
        uint256 proposedAmount,
        UserPosition storage position,
        uint256 expectedDebt,
        uint32 maxSlippageBps
    ) internal activePosition(msg.sender, positionId) validAmount(proposedAmount) returns (uint256 actualAmount) {
        // MEV protection: prevent same-block position operations
        if (position.lastInterestAccrual >= block.timestamp) revert MEVSameBlockOperation();

        if (position.debtAmount > 0) {
            // Calculate current debt with interest
            uint256 balance = calculateDebtWithInterest(msg.sender, positionId);
            _validateSlippage(balance, expectedDebt, maxSlippageBps);

            // Calculate interest accrued
            uint256 accruedInterest = balance - position.debtAmount;
            totalAccruedBorrowerInterest += accruedInterest;

            // Determine actual repayment amount (capped at total debt)
            actualAmount = proposedAmount > balance ? balance : proposedAmount;
            // Amount tracked in vault

            // Update total protocol debt
            totalBorrow = totalBorrow + (balance - actualAmount) - position.debtAmount;

            // Update position state
            position.debtAmount = balance - actualAmount;
            position.lastInterestAccrual = block.timestamp;

            // Emit events
            emit Repay(msg.sender, positionId, actualAmount);
            emit InterestAccrued(msg.sender, positionId, accruedInterest);
        }
    }

    /**
     * @notice Internal function to validate slippage protection
     * @dev Uses efficient absolute difference calculation to avoid division
     * @param actualAmount The actual amount being processed
     * @param expectedAmount The expected amount from the user
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
    function _validateSlippage(uint256 actualAmount, uint256 expectedAmount, uint32 maxSlippageBps) internal pure {
        if (expectedAmount > 0) {
            uint256 deviation =
                actualAmount > expectedAmount ? actualAmount - expectedAmount : expectedAmount - actualAmount;
            if (deviation * 10000 > expectedAmount * maxSlippageBps) revert MEVSlippageExceeded();
        }
    }
}
