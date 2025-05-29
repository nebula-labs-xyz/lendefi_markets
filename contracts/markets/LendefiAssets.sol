// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title LendefiAssets
 * @author alexei@nebula-labs(dot)xyz
 * @notice Manages asset configurations, listings, and oracle integrations
 * @dev Extracted component for asset-related functionality
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */

import {IASSETS} from "../interfaces/IASSETS.sol";
import {IPROTOCOL} from "../interfaces/IProtocol.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AggregatorV3Interface} from "../vendor/@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3Pool.sol";
import {UniswapTickMath} from "./lib/UniswapTickMath.sol";
import {LendefiConstants} from "./lib/LendefiConstants.sol";
import {IPoRFeed} from "../interfaces/IPoRFeed.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @custom:oz-upgrades
contract LendefiAssets is
    IASSETS,
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using Clones for address;
    using LendefiConstants for *;
    using UniswapTickMath for int24;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ==================== STATE VARIABLES ====================

    /// @notice Current version of the contract implementation
    /// @dev Incremented on each upgrade
    uint8 public version;

    /// @notice Address of the core protocol contract
    /// @dev Used for cross-contract calls and validation
    address public coreAddress;
    /// @notice Address of the usdc contract
    address internal usdc;
    /// @notice Address of the Proof of Reserve factory
    address public porFeed;
    /// @notice Address of the timelock contract
    address public timelock;

    /// @notice Information about the currently pending upgrade request
    /// @dev Stores implementation address and scheduling details
    UpgradeRequest public pendingUpgrade;

    /// @notice Interface to interact with the core protocol
    /// @dev Used to query protocol state and perform operations
    IPROTOCOL internal lendefiInstance;

    /// @notice Set of all listed asset addresses
    /// @dev Uses OpenZeppelin's EnumerableSet for efficient membership checks
    EnumerableSet.AddressSet internal listedAssets;

    /// @notice Mapping of asset address to its configuration
    /// @dev Stores complete asset settings including thresholds and oracle configs
    mapping(address => Asset) internal assetInfo;

    /// @notice Configuration of rates for each collateral tier
    /// @dev Maps tier enum to its associated rates struct
    mapping(CollateralTier => TierRates) public tierConfig;

    /// @notice Global oracle configuration parameters
    /// @dev Controls oracle freshness, volatility checks, and circuit breaker thresholds
    MainOracleConfig public mainOracleConfig;

    /// @notice Tracks whether circuit breaker is active for an asset
    /// @dev True if price feed is considered unreliable
    mapping(address asset => bool broken) public circuitBroken;

    /// @notice Reserved storage gap for future upgrades
    /// @dev Required by OpenZeppelin's upgradeable contracts pattern
    uint256[22] private __gap;

    /**
     * @notice Requires that the asset exists in the protocol's listed assets
     * @dev Modifier to guard functions that operate on listed assets
     * @param asset The address of the asset to check
     * @custom:reverts AssetNotListed if the asset is not in the listed assets set
     */
    modifier onlyListedAsset(address asset) {
        if (!listedAssets.contains(asset)) revert AssetNotListed(asset);
        _;
    }

    /**
     * @notice Checks that an address is not zero
     * @param addr The address to check
     */
    modifier nonZeroAddress(address addr) {
        if (addr == address(0)) revert ZeroAddressNotAllowed();
        _;
    }
    // ==================== CONSTRUCTOR & INITIALIZER ====================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with core configuration and access control settings
     * @dev This can only be called once through the proxy's initializer
     * @param timelock_ Address of the timelock_ contract that will have admin privileges
     * @param multisig Address of the multisig wallet for emergency controls
     * @param usdc_ USDC address
     * @custom:security Sets up the initial access control roles:
     * - DEFAULT_ADMIN_ROLE: timelock_
     * - MANAGER_ROLE: timelock_
     * - UPGRADER_ROLE: multisig, timelock_
     * - PAUSER_ROLE: multisig, timelock_
     * - CIRCUIT_BREAKER_ROLE: timelock_, multisig
     * @custom:oracle-config Initializes oracle configuration with the following defaults:
     * - freshnessThreshold: 28800 (8 hours)
     * - volatilityThreshold: 3600 (1 hour)
     * - volatilityPercentage: 20%
     * - circuitBreakerThreshold: 50%
     * @custom:version Sets initial contract version to 1
     */
    function initialize(address timelock_, address multisig, address usdc_, address porFeed_) external initializer {
        if (timelock_ == address(0) || multisig == address(0) || porFeed_ == address(0) || usdc_ == address(0)) {
            revert ZeroAddressNotAllowed();
        }

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, timelock_);
        _grantRole(LendefiConstants.MANAGER_ROLE, timelock_);
        _grantRole(LendefiConstants.UPGRADER_ROLE, multisig);
        _grantRole(LendefiConstants.UPGRADER_ROLE, timelock_);
        _grantRole(LendefiConstants.PAUSER_ROLE, multisig);
        _grantRole(LendefiConstants.PAUSER_ROLE, timelock_);

        // Initialize oracle config
        mainOracleConfig = MainOracleConfig({
            freshnessThreshold: 28800, // 8 hours
            volatilityThreshold: 3600, // 1 hour
            volatilityPercentage: 20, // 20%
            circuitBreakerThreshold: 50 // 50%
        });

        _initializeDefaultTierParameters();

        usdc = usdc_;
        porFeed = porFeed_;

        timelock = timelock_;
        version = 1;
    }

    /**
     * @notice Add an oracle with type specification
     * @param asset The asset to add the oracle for
     * @param oracle The oracle address
     * @param active active or not (1 or 0)
     */
    function updateChainlinkOracle(address asset, address oracle, uint8 active)
        external
        nonZeroAddress(oracle)
        onlyListedAsset(asset)
        onlyRole(LendefiConstants.MANAGER_ROLE)
        whenNotPaused
    {
        // Update Chainlink configuration
        assetInfo[asset].chainlinkConfig = ChainlinkOracleConfig({oracleUSD: oracle, active: active});

        // Create a memory copy of the asset configuration to validate
        Asset memory configCopy = assetInfo[asset];

        // Validate the updated configuration using the memory copy
        _validateAssetConfig(asset, configCopy);

        // Emit event to log the update
        emit ChainlinkOracleUpdated(asset, oracle, active);
    }

    // ==================== OTHER FUNCTIONS ====================

    /**
     * @notice Updates the global oracle configuration parameters
     * @param freshness Maximum age allowed for oracle data (15m-24h)
     * @param volatility Time window for volatility checks (5m-4h)
     * @param volatilityPct Maximum allowed price change percentage (5-30%)
     * @param circuitBreakerPct Price deviation to trigger circuit breaker (25-70%)
     */
    function updateMainOracleConfig(uint80 freshness, uint80 volatility, uint40 volatilityPct, uint40 circuitBreakerPct)
        external
        onlyRole(LendefiConstants.MANAGER_ROLE)
        whenNotPaused
    {
        // Validate parameters
        if (freshness < 15 minutes || freshness > 24 hours) {
            revert InvalidThreshold("freshness", freshness, 15 minutes, 24 hours);
        }

        if (volatility < 5 minutes || volatility > 4 hours) {
            revert InvalidThreshold("volatility", volatility, 5 minutes, 4 hours);
        }

        if (volatilityPct < 5 || volatilityPct > 30) {
            revert InvalidThreshold("volatilityPct", volatilityPct, 5, 30);
        }

        if (circuitBreakerPct < 25 || circuitBreakerPct > 70) {
            revert InvalidThreshold("circuitBreaker", circuitBreakerPct, 25, 70);
        }

        // Update config
        MainOracleConfig memory oldConfig = mainOracleConfig;

        mainOracleConfig.freshnessThreshold = freshness;
        mainOracleConfig.volatilityThreshold = volatility;
        mainOracleConfig.volatilityPercentage = volatilityPct;
        mainOracleConfig.circuitBreakerThreshold = circuitBreakerPct;

        // Emit events
        emit FreshnessThresholdUpdated(oldConfig.freshnessThreshold, freshness);
        emit VolatilityThresholdUpdated(oldConfig.volatilityThreshold, volatility);
        emit VolatilityPercentageUpdated(oldConfig.volatilityPercentage, volatilityPct);
        emit CircuitBreakerThresholdUpdated(oldConfig.circuitBreakerThreshold, circuitBreakerPct);
    }

    /**
     * @notice Updates rate configuration for a collateral tier
     * @param tier The collateral tier to update
     * @param jumpRate New jump rate (max 0.25e6 = 25%)
     * @param liquidationFee New liquidation fee (max 0.1e6 = 10%)
     */
    function updateTierConfig(CollateralTier tier, uint256 jumpRate, uint256 liquidationFee)
        external
        onlyRole(LendefiConstants.MANAGER_ROLE)
        whenNotPaused
    {
        if (jumpRate > 0.25e6) revert RateTooHigh(jumpRate, 0.25e6);
        if (liquidationFee > 0.1e6) revert FeeTooHigh(liquidationFee, 0.1e6);

        tierConfig[tier].jumpRate = jumpRate;
        tierConfig[tier].liquidationFee = liquidationFee;

        emit TierParametersUpdated(tier, jumpRate, liquidationFee);
    }

    // ==================== CORE FUNCTIONS ====================

    /**
     * @notice Updates the core protocol contract address
     * @dev This function can only be called by the DEFAULT_ADMIN_ROLE when the contract is not paused
     * @param newCore Address of the new core protocol contract
     * @custom:security Validates that the new address is not zero
     * @custom:access Restricted to DEFAULT_ADMIN_ROLE
     * @custom:emits CoreAddressUpdated event with the new core address
     */
    function setCoreAddress(address newCore)
        external
        nonZeroAddress(newCore)
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
    {
        coreAddress = newCore;
        lendefiInstance = IPROTOCOL(newCore);
        emit CoreAddressUpdated(newCore);
    }

    /**
     * @notice Pauses all contract operations
     * @dev This function can only be called by addresses with LendefiConstants.PAUSER_ROLE
     * @custom:access Restricted to LendefiConstants.PAUSER_ROLE
     * @custom:security Critical function that stops all state-changing operations
     */
    function pause() external onlyRole(LendefiConstants.PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses all contract operations
     * @dev This function can only be called by addresses with LendefiConstants.PAUSER_ROLE
     * @custom:access Restricted to LendefiConstants.PAUSER_ROLE
     * @custom:security Resumes normal contract operations
     */
    function unpause() external onlyRole(LendefiConstants.PAUSER_ROLE) {
        _unpause();
    }

    // ==================== ASSET MANAGEMENT ====================

    /**
     * @notice Updates or adds a new asset configuration
     * @dev Validates all configuration parameters before updating
     * @param asset The address of the asset to configure
     * @param config The complete asset configuration
     * @custom:security Includes comprehensive parameter validation
     * @custom:access Restricted to LendefiConstants.MANAGER_ROLE
     * @custom:pausable Operation not allowed when contract is paused
     * @custom:validation Asset address cannot be zero
     * @custom:emits UpdateAssetConfig when configuration is updated
     */
    function updateAssetConfig(address asset, Asset memory config)
        external
        nonZeroAddress(asset)
        onlyRole(LendefiConstants.MANAGER_ROLE)
        whenNotPaused
    {
        // Validate the entire config in one go
        _validateAssetConfig(asset, config);

        // If Uniswap oracle is active, validate pool configuration
        if (config.poolConfig.active == 1) {
            // Use the full validation with all parameters
            _validatePool(asset, config.poolConfig.pool, config.poolConfig.twapPeriod, config.poolConfig.active);
        }

        bool newAsset = !listedAssets.contains(asset);
        if (newAsset) {
            if (listedAssets.length() > uint256(LendefiConstants.MAX_ASSETS)) {
                revert AssetListTooLarge(LendefiConstants.MAX_ASSETS);
            }
            require(listedAssets.add(asset), "ADDING_ASSET");
            config.porFeed = Clones.clone(porFeed);
            // Verify clone was successful
            if (config.porFeed == address(0)) revert CloneDeploymentFailed();
            if (config.porFeed.code.length == 0) revert CloneDeploymentFailed();
            IPoRFeed(config.porFeed).initialize(asset, address(lendefiInstance), address(this), timelock);
        } else {
            if (config.porFeed == assetInfo[asset].porFeed) revert InvalidParameter("porFeed", 0);
        }

        assetInfo[asset] = config;
        emit UpdateAssetConfig(asset, config);
    }

    /**
     * @notice Updates the collateral tier for an existing asset
     * @dev Changes risk parameters associated with the asset
     * @param asset The address of the listed asset to modify
     * @param newTier The new collateral tier to assign
     * @custom:security Only modifies tier assignment
     * @custom:access Restricted to LendefiConstants.MANAGER_ROLE
     * @custom:pausable Operation not allowed when contract is paused
     * @custom:validation Asset must be previously listed
     * @custom:emits AssetTierUpdated when tier is changed
     */
    function updateAssetTier(address asset, CollateralTier newTier)
        external
        onlyListedAsset(asset)
        onlyRole(LendefiConstants.MANAGER_ROLE)
        whenNotPaused
    {
        assetInfo[asset].tier = newTier;
        emit AssetTierUpdated(asset, newTier);
    }

    /**
     * @notice Schedules an upgrade to a new implementation with timelock
     * @dev Only callable by addresses with LendefiConstants.UPGRADER_ROLE
     * @param newImplementation Address of the new implementation contract
     */
    function scheduleUpgrade(address newImplementation)
        external
        nonZeroAddress(newImplementation)
        onlyRole(LendefiConstants.UPGRADER_ROLE)
    {
        uint64 currentTime = uint64(block.timestamp);
        uint64 effectiveTime = currentTime + uint64(LendefiConstants.UPGRADE_TIMELOCK_DURATION);

        pendingUpgrade = UpgradeRequest({implementation: newImplementation, scheduledTime: currentTime, exists: true});

        emit UpgradeScheduled(msg.sender, newImplementation, currentTime, effectiveTime);
    }

    /**
     * @notice Cancels a previously scheduled upgrade
     * @dev Only callable by addresses with LendefiConstants.UPGRADER_ROLE
     */
    function cancelUpgrade() external onlyRole(LendefiConstants.UPGRADER_ROLE) {
        if (!pendingUpgrade.exists) {
            revert UpgradeNotScheduled();
        }

        address implementation = pendingUpgrade.implementation;
        delete pendingUpgrade;

        emit UpgradeCancelled(msg.sender, implementation);
    }

    /**
     * @notice Automatically evaluates and manages circuit breaker status based on price conditions
     * @dev Anyone can call this function to update circuit breaker status based on current conditions
     * @param asset The asset to evaluate circuit breaker status for
     * @return triggered Whether the circuit breaker is now active
     * @return deviation The percentage deviation that affected the decision
     */
    function evaluateCircuitBreaker(address asset)
        external
        onlyListedAsset(asset)
        returns (bool triggered, uint256 deviation)
    {
        // Get oracle configuration
        Asset storage info = assetInfo[asset];
        uint8 chainlinkActive = info.chainlinkConfig.active;
        uint8 uniswapActive = info.poolConfig.active;
        bool shouldBreak = false;
        uint256 deviationPct = 0;

        // Dual oracle case - check price deviation between oracles
        if (chainlinkActive == 1 && uniswapActive == 1) {
            (bool hasDeviation, uint256 devPercent) = checkPriceDeviation(asset);
            if (hasDeviation) {
                shouldBreak = true;
                deviationPct = devPercent;
            }
        }
        // Single Chainlink oracle case - check volatility between rounds
        else if (chainlinkActive == 1) {
            // Use new helper function to calculate volatility
            deviationPct = _getChainlinkVolatility(asset);

            // Get timestamp to check age
            address oracle = info.chainlinkConfig.oracleUSD;
            (,,, uint256 timestamp,) = AggregatorV3Interface(oracle).latestRoundData();
            uint256 age = block.timestamp - timestamp;

            // Check if volatility exceeds threshold and price is old enough
            if (deviationPct >= mainOracleConfig.volatilityPercentage && age >= mainOracleConfig.volatilityThreshold) {
                shouldBreak = true;
            }
        }

        // Update circuit breaker status based on conditions
        if (shouldBreak && !circuitBroken[asset]) {
            // Activate circuit breaker
            circuitBroken[asset] = true;
            emit CircuitBreakerTriggered(asset, deviationPct, block.timestamp);
            return (true, deviationPct);
        } else if (!shouldBreak && circuitBroken[asset]) {
            // Reset circuit breaker automatically when conditions return to normal
            circuitBroken[asset] = false;
            emit CircuitBreakerReset(asset);
            return (false, deviationPct);
        }

        // Return current status
        return (circuitBroken[asset], deviationPct);
    }

    /**
     * @notice Gets the price from the Chainlink oracle
     * @param asset The asset to get price for
     * @return usdValue The price in USD (scaled by 1e8)
     */
    function updateAssetPoRFeed(address asset, uint256 tvl)
        external
        onlyListedAsset(asset)
        returns (uint256 usdValue)
    {
        // Get PoR feed
        address feedAddr = assetInfo[asset].porFeed;
        // Update the reserves on the feed
        IPoRFeed(feedAddr).updateReserves(tvl);
        // Calculate USD value
        usdValue = tvl * getAssetPrice(asset) / LendefiConstants.WAD;
    }

    /**
     * @notice Get the oracle address for a specific asset and oracle type
     * @param asset The asset address
     * @param oracleType The oracle type to retrieve
     * @return The oracle address for the specified type, or address(0) if none exists
     */
    function getOracleByType(address asset, OracleType oracleType) external view returns (address) {
        if (oracleType == OracleType.UNISWAP_V3_TWAP) {
            return assetInfo[asset].poolConfig.pool;
        }

        return assetInfo[asset].chainlinkConfig.oracleUSD;
    }

    /**
     * @notice Get the price from a specific oracle type for an asset
     * @param asset The asset to get price for
     * @param oracleType The specific oracle type to query
     * @return The price from the specified oracle type
     */
    function getAssetPriceByType(address asset, OracleType oracleType)
        external
        view
        onlyListedAsset(asset)
        returns (uint256)
    {
        if (circuitBroken[asset]) {
            revert CircuitBreakerActive(asset);
        }

        if (oracleType == OracleType.UNISWAP_V3_TWAP) {
            return _getUniswapTWAPPrice(asset);
        }

        return _getChainlinkPrice(asset);
    }
    /**
     * @notice Returns the remaining time before a scheduled upgrade can be executed
     * @dev Returns 0 if no upgrade is scheduled or if the timelock has expired
     * @return timeRemaining The time remaining in seconds
     */

    function upgradeTimelockRemaining() external view returns (uint256) {
        return pendingUpgrade.exists
            && block.timestamp < pendingUpgrade.scheduledTime + LendefiConstants.UPGRADE_TIMELOCK_DURATION
            ? pendingUpgrade.scheduledTime + LendefiConstants.UPGRADE_TIMELOCK_DURATION - block.timestamp
            : 0;
    }

    /**
     * @notice Retrieves detailed information about an asset
     * @dev Combines multiple data points into a single view call
     * @param asset The address of the asset to query
     * @return price Current oracle price of the asset
     * @return totalSupplied Total amount of asset supplied to protocol
     * @return maxSupply Maximum supply threshold for the asset
     * @return tier Collateral tier classification
     * @custom:validation Asset must be listed
     */
    function getAssetDetails(address asset)
        external
        view
        onlyListedAsset(asset)
        returns (uint256 price, uint256 totalSupplied, uint256 maxSupply, CollateralTier tier)
    {
        // Direct storage access instead of copying entire struct
        maxSupply = assetInfo[asset].maxSupplyThreshold;
        tier = assetInfo[asset].tier;

        // Get price (this will revert if circuit breaker is active)
        price = getAssetPrice(asset);

        // Get total supplied from protocol
        totalSupplied = lendefiInstance.assetTVL(asset);
    }

    /**
     * @notice Retrieves rates configuration for all collateral tiers
     * @dev Returns parallel arrays for jump rates and liquidation fees
     * @return jumpRates Array of jump rates for each tier [STABLE, CROSS_A, CROSS_B, ISOLATED]
     * @return liquidationFees Array of liquidation fees for each tier [STABLE, CROSS_A, CROSS_B, ISOLATED]
     */
    function getTierRates() external view returns (uint256[4] memory jumpRates, uint256[4] memory liquidationFees) {
        jumpRates[0] = tierConfig[CollateralTier.STABLE].jumpRate;
        jumpRates[1] = tierConfig[CollateralTier.CROSS_A].jumpRate;
        jumpRates[2] = tierConfig[CollateralTier.CROSS_B].jumpRate;
        jumpRates[3] = tierConfig[CollateralTier.ISOLATED].jumpRate;

        liquidationFees[0] = tierConfig[CollateralTier.STABLE].liquidationFee;
        liquidationFees[1] = tierConfig[CollateralTier.CROSS_A].liquidationFee;
        liquidationFees[2] = tierConfig[CollateralTier.CROSS_B].liquidationFee;
        liquidationFees[3] = tierConfig[CollateralTier.ISOLATED].liquidationFee;
    }

    /**
     * @notice Gets the jump rate for a specific collateral tier
     * @param tier The collateral tier to query
     * @return The jump rate for the specified tier
     */
    function getTierJumpRate(CollateralTier tier) external view returns (uint256) {
        return tierConfig[tier].jumpRate;
    }

    /**
     * @notice Checks if an asset is valid and active in the protocol
     * @param asset The asset address to check
     * @return true if the asset is listed and active, false otherwise
     */
    function isAssetValid(address asset) external view returns (bool) {
        return listedAssets.contains(asset) && assetInfo[asset].active == 1;
    }

    /**
     * @notice Checks if supplying an amount would exceed asset capacity
     * @param asset The asset address to check
     * @param amount The amount to be supplied
     * @return true if supply would exceed maximum threshold
     * @custom:validation Asset must be listed
     */
    function isAssetAtCapacity(address asset, uint256 amount) external view onlyListedAsset(asset) returns (bool) {
        // Check standard supply cap
        if (lendefiInstance.assetTVL(asset) + amount > assetInfo[asset].maxSupplyThreshold) {
            return true;
        }

        return false;
    }

    /**
     * @notice Checks if an amount exceeds pool liquidity limits
     * @dev Only applicable for assets with active Uniswap oracle
     * @param asset The asset address to check
     * @param amount The amount to validate
     * @return limitReached true if amount exceeds 3% of pool liquidity
     */
    function poolLiquidityLimit(address asset, uint256 amount) external view returns (bool limitReached) {
        // Check pool liquidity cap if Uniswap oracle is active
        if (assetInfo[asset].poolConfig.active == 1) {
            address pool = assetInfo[asset].poolConfig.pool;

            // Get the actual token balance in the pool
            uint256 assetBalance = IERC20(asset).balanceOf(pool);

            // If amount is more than 3% of the available assets in pool, revert
            if (amount > (assetBalance * 3) / 100) {
                return true;
            }
        }

        return false;
    }

    /**
     * @notice Retrieves complete configuration for an asset
     * @dev Returns full Asset struct from storage
     * @param asset The address of the asset to query
     * @return Complete Asset struct containing all configuration parameters
     * @custom:validation Asset must be listed in protocol
     */
    function getAssetInfo(address asset) external view onlyListedAsset(asset) returns (Asset memory) {
        return assetInfo[asset];
    }

    /**
     * @notice Retrieves array of all listed asset addresses
     * @dev Converts EnumerableSet to memory array
     * @return Array containing addresses of all listed assets
     * @custom:complexity O(n) where n is number of listed assets
     * @custom:gas-note May be expensive for large numbers of assets
     */
    function getListedAssets() external view returns (address[] memory) {
        return listedAssets.values();
    }

    /**
     * @notice Gets the liquidation fee for a specific collateral tier
     * @param tier The collateral tier to query
     * @return The liquidation fee percentage (scaled by 1e6)
     */
    function getLiquidationFee(CollateralTier tier) external view returns (uint256) {
        return tierConfig[tier].liquidationFee;
    }

    /**
     * @notice Gets the collateral tier assigned to an asset
     * @param asset The asset address to query
     * @return tier The collateral tier classification
     * @custom:validation Asset must be listed
     */
    function getAssetTier(address asset) external view onlyListedAsset(asset) returns (CollateralTier tier) {
        return assetInfo[asset].tier;
    }

    /**
     * @notice Gets the decimal precision of an asset
     * @param asset The asset address to query
     * @return The number of decimals (e.g., 18 for ETH)
     * @custom:validation Asset must be listed
     */
    function getAssetDecimals(address asset) external view onlyListedAsset(asset) returns (uint8) {
        return assetInfo[asset].decimals;
    }

    /**
     * @notice Gets the liquidation threshold for an asset
     * @param asset The asset address to query
     * @return The liquidation threshold percentage (scaled by 1e4)
     * @custom:validation Asset must be listed
     */
    function getAssetLiquidationThreshold(address asset) external view onlyListedAsset(asset) returns (uint16) {
        return assetInfo[asset].liquidationThreshold;
    }

    /**
     * @notice Gets the borrow threshold for an asset
     * @param asset The asset address to query
     * @return The borrow threshold percentage (scaled by 1e4)
     * @custom:validation Asset must be listed
     */
    function getAssetBorrowThreshold(address asset) external view onlyListedAsset(asset) returns (uint16) {
        return assetInfo[asset].borrowThreshold;
    }

    /**
     * @notice Gets the maximum allowed debt for an isolated asset
     * @param asset The asset address to query
     * @return The maximum debt cap in asset's native units
     * @custom:validation Asset must be listed
     */
    function getIsolationDebtCap(address asset) external view onlyListedAsset(asset) returns (uint256) {
        return assetInfo[asset].isolationDebtCap;
    }

    /**
     * @notice Gets all parameters needed for collateral calculations in a single call
     * @dev Consolidates multiple getter calls into a single cross-contract call
     * @param asset Address of the asset to query
     * @return Struct containing price, thresholds and decimals
     */
    function getAssetCalculationParams(address asset)
        external
        view
        onlyListedAsset(asset)
        returns (AssetCalculationParams memory)
    {
        return AssetCalculationParams({
            price: getAssetPrice(asset),
            borrowThreshold: assetInfo[asset].borrowThreshold,
            liquidationThreshold: assetInfo[asset].liquidationThreshold,
            decimals: assetInfo[asset].decimals
        });
    }

    /**
     * @notice Gets the number of active oracles for an asset
     * @dev Returns sum of active Chainlink and Uniswap oracles (0-2)
     * @param asset The asset address to check
     * @return The total number of active oracle price feeds
     * @custom:oracle-config Sum of chainlinkConfig.active and poolConfig.active
     */
    function getOracleCount(address asset) external view returns (uint256) {
        return assetInfo[asset].chainlinkConfig.active + assetInfo[asset].poolConfig.active;
    }

    /**
     * @notice Gets the Proof of Reserve feed for an asset
     * @param asset The asset address
     * @return The feed address or address(0) if none exists
     */
    function getPoRFeed(address asset) external view onlyListedAsset(asset) returns (address) {
        return assetInfo[asset].porFeed;
    }

    /**
     * @notice Register a Uniswap V3 pool as an oracle for an asset
     * @param asset The asset to register the oracle for
     * @param uniswapPool The Uniswap V3 pool address
     * @param twapPeriod The TWAP period in seconds (15min-24h)
     * @param active isActive flag (0 or 1)
     * @custom:validation Validates through _validateAssetConfig
     * @custom:validation Performed by _validatePool function
     */
    function updateUniswapOracle(address asset, address uniswapPool, uint32 twapPeriod, uint8 active)
        public
        nonZeroAddress(uniswapPool)
        onlyListedAsset(asset)
        onlyRole(LendefiConstants.MANAGER_ROLE)
        whenNotPaused
    {
        // Validate TWAP period and pool configuration first
        _validatePool(asset, uniswapPool, twapPeriod, active);

        // Update Uniswap configuration
        assetInfo[asset].poolConfig = UniswapPoolConfig({pool: uniswapPool, twapPeriod: twapPeriod, active: active});

        // Create a memory copy of the asset configuration to validate
        Asset memory configCopy = assetInfo[asset];

        // Validate the updated configuration using the memory copy
        _validateAssetConfig(asset, configCopy);

        // Emit event to log the update
        emit UniswapOracleUpdated(asset, uniswapPool, active);
    }

    /**
     * @notice Get asset price as a view function (no state changes)
     * @param asset The asset to get price for
     * @return price The current price of the asset
     */
    function getAssetPrice(address asset) public view onlyListedAsset(asset) returns (uint256) {
        if (circuitBroken[asset]) {
            revert CircuitBreakerActive(asset);
        }

        // Load into memory once
        Asset storage info = assetInfo[asset];
        uint8 chainlinkActive = info.chainlinkConfig.active;
        uint8 uniswapActive = info.poolConfig.active;

        // Early returns for single oracle
        if (chainlinkActive == 1 && uniswapActive == 0) {
            return _getChainlinkPrice(asset);
        }
        if (uniswapActive == 1 && chainlinkActive == 0) {
            return _getUniswapTWAPPrice(asset);
        }

        // Dual-oracle case (implicitly totalActive == 2)
        uint256 price1 = _getChainlinkPrice(asset);
        uint256 price2 = _getUniswapTWAPPrice(asset);
        uint256 median = (price1 + price2) >> 1; // Bit shift instead of division

        return median;
    }

    /**
     * @notice Checks for price deviation between Chainlink and Uniswap oracles
     * @dev Requires both oracles to be active. Calculates percentage deviation between prices.
     * @param asset The address of the asset to check price deviation for
     * @return isDeviated True if deviation exceeds circuit breaker threshold
     * @return deviation The calculated percentage deviation between oracle prices (0-100+)
     * @custom:reverts NotEnoughValidOracles if both oracles aren't active
     * @custom:calculation (abs(price1 - price2) * 100) / min(price1, price2)
     * @custom:example If Chainlink reports $1000 and Uniswap reports $1200:
     *                 deviation = (200 * 100) / 1000 = 20%
     */
    function checkPriceDeviation(address asset) public view returns (bool isDeviated, uint256 deviation) {
        // Load asset info into memory once

        uint8 chainlinkActive = assetInfo[asset].chainlinkConfig.active;
        uint8 uniswapActive = assetInfo[asset].poolConfig.active;

        // Check if both oracles are active (must be 2)
        if (chainlinkActive + uniswapActive != 2) {
            revert NotEnoughValidOracles(asset, 2, chainlinkActive + uniswapActive);
        }

        // Fetch prices
        uint256 price1 = _getChainlinkPrice(asset);
        uint256 price2 = _getUniswapTWAPPrice(asset);

        // Calculate deviation
        uint256 minPrice = price1 < price2 ? price1 : price2;
        uint256 maxPrice = price1 > price2 ? price1 : price2;
        uint256 priceDelta = maxPrice - minPrice;

        deviation = FullMath.mulDiv(priceDelta, 100, minPrice);

        // Compare with circuit breaker threshold
        return (deviation >= mainOracleConfig.circuitBreakerThreshold, deviation);
    }

    // ==================== INTERNAL FUNCTIONS ====================

    /**
     * @notice Initializes default parameters for all collateral tiers
     * @dev Called once during contract initialization
     * @custom:rates Sets the following default rates:
     * - STABLE: 5% jump rate, 1% liquidation fee
     * - CROSS_A: 8% jump rate, 2% liquidation fee
     * - CROSS_B: 12% jump rate, 3% liquidation fee
     * - ISOLATED: 15% jump rate, 4% liquidation fee
     * @custom:security All rates are scaled by 1e6 (100% = 1e6)
     */
    function _initializeDefaultTierParameters() internal {
        tierConfig[CollateralTier.STABLE] = TierRates({
            jumpRate: 0.05e6, // 5%
            liquidationFee: 0.01e6 // 1%
        });

        tierConfig[CollateralTier.CROSS_A] = TierRates({
            jumpRate: 0.08e6, // 8%
            liquidationFee: 0.02e6 // 2%
        });

        tierConfig[CollateralTier.CROSS_B] = TierRates({
            jumpRate: 0.12e6, // 12%
            liquidationFee: 0.03e6 // 3%
        });

        tierConfig[CollateralTier.ISOLATED] = TierRates({
            jumpRate: 0.15e6, // 15%
            liquidationFee: 0.04e6 // 4%
        });
    }

    /**
     * @notice Validates and authorizes contract upgrades
     * @dev Internal function required by UUPSUpgradeable pattern
     * @param newImplementation Address of the new implementation contract
     * @custom:security Enforces timelock and validates implementation address
     * @custom:access Restricted to LendefiConstants.UPGRADER_ROLE
     * @custom:validation Requires:
     * - Upgrade must be scheduled
     * - Implementation must match scheduled upgrade
     * - Timelock duration must have elapsed
     * @custom:emits Upgrade event on successful authorization
     * @custom:state-changes Increments version and clears pending upgrade
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(LendefiConstants.UPGRADER_ROLE) {
        if (!pendingUpgrade.exists) revert UpgradeNotScheduled();
        if (pendingUpgrade.implementation != newImplementation) {
            revert ImplementationMismatch(pendingUpgrade.implementation, newImplementation);
        }
        if (block.timestamp - pendingUpgrade.scheduledTime < LendefiConstants.UPGRADE_TIMELOCK_DURATION) {
            revert UpgradeTimelockActive(
                LendefiConstants.UPGRADE_TIMELOCK_DURATION - (block.timestamp - pendingUpgrade.scheduledTime)
            );
        }

        delete pendingUpgrade;

        ++version;
        emit Upgrade(msg.sender, newImplementation);
    }

    /**
     * @notice Get price from Chainlink oracle with volatility checks
     * @param asset The asset address
     * @return The price with normalized decimals (1e6)
     */
    function _getChainlinkPrice(address asset) internal view returns (uint256) {
        address oracle = assetInfo[asset].chainlinkConfig.oracleUSD;
        (uint80 roundId, int256 price,, uint256 timestamp, uint80 answeredInRound) =
            AggregatorV3Interface(oracle).latestRoundData();

        // Validate price is positive
        if (price <= 0) {
            revert OracleInvalidPrice(oracle, price);
        }

        // Validate round data is not stale
        if (answeredInRound < roundId) {
            revert OracleStalePrice(oracle, roundId, answeredInRound);
        }

        // Validate timestamp is fresh enough
        uint256 age = block.timestamp - timestamp;
        if (age > mainOracleConfig.freshnessThreshold) {
            revert OracleTimeout(oracle, timestamp, block.timestamp, mainOracleConfig.freshnessThreshold);
        }

        // Check for excessive volatility using the new helper function
        uint256 changePercent = _getChainlinkVolatility(asset);
        if (changePercent >= mainOracleConfig.volatilityPercentage && age >= mainOracleConfig.volatilityThreshold) {
            revert OracleInvalidPriceVolatility(oracle, price, changePercent);
        }

        return uint256(price) / 1e2; // Normalize to 1e6 to match Uniswap
    }

    /**
     * @notice Retrieves the Time-Weighted Average Price (TWAP) of an asset in USD using Uniswap V3
     * @dev Validates the Uniswap pool configuration and fetches the price using the TWAP period
     * @param asset The address of the asset to fetch the price for
     * @return tokenPriceInUSD The price of the asset in USD (scaled to 1e6)
     * @custom:oracle Uses Uniswap V3 TWAP oracle
     * @custom:reverts InvalidUniswapConfig if the pool is not configured or inactive
     * @custom:reverts OracleInvalidPrice if the price is invalid or zero
     */
    function _getUniswapTWAPPrice(address asset) internal view returns (uint256 tokenPriceInUSD) {
        UniswapPoolConfig memory config = assetInfo[asset].poolConfig;
        if (config.pool == address(0) || config.active == 0) {
            revert InvalidUniswapConfig(asset);
        }

        tokenPriceInUSD =
            getAnyPoolTokenPriceInUSD(config.pool, asset, LendefiConstants.USDC_ETH_POOL, config.twapPeriod); // Price on 1e6 scale, USDC

        if (tokenPriceInUSD <= 0) {
            revert OracleInvalidPrice(config.pool, int256(tokenPriceInUSD));
        }
    }

    /**
     * @notice Retrieves the USD price of any token from a Uniswap V3 pool using TWAP
     * @dev Supports both direct USDC pairs and indirect ETH-denominated pairs
     * @param poolAddress Address of the Uniswap V3 pool to query
     * @param token Address of the token to get the price for
     * @param ethUsdcPool Address of the ETH/USDC pool used for ETH-denominated price conversion
     * @param twapPeriod Time period in seconds for the TWAP calculation (900-1800)
     * @return tokenPriceInUSD Price in USD normalized to 1e6 precision
     * @custom:oracle-path For direct USDC pairs:
     *   - Fetches token/USDC price directly from pool
     *   - Normalizes to 1e6 precision based on token decimals
     * @custom:oracle-path For ETH pairs:
     *   - Gets token/ETH price from pool
     *   - Gets ETH/USDC price from reference pool
     *   - Combines prices with proper decimal handling
     * @custom:decimals Input token can have any decimal precision (1-18)
     *   - Output is always normalized to 1e6 (USDC precision)
     *   - Internal calculations handle decimal conversion
     * @custom:validation Performs the following checks:
     *   - Token must be present in the specified pool
     *   - Resulting price must be greater than zero
     *   - Pool must be properly configured
     * @custom:security Features:
     *   - Uses TWAP for manipulation resistance
     *   - Handles decimal normalization safely
     *   - Validates pool configuration
     * @custom:reverts OracleInvalidPrice - If calculated price is zero or invalid
     * @custom:reverts AssetNotInUniswapPool - If token not found in pool
     * @custom:example For a token with 18 decimals in a token/USDC pool:
     *   - Raw pool price: 1200.123456 (token/USDC)
     *   - Returned price: 1200123456 (1200.123456 * 1e6)
     * @custom:example For a token with 18 decimals in a token/ETH pool:
     *   - Raw pool price: 0.5 ETH per token
     *   - ETH/USDC price: 2000.00 USD per ETH
     *   - Returned price: 1000000000 (1000.00 * 1e6)
     */
    function getAnyPoolTokenPriceInUSD(address poolAddress, address token, address ethUsdcPool, uint32 twapPeriod)
        internal
        view
        returns (uint256 tokenPriceInUSD)
    {
        // Get the pool instance
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);

        // Phase 1: Get pool configuration
        (bool isToken0, uint8 assetDecimals, bool isUsdcPool) = getOptimalUniswapConfig(token, pool);

        // Phase 2: Get raw price
        if (isUsdcPool) {
            tokenPriceInUSD = UniswapTickMath.getRawPrice(pool, isToken0, 10 ** assetDecimals, twapPeriod);
        } else {
            // Get raw price in ETH
            uint256 rawPrice = UniswapTickMath.getRawPrice(pool, isToken0, 10 ** assetDecimals, twapPeriod);

            IUniswapV3Pool ethUSDCPool = IUniswapV3Pool(ethUsdcPool);
            // ETH is token1 in USDC/ETH pool
            uint256 ethPriceInUSD = UniswapTickMath.getRawPrice(ethUSDCPool, false, 1e18, twapPeriod);

            // Adjust token/ETH price to account for token decimals
            uint256 adjustedPrice = rawPrice / (10 ** (18 - assetDecimals)); // Scale to 1e6 precision

            // Dynamically normalize the final price based on token decimals
            uint256 normalizationFactor = 10 ** assetDecimals;
            tokenPriceInUSD = FullMath.mulDiv(adjustedPrice, ethPriceInUSD, normalizationFactor);
        }
    }

    /**
     * @notice Determines the optimal configuration for a Uniswap V3 pool
     * @dev Identifies token positions, decimals, and pool type for accurate price calculations
     * @param asset The address of the asset to configure
     * @param pool The Uniswap V3 pool instance
     * @return isToken0 True if the asset is token0 in the pool, false if token1
     * @return assetDecimals The number of decimal places for the asset (e.g., 18 for ETH)
     * @return isUsdcPool True if the pool directly pairs with USDC, false otherwise
     * @custom:validation Ensures the asset is part of the pool, reverts otherwise
     * @custom:pricing-impact Token position affects price calculation direction (token0/token1 vs token1/token0)
     * @custom:reverts AssetNotInUniswapPool if the asset is not present in the pool
     */
    function getOptimalUniswapConfig(address asset, IUniswapV3Pool pool)
        internal
        view
        returns (bool isToken0, uint8 assetDecimals, bool isUsdcPool)
    {
        // Get pool tokens
        address token0 = pool.token0();
        address token1 = pool.token1();

        // Verify the asset is in the pool
        if (asset != token0 && asset != token1) revert AssetNotInUniswapPool(asset, address(pool));

        // Determine if asset is token0
        isToken0 = (asset == token0);

        // Check if the pool is USDC-based
        isUsdcPool = (token0 == usdc || token1 == usdc);
        assetDecimals = IERC20Metadata(asset).decimals();
    }

    /**
     * @notice Validates a Uniswap V3 pool configuration for an asset
     * @dev Performs comprehensive validation to ensure safe and reliable oracle configuration
     * @param asset The asset token address to validate
     * @param uniswapPool The Uniswap V3 pool address
     * @param twapPeriod The TWAP period in seconds (must be 15min-24h)
     * @param active Whether the oracle should be active (must be 0 or 1)
     * @custom:validation Performs the following checks:
     * - Asset must be present in the Uniswap pool (token0 or token1)
     * - TWAP period must be between 15 minutes and 24 hours for optimal security
     * - Active parameter must be valid (0=inactive or 1=active)
     * - If deactivating, ensures minimum oracle requirements are still met
     * @custom:security Prevents configuration of invalid pools or unsafe TWAP periods
     * @custom:reverts AssetNotInUniswapPool if asset is not in the pool
     * @custom:reverts InvalidThreshold if TWAP period is outside allowed range
     * @custom:reverts InvalidParameter if active parameter is not 0 or 1
     * @custom:reverts NotEnoughValidOracles if deactivation would violate minimum oracle requirement
     */
    function _validatePool(address asset, address uniswapPool, uint32 twapPeriod, uint8 active) internal view {
        // Validate that the asset is in the pool
        IUniswapV3Pool pool = IUniswapV3Pool(uniswapPool);
        address token0 = pool.token0();
        address token1 = pool.token1();

        if (asset != token0 && asset != token1) {
            revert AssetNotInUniswapPool(asset, uniswapPool);
        }

        // Validate TWAP period (between 15 minutes and 30 minutes)
        if (twapPeriod < 900 || twapPeriod > 1800) {
            revert InvalidThreshold("twapPeriod", twapPeriod, 900, 1800);
        }

        // Validate active parameter (must be 0 or 1)
        if (active > 1) {
            revert InvalidParameter("active", active);
        }

        // Check minimum oracle requirements if we're deactivating this oracle
        if (active == 0 && assetInfo[asset].chainlinkConfig.active == 0 && assetInfo[asset].assetMinimumOracles >= 1) {
            revert NotEnoughValidOracles(asset, assetInfo[asset].assetMinimumOracles, 0);
        }
    }

    /**
     * @notice Calculates price volatility between current and previous Chainlink oracle rounds
     * @dev Compares the current price with the previous round price to detect significant changes
     * @param asset The asset address to check volatility for
     * @return volatilityPct The percentage change between current and previous price (0-100+)
     * @custom:returns 0 if previous round data is invalid or unavailable
     * @custom:calculation (abs(currentPrice - previousPrice) * 100) / previousPrice
     * @custom:security Used to detect abnormal price movements in Chainlink feeds
     * @custom:example If current price is $1200 and previous was $1000:
     *                 volatilityPct = (|1200 - 1000| * 100) / 1000 = 20%
     */
    function _getChainlinkVolatility(address asset) internal view returns (uint256) {
        address oracle = assetInfo[asset].chainlinkConfig.oracleUSD;
        (uint80 roundId, int256 price,,,) = AggregatorV3Interface(oracle).latestRoundData();
        if (roundId <= 1) return 0;
        (, int256 previousPrice,, uint256 previousTimestamp,) = AggregatorV3Interface(oracle).getRoundData(roundId - 1);
        if (previousPrice <= 0 || previousTimestamp == 0) return 0;
        uint256 priceDelta = uint256(price > previousPrice ? price - previousPrice : previousPrice - price);
        return FullMath.mulDiv(priceDelta, 100, uint256(previousPrice));
    }

    /**
     * @notice Validates asset configuration parameters
     * @dev Centralized validation logic for all asset configurations
     * @param asset The address of the asset being configured
     * @param config The complete asset configuration to validate
     * @custom:validation Performs comprehensive checks including:
     * - Oracle address validity (non-zero)
     * - Oracle activity flags validity (0 or 1)
     * - Minimum oracle requirement satisfaction
     * - Primary oracle type activation
     * - Threshold values (liquidation threshold ≤ 990)
     * - Threshold ordering (borrow threshold ≤ liquidation threshold - 10)
     * - Decimal precision (1-18)
     * - Activity flag validity (0 or 1)
     * - Supply limit validity (non-zero)
     * - Isolation debt cap for isolated assets (non-zero)
     * @custom:security Guards against misconfiguration that could lead to:
     * - Unreliable price data
     * - Unsafe collateralization ratios
     * - Economic attacks on the lending protocol
     * @custom:reverts Multiple error types based on the specific validation failure
     */
    function _validateAssetConfig(address asset, Asset memory config) internal pure {
        // Basic validation
        if (config.chainlinkConfig.oracleUSD == address(0)) revert ZeroAddressNotAllowed();
        // Validate active parameter (must be 0 or 1)
        if (config.chainlinkConfig.active > 1) {
            revert InvalidParameter("chainlink active", config.chainlinkConfig.active);
        }

        if (config.chainlinkConfig.active + config.poolConfig.active < config.assetMinimumOracles) {
            revert NotEnoughValidOracles(
                asset, config.assetMinimumOracles, config.chainlinkConfig.active + config.poolConfig.active
            );
        }

        // Validate that the primary oracle type is active
        bool isPrimaryOracleActive = false;

        if (config.primaryOracleType == OracleType.CHAINLINK) {
            isPrimaryOracleActive = config.chainlinkConfig.active == 1;
        } else if (config.primaryOracleType == OracleType.UNISWAP_V3_TWAP) {
            isPrimaryOracleActive = config.poolConfig.active == 1;
        }

        if (!isPrimaryOracleActive) {
            revert OracleNotActive(asset, config.primaryOracleType);
        }

        // Threshold validations
        if (config.liquidationThreshold > LendefiConstants.MAX_LIQUIDATION_THRESHOLD) {
            revert InvalidLiquidationThreshold(config.liquidationThreshold);
        }

        if (config.borrowThreshold > config.liquidationThreshold - LendefiConstants.MIN_THRESHOLD_SPREAD) {
            revert InvalidBorrowThreshold(config.borrowThreshold);
        }

        if (config.decimals == 0 || config.decimals > 18) {
            revert InvalidParameter("assetDecimals", config.decimals);
        }

        // Activity check
        if (config.active > 1) {
            revert InvalidParameter("active", config.active);
        }

        // Supply limit validation
        if (config.maxSupplyThreshold == 0) {
            revert InvalidParameter("maxSupplyThreshold", 0);
        }

        // For isolated assets, check debt cap
        if (config.tier == CollateralTier.ISOLATED && config.isolationDebtCap == 0) {
            revert InvalidParameter("isolationDebtCap", 0);
        }
    }
}
