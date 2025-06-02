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
 * @title Lendefi Market Factory
 * @author alexei@nebula-labs(dot)xyz
 * @notice Factory contract for creating and managing LendefiCore + ERC4626 vault pairs for different base assets
 *         with multi-tenant support where each market owner can create isolated markets
 * @dev Creates composable lending markets where each market owner can deploy their own isolated lending market
 *      for any base asset. Uses OpenZeppelin's clone factory pattern for gas-efficient deployment.
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */

import {LendefiCore} from "./LendefiCore.sol";
import {LendefiMarketVault} from "./LendefiMarketVault.sol";
import {IPROTOCOL} from "../interfaces/IProtocol.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoRFeed} from "../interfaces/IPoRFeed.sol";
import {IASSETS} from "../interfaces/IASSETS.sol";
import {LendefiConstants} from "./lib/LendefiConstants.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @custom:oz-upgrades
contract LendefiMarketFactory is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using Clones for address;
    using LendefiConstants for *;

    /**
     * @notice Information about a scheduled contract upgrade
     */
    struct UpgradeRequest {
        address implementation;
        uint64 scheduledTime;
        bool exists;
    }

    // ========== ROLES ==========

    /// @notice Role identifier for addresses that can create new markets
    bytes32 public constant MARKET_OWNER_ROLE = keccak256("MARKET_OWNER_ROLE");

    // ========== STATE VARIABLES ==========

    /// @notice Version of the factory contract
    uint256 public version;

    /// @notice Implementation contract address for LendefiCore instances
    /// @dev Used as template for cloning new core contracts for each market
    address public coreImplementation;

    /// @notice Implementation contract address for LendefiMarketVault instances
    /// @dev Used as template for cloning new vault contracts for each market
    address public vaultImplementation;

    /// @notice Implementation contract address for user position vault instances
    /// @dev Used by core contracts to create individual user position vaults
    address public positionVaultImplementation;

    /// @notice Implementation contract address for LendefiAssets instances
    /// @dev Used as template for cloning new assets module contracts for each market
    address public assetsModuleImplementation;

    /// @notice Address of the Proof of Reserves feed implementation
    /// @dev Template for creating PoR feeds for each market to track reserves
    address public porFeedImplementation;

    /// @notice Address of the protocol governance token
    /// @dev Used for liquidator threshold requirements and rewards distribution
    address public govToken;

    /// @notice Address of the timelock contract for administrative operations
    /// @dev Has admin privileges across all created markets for governance operations
    address public timelock;

    /// @notice Address of the multisig wallet for administrative operations
    /// @dev Has admin privileges across all created markets for governance operations
    address public multisig;

    /// @notice Address of the ecosystem contract for reward distribution
    /// @dev Handles governance token rewards for liquidity providers
    address public ecosystem;

    /// @notice Nested mapping of market owner to base asset to market configuration
    /// @dev First key: market owner address, Second key: base asset address, Value: Market struct
    mapping(address => mapping(address => IPROTOCOL.Market)) public markets;

    /// @notice Mapping to track all base assets for each market owner
    /// @dev Key: market owner address, Value: array of base asset addresses they've created markets for
    mapping(address => address[]) public ownerBaseAssets;

    /// @notice Array of all market owners who have created markets
    /// @dev Used for enumeration and iteration over all market owners
    address[] public allMarketOwners;

    /// @notice Array of all market configurations created by this factory
    /// @dev Provides direct access to all market data across all owners
    IPROTOCOL.Market[] public allMarkets;

    /// @dev Pending upgrade information
    UpgradeRequest public pendingUpgrade;

    // Storage gap reduced to account for new variables
    uint256[14] private __gap;

    // ========== EVENTS ==========

    /**
     * @notice Emitted when a new lending market is successfully created
     * @param marketOwner The address that owns this market instance
     * @param baseAsset The base asset address for the new market
     * @param core The deployed LendefiCore contract address for this market
     * @param baseVault The deployed LendefiMarketVault contract address for this market
     * @param name The name of the ERC20 yield token for this market
     * @param symbol The symbol of the ERC20 yield token for this market
     * @param porFeed The deployed Proof of Reserves feed address for this market
     */
    event MarketCreated(
        address indexed marketOwner,
        address indexed baseAsset,
        address core,
        address baseVault,
        string name,
        string symbol,
        address porFeed
    );

    /**
     * @notice Emitted when market information is updated
     * @param marketOwner The address that owns the market being updated
     * @param baseAsset The base asset address of the updated market
     * @param marketInfo The updated market configuration data
     */
    event MarketUpdated(address indexed marketOwner, address indexed baseAsset, IPROTOCOL.Market marketInfo);

    /**
     * @notice Emitted when a market is removed or deactivated
     * @param marketOwner The address that owns the market being removed
     * @param baseAsset The base asset address of the removed market
     */
    event MarketRemoved(address indexed marketOwner, address indexed baseAsset);

    /**
     * @notice Emitted when implementation contracts are updated by admin
     * @param coreImplementation The new core implementation contract address
     * @param vaultImplementation The new vault implementation contract address
     * @param positionVaultImplementation The new position vault implementation contract address
     */
    event ImplementationsSet(
        address indexed coreImplementation,
        address indexed vaultImplementation,
        address indexed positionVaultImplementation
    );

    /**
     * @notice Emitted when implementation contract is upgraded
     * @param admin Address of the admin who performed the upgrade
     * @param implementation Address of the new implementation
     */
    event Upgrade(address indexed admin, address indexed implementation);

    /// @notice Emitted when an upgrade is scheduled
    /// @param scheduler The address scheduling the upgrade
    /// @param implementation The new implementation contract address
    /// @param scheduledTime The timestamp when the upgrade was scheduled
    /// @param effectiveTime The timestamp when the upgrade can be executed
    event UpgradeScheduled(
        address indexed scheduler, address indexed implementation, uint64 scheduledTime, uint64 effectiveTime
    );

    /// @notice Emitted when a scheduled upgrade is cancelled
    /// @param canceller The address that cancelled the upgrade
    /// @param implementation The implementation address that was cancelled
    event UpgradeCancelled(address indexed canceller, address indexed implementation);

    // ========== ERRORS ==========

    /// @notice Thrown when attempting to create a market for an owner/asset pair that already exists
    error MarketAlreadyExists();

    /// @notice Thrown when a required address parameter is the zero address
    error ZeroAddress();

    /// @notice Thrown when trying to access a market that doesn't exist
    error MarketNotFound();

    /// @notice Thrown when clone deployment fails during market creation
    error CloneDeploymentFailed();

    /// @notice Thrown when an invalid contract address is provided
    error InvalidContract();

    /// @notice Thrown when attempting to execute an upgrade before timelock expires
    /// @param timeRemaining The time remaining until the upgrade can be executed
    error UpgradeTimelockActive(uint256 timeRemaining);

    /// @notice Thrown when attempting to execute an upgrade that wasn't scheduled
    error UpgradeNotScheduled();

    /// @notice Thrown when implementation address doesn't match scheduled upgrade
    /// @param scheduledImpl The address that was scheduled for upgrade
    /// @param attemptedImpl The address that was attempted to be used
    error ImplementationMismatch(address scheduledImpl, address attemptedImpl);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ========== INITIALIZATION ==========

    /**
     * @notice Initializes the factory contract with essential protocol addresses
     * @dev Sets up the factory with all required contract addresses and grants admin role to timelock.
     *      This function can only be called once due to the initializer modifier.
     * @param _timelock Address of the timelock contract that will have admin privileges
     * @param _govToken Address of the protocol governance token
     * @param _multisig Address of the Proof of Reserves feed implementation
     * @param _ecosystem Address of the ecosystem contract for rewards
     *
     * @custom:requirements
     *   - All address parameters must be non-zero
     *   - Function can only be called once during deployment
     *
     * @custom:state-changes
     *   - Initializes AccessControl and UUPS upgradeable functionality
     *   - Grants DEFAULT_ADMIN_ROLE to the timelock address
     *   - Sets all protocol address state variables
     *
     * @custom:access-control Only callable during contract initialization
     * @custom:error-cases
     *   - ZeroAddress: When any required address parameter is zero
     */
    function initialize(address _timelock, address _govToken, address _multisig, address _ecosystem)
        external
        initializer
    {
        if (_timelock == address(0) || _govToken == address(0) || _multisig == address(0) || _ecosystem == address(0)) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _timelock);
        _grantRole(LendefiConstants.UPGRADER_ROLE, _timelock);

        govToken = _govToken;
        timelock = _timelock;
        multisig = _multisig;
        ecosystem = _ecosystem;
        version = 1;
    }

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Sets the implementation contract addresses used for cloning new markets
     * @dev Updates the template contracts that will be cloned when creating new markets.
     *      These implementations must be properly initialized and tested before setting.
     * @param _coreImplementation Address of the LendefiCore implementation contract
     * @param _vaultImplementation Address of the LendefiMarketVault implementation contract
     * @param _positionVaultImplementation Address of the position vault implementation contract
     *
     * @custom:requirements
     *   - All implementation addresses must be non-zero
     *   - Caller must have DEFAULT_ADMIN_ROLE
     *
     * @custom:state-changes
     *   - Updates coreImplementation state variable
     *   - Updates vaultImplementation state variable
     *   - Updates positionVaultImplementation state variable
     *
     * @custom:emits ImplementationsSet event with the new implementation addresses
     * @custom:access-control Restricted to DEFAULT_ADMIN_ROLE
     * @custom:error-cases
     *   - ZeroAddress: When any implementation address is zero
     */
    function setImplementations(
        address _coreImplementation,
        address _vaultImplementation,
        address _positionVaultImplementation,
        address _assetsModuleImplementation,
        address _PoRFeed
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (
            _coreImplementation == address(0) || _vaultImplementation == address(0)
                || _positionVaultImplementation == address(0) || _assetsModuleImplementation == address(0)
                || _PoRFeed == address(0)
        ) revert ZeroAddress();

        coreImplementation = _coreImplementation;
        vaultImplementation = _vaultImplementation;
        positionVaultImplementation = _positionVaultImplementation;
        assetsModuleImplementation = _assetsModuleImplementation;
        porFeedImplementation = _PoRFeed;

        emit ImplementationsSet(_coreImplementation, _vaultImplementation, _positionVaultImplementation);
    }

    // ========== MARKET MANAGEMENT ==========

    /**
     * @notice Creates a new lending market for the caller and specified base asset
     * @dev Deploys a complete lending market infrastructure including:
     *      1. LendefiCore contract (cloned from implementation)
     *      2. LendefiMarketVault contract (cloned from implementation)
     *      3. Proof of Reserves feed (cloned from implementation)
     *      4. Proper initialization and cross-contract linking
     *
     *      Each market owner can create their own isolated lending markets where each base asset
     *      operates independently with its own liquidity pools and risk parameters.
     *      The caller (msg.sender) becomes the market owner.
     *
     * @param baseAsset The ERC20 token address that will serve as the base asset for lending
     * @param name The name for the ERC4626 yield token (e.g., "Lendefi USDC Yield Token")
     * @param symbol The symbol for the ERC4626 yield token (e.g., "lendUSDC")
     *
     * @custom:requirements
     *   - baseAsset must be a valid ERC20 token address (non-zero)
     *   - Market for this caller/baseAsset pair must not already exist
     *   - Implementation contracts must be set before calling this function
     *   - Caller must have MARKET_OWNER_ROLE
     *
     * @custom:state-changes
     *   - Creates new market entry in nested markets mapping
     *   - Adds baseAsset to ownerBaseAssets mapping for the caller
     *   - Adds caller to allMarketOwners array (if first market)
     *   - Adds market info to allMarkets array
     *   - Deploys multiple new contract instances
     *
     * @custom:emits MarketCreated event with all deployed contract addresses
     * @custom:access-control Restricted to MARKET_OWNER_ROLE
     * @custom:error-cases
     *   - ZeroAddress: When baseAsset is the zero address
     *   - MarketAlreadyExists: When market for this caller/asset pair already exists
     *   - CloneDeploymentFailed: When any contract clone deployment fails
     */
    function createMarket(address baseAsset, string memory name, string memory symbol)
        external
        onlyRole(MARKET_OWNER_ROLE)
    {
        address marketOwner = msg.sender;
        if (baseAsset == address(0)) revert ZeroAddress();
        if (markets[marketOwner][baseAsset].core != address(0)) revert MarketAlreadyExists();

        // Deploy core and vault contracts
        (address coreProxy, address vaultProxy, address assetsModule) = _deployContracts(baseAsset, name, symbol);

        // Deploy and initialize PoR feed
        address porFeedClone = _deployPoRFeed(baseAsset);

        // Create and store market configuration
        _storeMarket(marketOwner, baseAsset, coreProxy, vaultProxy, porFeedClone, assetsModule, name, symbol);

        // Initialize the core contract with market information
        LendefiCore(payable(coreProxy)).initializeMarket(markets[marketOwner][baseAsset]);

        emit MarketCreated(marketOwner, baseAsset, coreProxy, vaultProxy, name, symbol, porFeedClone);
    }

    /**
     * @dev Internal function to deploy core and vault contracts
     */
    function _deployContracts(address baseAsset, string memory name, string memory symbol)
        internal
        returns (address coreProxy, address vaultProxy, address assetsModule)
    {
        // Clone assets module for this market
        assetsModule = assetsModuleImplementation.clone();
        if (assetsModule == address(0) || assetsModule.code.length == 0) revert CloneDeploymentFailed();

        // Initialize the cloned assets module
        // Note: Using timelock for both admin and multisig roles
        // Using the porFeed implementation as template (assets module will clone it for each asset)
        IASSETS(assetsModule).initialize(timelock, multisig, baseAsset, porFeedImplementation);

        // Create core contract using minimal proxy pattern
        address core = coreImplementation.clone();
        if (core == address(0) || core.code.length == 0) revert CloneDeploymentFailed();

        // Initialize core contract through proxy
        bytes memory initData = abi.encodeWithSelector(
            LendefiCore.initialize.selector, timelock, govToken, assetsModule, positionVaultImplementation
        );
        coreProxy = address(new TransparentUpgradeableProxy(core, timelock, initData));

        // Create vault contract using minimal proxy pattern
        address baseVault = vaultImplementation.clone();
        if (baseVault == address(0) || baseVault.code.length == 0) revert CloneDeploymentFailed();

        // Initialize vault contract through proxy
        bytes memory vaultData = abi.encodeCall(
            LendefiMarketVault.initialize, (timelock, coreProxy, baseAsset, ecosystem, assetsModule, name, symbol)
        );
        vaultProxy = address(new TransparentUpgradeableProxy(baseVault, timelock, vaultData));
    }

    /**
     * @dev Internal function to deploy and initialize PoR feed
     */
    function _deployPoRFeed(address baseAsset) internal returns (address porFeedClone) {
        porFeedClone = porFeedImplementation.clone();
        if (porFeedClone == address(0) || porFeedClone.code.length == 0) revert CloneDeploymentFailed();

        IPoRFeed(porFeedClone).initialize(baseAsset, timelock, timelock);
    }

    /**
     * @dev Internal function to store market configuration
     */
    function _storeMarket(
        address marketOwner,
        address baseAsset,
        address coreProxy,
        address vaultProxy,
        address porFeedClone,
        address assetsModule,
        string memory name,
        string memory symbol
    ) internal {
        // Create market configuration struct
        IPROTOCOL.Market memory marketInfo = IPROTOCOL.Market({
            core: coreProxy,
            baseVault: vaultProxy,
            baseAsset: baseAsset,
            assetsModule: assetsModule,
            porFeed: porFeedClone,
            decimals: IERC20Metadata(baseAsset).decimals(),
            name: name,
            symbol: symbol,
            createdAt: block.timestamp,
            active: true
        });

        // Store market information in nested mapping
        markets[marketOwner][baseAsset] = marketInfo;

        // Track base assets for this owner
        ownerBaseAssets[marketOwner].push(baseAsset);

        // Track unique market owners (only add if this is their first market)
        if (ownerBaseAssets[marketOwner].length == 1) {
            allMarketOwners.push(marketOwner);
        }

        // Add to global markets array
        allMarkets.push(marketInfo);
    }

    /**
     * @notice Schedules an upgrade to a new implementation with timelock
     * @dev Only callable by addresses with LendefiConstants.UPGRADER_ROLE
     * @param newImplementation Address of the new implementation contract
     */
    function scheduleUpgrade(address newImplementation) external onlyRole(LendefiConstants.UPGRADER_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();

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

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Retrieves complete market information for a given market owner and base asset
     * @dev Returns the full Market struct containing all deployed contract addresses
     *      and configuration data for the specified market.
     * @param marketOwner Address of the market owner
     * @param baseAsset Address of the base asset to query market information for
     * @return Market configuration struct containing all market data
     *
     * @custom:requirements
     *   - marketOwner must be a valid address (non-zero)
     *   - baseAsset must be a valid address (non-zero)
     *   - Market for the specified marketOwner/baseAsset pair must exist
     *
     * @custom:access-control Available to any caller (view function)
     * @custom:error-cases
     *   - ZeroAddress: When marketOwner or baseAsset is the zero address
     *   - MarketNotFound: When no market exists for the specified owner/asset pair
     */
    function getMarketInfo(address marketOwner, address baseAsset) external view returns (IPROTOCOL.Market memory) {
        if (marketOwner == address(0) || baseAsset == address(0)) revert ZeroAddress();
        if (markets[marketOwner][baseAsset].core == address(0)) revert MarketNotFound();

        return markets[marketOwner][baseAsset];
    }

    /**
     * @notice Checks if a market is currently active for the specified owner and base asset
     * @dev Returns the active status flag from the market configuration.
     *      Markets can be deactivated for maintenance or emergency purposes.
     * @param marketOwner Address of the market owner
     * @param baseAsset Address of the base asset to check
     * @return bool True if the market is active, false if inactive or non-existent
     *
     * @custom:access-control Available to any caller (view function)
     */
    function isMarketActive(address marketOwner, address baseAsset) external view returns (bool) {
        return markets[marketOwner][baseAsset].active;
    }

    /**
     * @notice Returns all markets created by a specific owner
     * @dev Retrieves all market configurations for a given market owner
     * @param marketOwner Address of the market owner to query
     * @return Array of Market structs for all markets owned by the specified address
     *
     * @custom:access-control Available to any caller (view function)
     */
    function getOwnerMarkets(address marketOwner) external view returns (IPROTOCOL.Market[] memory) {
        address[] memory baseAssets = ownerBaseAssets[marketOwner];
        IPROTOCOL.Market[] memory ownerMarkets = new IPROTOCOL.Market[](baseAssets.length);

        for (uint256 i = 0; i < baseAssets.length; i++) {
            ownerMarkets[i] = markets[marketOwner][baseAssets[i]];
        }

        return ownerMarkets;
    }

    /**
     * @notice Returns all base assets for which a specific owner has created markets
     * @dev Retrieves the list of base asset addresses for a given market owner
     * @param marketOwner Address of the market owner to query
     * @return Array of base asset addresses
     *
     * @custom:access-control Available to any caller (view function)
     */
    function getOwnerBaseAssets(address marketOwner) external view returns (address[] memory) {
        return ownerBaseAssets[marketOwner];
    }

    /**
     * @notice Returns all active markets across all owners
     * @dev Filters through all created markets and returns only those marked as active.
     * @return Array containing Market structs of all active markets
     *
     * @custom:gas-considerations This function iterates through all owners and markets,
     *                            which can be gas-intensive with many markets
     * @custom:access-control Available to any caller (view function)
     */
    function getAllActiveMarkets() external view returns (IPROTOCOL.Market[] memory) {
        uint256 totalCount = 0;

        // First, count active markets
        for (uint256 i = 0; i < allMarketOwners.length; i++) {
            address owner = allMarketOwners[i];
            address[] memory baseAssets = ownerBaseAssets[owner];

            for (uint256 j = 0; j < baseAssets.length; j++) {
                if (markets[owner][baseAssets[j]].active) {
                    totalCount++;
                }
            }
        }

        // Then populate the array
        IPROTOCOL.Market[] memory activeMarkets = new IPROTOCOL.Market[](totalCount);
        uint256 index = 0;

        for (uint256 i = 0; i < allMarketOwners.length; i++) {
            address owner = allMarketOwners[i];
            address[] memory baseAssets = ownerBaseAssets[owner];

            for (uint256 j = 0; j < baseAssets.length; j++) {
                if (markets[owner][baseAssets[j]].active) {
                    activeMarkets[index] = markets[owner][baseAssets[j]];
                    index++;
                }
            }
        }

        return activeMarkets;
    }

    /**
     * @notice Returns the total number of market owners
     * @dev Returns the length of the allMarketOwners array
     * @return Total number of unique market owners
     *
     * @custom:access-control Available to any caller (view function)
     */
    function getMarketOwnersCount() external view returns (uint256) {
        return allMarketOwners.length;
    }

    /**
     * @notice Returns a market owner address by index
     * @dev Retrieves an owner address from the allMarketOwners array
     * @param index The index of the owner to retrieve
     * @return Address of the market owner at the specified index
     *
     * @custom:requirements
     *   - index must be less than allMarketOwners.length
     *
     * @custom:access-control Available to any caller (view function)
     */
    function getMarketOwnerByIndex(uint256 index) external view returns (address) {
        require(index < allMarketOwners.length, "Index out of bounds");
        return allMarketOwners[index];
    }

    /**
     * @notice Returns the total number of markets created across all owners
     * @dev Returns the length of the allMarkets array
     * @return Total number of markets created
     *
     * @custom:access-control Available to any caller (view function)
     */
    function getTotalMarketsCount() external view returns (uint256) {
        return allMarkets.length;
    }

    // ========== BACKWARD COMPATIBILITY FUNCTIONS ==========

    /**
     * @notice Backward compatibility function for single-tenant market access
     * @dev Looks for market owned by any owner - returns first found (for legacy test compatibility)
     * @param baseAsset Address of the base asset
     * @return Market configuration struct
     */
    function getMarketInfo(address baseAsset) external view returns (IPROTOCOL.Market memory) {
        // Look through all market owners to find this base asset
        for (uint256 i = 0; i < allMarketOwners.length; i++) {
            address owner = allMarketOwners[i];
            if (markets[owner][baseAsset].core != address(0)) {
                return markets[owner][baseAsset];
            }
        }
        revert MarketNotFound();
    }

    /**
     * @notice Backward compatibility function for checking market active status
     * @dev Looks for market owned by any owner - returns first found (for legacy test compatibility)
     * @param baseAsset Address of the base asset
     * @return True if market is active
     */
    function isMarketActive(address baseAsset) external view returns (bool) {
        // Look through all market owners to find this base asset
        for (uint256 i = 0; i < allMarketOwners.length; i++) {
            address owner = allMarketOwners[i];
            if (markets[owner][baseAsset].core != address(0)) {
                return markets[owner][baseAsset].active;
            }
        }
        return false;
    }

    /**
     * @notice Backward compatibility function that returns base asset addresses
     * @dev For tests that expect address[] instead of Market[]
     * @return Array of base asset addresses for active markets
     */
    function getAllActiveMarketsAddresses() external view returns (address[] memory) {
        IPROTOCOL.Market[] memory activeMarkets = this.getAllActiveMarkets();
        address[] memory addresses = new address[](activeMarkets.length);

        for (uint256 i = 0; i < activeMarkets.length; i++) {
            addresses[i] = activeMarkets[i].baseAsset;
        }

        return addresses;
    }

    // ========== UUPS UPGRADE AUTHORIZATION ==========

    /**
     * @notice Authorizes an upgrade to a new implementation
     * @dev Implements the upgrade verification and authorization logic
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(LendefiConstants.UPGRADER_ROLE) {
        if (!pendingUpgrade.exists) {
            revert UpgradeNotScheduled();
        }

        if (pendingUpgrade.implementation != newImplementation) {
            revert ImplementationMismatch(pendingUpgrade.implementation, newImplementation);
        }

        uint256 timeElapsed = block.timestamp - pendingUpgrade.scheduledTime;
        if (timeElapsed < LendefiConstants.UPGRADE_TIMELOCK_DURATION) {
            revert UpgradeTimelockActive(LendefiConstants.UPGRADE_TIMELOCK_DURATION - timeElapsed);
        }

        // Clear the scheduled upgrade
        delete pendingUpgrade;

        ++version;
        emit Upgrade(msg.sender, newImplementation);
    }
}
