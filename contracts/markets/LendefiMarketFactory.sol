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
 * @dev Creates composable lending markets where each base asset gets its own isolated lending market
 *      with dedicated core logic and vault implementation. Uses OpenZeppelin's clone factory pattern
 *      for gas-efficient deployment of market instances.
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
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoRFeed} from "../interfaces/IPoRFeed.sol";

/// @custom:oz-upgrades
contract LendefiMarketFactory is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using Clones for address;

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

    /// @notice Address of the protocol treasury that receives fees and rewards
    /// @dev Treasury address is passed to all created markets for fee collection
    address public treasury;

    /// @notice Address of the assets module contract for asset management and validation
    /// @dev Contains asset whitelisting, pricing, and configuration logic
    address public assetsModule;

    /// @notice Address of the protocol governance token
    /// @dev Used for liquidator threshold requirements and rewards distribution
    address public govToken;

    /// @notice Address of the timelock contract for administrative operations
    /// @dev Has admin privileges across all created markets for governance operations
    address public timelock;

    /// @notice Address of the Proof of Reserves feed implementation
    /// @dev Template for creating PoR feeds for each market to track reserves
    address public porFeed;

    /// @notice Address of the ecosystem contract for reward distribution
    /// @dev Handles governance token rewards for liquidity providers
    address public ecosystem;

    /// @notice Mapping of base asset addresses to their corresponding market configurations
    /// @dev Key: base asset address, Value: Market struct containing all market data
    mapping(address => IPROTOCOL.Market) public markets;

    /// @notice Array of all base asset addresses for which markets have been created
    /// @dev Used for enumeration and iteration over all markets
    address[] public allBaseAssets;

    /// @notice Array of all market configurations created by this factory
    /// @dev Provides direct access to market data without mapping lookups
    IPROTOCOL.Market[] public allMarkets;

    // ========== EVENTS ==========

    /**
     * @notice Emitted when a new lending market is successfully created
     * @param baseAsset The base asset address for the new market
     * @param core The deployed LendefiCore contract address for this market
     * @param baseVault The deployed LendefiMarketVault contract address for this market
     * @param name The name of the ERC20 yield token for this market
     * @param symbol The symbol of the ERC20 yield token for this market
     * @param porFeed The deployed Proof of Reserves feed address for this market
     */
    event MarketCreated(
        address indexed baseAsset,
        address indexed core,
        address indexed baseVault,
        string name,
        string symbol,
        address porFeed
    );

    /**
     * @notice Emitted when market information is updated (reserved for future use)
     * @param baseAsset The base asset address of the updated market
     * @param marketInfo The updated market configuration data
     */
    event MarketUpdated(address indexed baseAsset, IPROTOCOL.Market marketInfo);

    /**
     * @notice Emitted when a market is removed or deactivated (reserved for future use)
     * @param baseAsset The base asset address of the removed market
     */
    event MarketRemoved(address indexed baseAsset);

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

    // ========== ERRORS ==========

    /// @notice Thrown when attempting to create a market for an asset that already has one
    error MarketAlreadyExists();

    /// @notice Thrown when a required address parameter is the zero address
    error ZeroAddress();

    /// @notice Thrown when trying to access a market that doesn't exist
    error MarketNotFound();

    /// @notice Thrown when clone deployment fails during market creation
    error CloneDeploymentFailed();

    /// @notice Thrown when an invalid contract address is provided
    error InvalidContract();

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
     * @param _treasury Address of the protocol treasury for fee collection
     * @param _assetsModule Address of the assets module for asset management
     * @param _govToken Address of the protocol governance token
     * @param _porFeed Address of the Proof of Reserves feed implementation
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
    function initialize(
        address _timelock,
        address _treasury,
        address _assetsModule,
        address _govToken,
        address _porFeed,
        address _ecosystem
    ) external initializer {
        if (
            _timelock == address(0) || _treasury == address(0) || _assetsModule == address(0) || _govToken == address(0)
                || _porFeed == address(0) || _ecosystem == address(0)
        ) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _timelock);

        treasury = _treasury;
        assetsModule = _assetsModule;
        govToken = _govToken;
        timelock = _timelock;
        porFeed = _porFeed;
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
        address _positionVaultImplementation
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (
            _coreImplementation == address(0) || _vaultImplementation == address(0)
                || _positionVaultImplementation == address(0)
        ) revert ZeroAddress();

        coreImplementation = _coreImplementation;
        vaultImplementation = _vaultImplementation;
        positionVaultImplementation = _positionVaultImplementation;

        emit ImplementationsSet(_coreImplementation, _vaultImplementation, _positionVaultImplementation);
    }

    // ========== MARKET MANAGEMENT ==========

    /**
     * @notice Creates a new lending market for a specified base asset
     * @dev Deploys a complete lending market infrastructure including:
     *      1. LendefiCore contract (cloned from implementation)
     *      2. LendefiMarketVault contract (cloned from implementation)
     *      3. Proof of Reserves feed (cloned from implementation)
     *      4. Proper initialization and cross-contract linking
     *
     *      The function creates isolated lending markets where each base asset
     *      operates independently with its own liquidity pools and risk parameters.
     *
     * @param baseAsset The ERC20 token address that will serve as the base asset for lending
     * @param name The name for the ERC4626 yield token (e.g., "Lendefi USDC Yield Token")
     * @param symbol The symbol for the ERC4626 yield token (e.g., "lendUSDC")
     *
     * @custom:requirements
     *   - baseAsset must be a valid ERC20 token address (non-zero)
     *   - Market for this baseAsset must not already exist
     *   - Implementation contracts must be set before calling this function
     *   - Caller must have DEFAULT_ADMIN_ROLE
     *
     * @custom:state-changes
     *   - Creates new market entry in markets mapping
     *   - Adds baseAsset to allBaseAssets array
     *   - Adds market info to allMarkets array
     *   - Deploys multiple new contract instances
     *
     * @custom:emits MarketCreated event with all deployed contract addresses
     * @custom:access-control Restricted to DEFAULT_ADMIN_ROLE
     * @custom:error-cases
     *   - ZeroAddress: When baseAsset is the zero address
     *   - MarketAlreadyExists: When market for this asset already exists
     *   - CloneDeploymentFailed: When any contract clone deployment fails
     */
    function createMarket(address baseAsset, string memory name, string memory symbol)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (baseAsset == address(0)) revert ZeroAddress();
        if (markets[baseAsset].core != address(0)) revert MarketAlreadyExists();

        // Create core contract using minimal proxy pattern
        address core = coreImplementation.clone();
        // Verify clone was successful
        if (core == address(0)) revert CloneDeploymentFailed();
        if (core.code.length == 0) revert CloneDeploymentFailed();

        // Initialize core contract through proxy
        bytes memory initData = abi.encodeWithSelector(
            LendefiCore.initialize.selector,
            timelock, // admin
            govToken, // Use stored govToken
            assetsModule, // assetsModule
            treasury, // treasury
            positionVaultImplementation // position vault implementation for user vaults
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(core), initData);
        LendefiCore coreInstance = LendefiCore(payable(address(proxy)));

        // Create vault contract using minimal proxy pattern
        address baseVault = vaultImplementation.clone();
        // Verify clone was successful
        if (baseVault == address(0)) revert CloneDeploymentFailed();
        if (baseVault.code.length == 0) revert CloneDeploymentFailed();

        // Initialize vault contract through proxy
        bytes memory vaultData = abi.encodeCall(
            LendefiMarketVault.initialize, (timelock, address(coreInstance), baseAsset, ecosystem, name, symbol)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(baseVault), vaultData);
        LendefiMarketVault vaultInstance = LendefiMarketVault(payable(address(vaultProxy)));

        // Create Proof of Reserves feed
        address porFeedClone = porFeed.clone();
        // Verify clone was successful
        if (porFeedClone == address(0)) revert CloneDeploymentFailed();
        if (porFeedClone.code.length == 0) revert CloneDeploymentFailed();

        // Initialize PoR feed
        IPoRFeed(porFeedClone).initialize(baseAsset, timelock, timelock);

        // Create market configuration struct
        IPROTOCOL.Market memory marketInfo = IPROTOCOL.Market({
            core: address(coreInstance),
            baseVault: address(vaultInstance),
            baseAsset: baseAsset,
            porFeed: porFeedClone,
            decimals: IERC20Metadata(baseAsset).decimals(),
            name: name, // Name for the yield token
            symbol: symbol, // Symbol for the yield token
            createdAt: block.timestamp,
            active: true
        });

        // Initialize the core contract with market information
        coreInstance.initializeMarket(marketInfo);

        // Store market information in contract state
        markets[marketInfo.baseAsset] = marketInfo;
        allBaseAssets.push(marketInfo.baseAsset);
        allMarkets.push(marketInfo);

        emit MarketCreated(
            marketInfo.baseAsset,
            address(coreInstance),
            address(vaultInstance),
            marketInfo.name,
            marketInfo.symbol,
            marketInfo.porFeed
        );
    }

    /**
     * @notice Retrieves complete market information for a given base asset
     * @dev Returns the full Market struct containing all deployed contract addresses
     *      and configuration data for the specified base asset's lending market.
     * @param baseAsset Address of the base asset to query market information for
     * @return Market configuration struct containing all market data
     *
     * @custom:requirements
     *   - baseAsset must be a valid address (non-zero)
     *   - Market for the specified baseAsset must exist
     *
     * @custom:access-control Available to any caller (view function)
     * @custom:error-cases
     *   - ZeroAddress: When baseAsset is the zero address
     *   - MarketNotFound: When no market exists for the specified base asset
     */
    function getMarketInfo(address baseAsset) external view returns (IPROTOCOL.Market memory) {
        if (baseAsset == address(0)) revert ZeroAddress();
        if (markets[baseAsset].core == address(0)) revert MarketNotFound();

        return markets[baseAsset];
    }

    /**
     * @notice Checks if a market is currently active for the specified base asset
     * @dev Returns the active status flag from the market configuration.
     *      Markets can be deactivated for maintenance or emergency purposes.
     * @param baseAsset Address of the base asset to check
     * @return bool True if the market is active, false if inactive or non-existent
     *
     * @custom:access-control Available to any caller (view function)
     */
    function isMarketActive(address baseAsset) external view returns (bool) {
        return markets[baseAsset].active;
    }

    /**
     * @notice Returns an array of all base asset addresses with active markets
     * @dev Filters through all created markets and returns only those marked as active.
     *      Uses assembly optimization to resize the returned array to the exact count
     *      of active markets, avoiding empty array elements.
     * @return address[] Array containing base asset addresses of all active markets
     *
     * @custom:gas-optimization Uses assembly to efficiently resize the returned array
     * @custom:access-control Available to any caller (view function)
     */
    function getAllActiveMarkets() external view returns (address[] memory) {
        address[] memory activeMarkets = new address[](allBaseAssets.length);
        uint256 count = 0;

        for (uint256 i = 0; i < allBaseAssets.length; i++) {
            address baseAsset = allBaseAssets[i];
            if (markets[baseAsset].active) {
                activeMarkets[count] = baseAsset;
                count++;
            }
        }

        // Resize the array to the actual number of active markets using assembly
        assembly {
            mstore(activeMarkets, count)
        }

        return activeMarkets;
    }

    // ========== UUPS UPGRADE AUTHORIZATION ==========

    /**
     * @notice Authorizes contract upgrades through the UUPS proxy pattern
     * @dev Internal function called by the UUPS upgrade mechanism to verify
     *      that the caller has permission to upgrade the contract implementation.
     *      Only addresses with DEFAULT_ADMIN_ROLE can authorize upgrades.
     *
     * @custom:access-control Restricted to DEFAULT_ADMIN_ROLE
     * @custom:upgrade-safety This function ensures only authorized parties can upgrade the factory
     */
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        version++;
    }
}
