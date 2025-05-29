// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title Lendefi Market Factory
 * @author alexei@nebula-labs(dot)xyz
 * @notice Factory for creating LendefiCore + ERC4626baseVault pairs for different base assets
 * @dev Composable lending markets
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */

import {LendefiCore} from "./LendefiCore.sol";
import {LendefiMarketVault} from "./LendefiMarketVault.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IPoRFeed} from "../interfaces/IPoRFeed.sol";

/// @custom:oz-upgrades
contract LendefiMarketFactory is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using Clones for address;

    // ========== STATE VARIABLES ==========
    address public coreImplementation;
    address public vaultImplementation;
    address public treasury;
    address public assetsModule;
    address public govToken;
    address public timelock;
    address public porFeed;

    mapping(address => LendefiCore.Market) public markets; // baseAsset => Market
    address[] public allBaseAssets;
    LendefiCore.Market[] public allMarkets;

    // ========== EVENTS ==========
    event MarketCreated(
        address indexed baseAsset,
        address indexed core,
        address indexed baseVault,
        string name,
        string symbol,
        address porFeed
    );
    event MarketUpdated(address indexed baseAsset, LendefiCore.Market marketInfo);
    event MarketRemoved(address indexed baseAsset);
    event ImplementationsSet(address indexed coreImplementation, address indexed vaultImplementation);

    // ========== ERRORS ==========
    error MarketAlreadyExists();
    error ZeroAddress();
    error InvalidAsset();
    error MarketNotFound();
    error OnlyAdmin();
    error CloneDeploymentFailed();

    // ========== CONSTRUCTOR ==========
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ========== INITIALIZATION ==========
    function initialize(
        address _timelock,
        address _treasury,
        address _assetsModule,
        address _govToken,
        address _porFeed
    ) external initializer {
        if (
            _timelock == address(0) || _treasury == address(0) || _assetsModule == address(0) || _govToken == address(0)
                || _porFeed == address(0)
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
    }

    // // ========== ADMIN FUNCTIONS ==========
    function setImplementations(address _coreImplementation, address _vaultImplementation)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (_coreImplementation == address(0)) revert ZeroAddress();
        coreImplementation = _coreImplementation;
        vaultImplementation = _vaultImplementation;
        emit ImplementationsSet(_coreImplementation, _vaultImplementation);
    }

    // ========== MARKET MANAGEMENT ==========
    /**
     * @notice Create a new market for a base asset
     * @dev Only callable by admin
     * @param baseAsset The base asset address for the market
     */
    function createMarket(address baseAsset, string memory name, string memory symbol)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (baseAsset == address(0)) revert ZeroAddress();
        if (markets[baseAsset].core != address(0)) revert MarketAlreadyExists();

        // Create core contract
        address core = coreImplementation.clone();
        // Verify clone was successful
        if (core == address(0)) revert CloneDeploymentFailed();
        if (core.code.length == 0) revert CloneDeploymentFailed();
        
        bytes memory initData = abi.encodeWithSelector(
            LendefiCore.initialize.selector,
            timelock, // admin
            govToken, // Use stored govToken
            assetsModule, // assetsModule
            treasury // treasury
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(core), initData);
        LendefiCore coreInstance = LendefiCore(payable(address(proxy)));

        address baseVault = vaultImplementation.clone();
        // Verify clone was successful
        if (baseVault == address(0)) revert CloneDeploymentFailed();
        if (baseVault.code.length == 0) revert CloneDeploymentFailed();
        
        bytes memory vaultData =
            abi.encodeCall(LendefiMarketVault.initialize, (timelock, address(coreInstance), baseAsset, name, symbol));
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(baseVault), vaultData);
        LendefiMarketVault vaultInstance = LendefiMarketVault(payable(address(vaultProxy)));

        address porFeedClone = porFeed.clone();
        // Verify clone was successful
        if (porFeedClone == address(0)) revert CloneDeploymentFailed();
        if (porFeedClone.code.length == 0) revert CloneDeploymentFailed();
        
        //function initialize(address _asset, address _lendefiProtocol, address _updater, address _owner)
        IPoRFeed(porFeedClone).initialize(baseAsset, address(coreInstance), timelock, timelock);

        // Update market info with created addresses

        LendefiCore.Market memory marketInfo = LendefiCore.Market({
            core: address(coreInstance),
            baseVault: address(vaultInstance),
            baseAsset: baseAsset,
            porFeed: porFeedClone,
            decimals: IERC20Metadata(baseAsset).decimals(),
            name: name, //new name for new market yield token
            symbol: symbol, //new symbol for new market yield token
            createdAt: block.timestamp,
            active: true
        });

        // Initialize market
        coreInstance.initializeMarket(marketInfo);

        // Store market info
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
     * @notice Get market information
     * @param baseAsset Address of the base asset
     * @return Market configuration
     */
    function getMarketInfo(address baseAsset) external view returns (LendefiCore.Market memory) {
        if (baseAsset == address(0)) revert ZeroAddress();
        if (markets[baseAsset].core == address(0)) revert MarketNotFound();

        return markets[baseAsset];
    }

    /**
     * @notice Check if a market is active
     * @param baseAsset Address of the base asset
     * @return bool whether the market is active
     */
    function isMarketActive(address baseAsset) external view returns (bool) {
        return markets[baseAsset].active;
    }

    /**
     * @notice Get all active markets
     * @return Array of active market addresses
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

        // Resize the array to the actual number of active markets
        assembly {
            mstore(activeMarkets, count)
        }

        return activeMarkets;
    }

    // ========== UUPS ==========
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
