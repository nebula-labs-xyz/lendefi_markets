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
 * @title LendefiMarketVault
 * @author alexei@nebula-labs(dot)xyz
 * @notice ERC-4626 compliant wrapper for the LendefiCore protocol
 * @dev Handles base currency tokenization while LendefiCore handles collateral and lending logic
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */

import {IPROTOCOL} from "../interfaces/IProtocol.sol";
import {IECOSYSTEM} from "../interfaces/IEcosystem.sol";
import {IPoRFeed} from "../interfaces/IPoRFeed.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {LendefiConstants} from "./lib/LendefiConstants.sol";
import {LendefiRates} from "./lib/LendefiRates.sol";
import {LendefiPoRFeed} from "./LendefiPoRFeed.sol";
import {IFlashLoanReceiver} from "../interfaces/IFlashLoanReceiver.sol";
import {AutomationCompatibleInterface} from
    "../vendor/@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";

/// @custom:oz-upgrades
contract LendefiMarketVault is
    Initializable,
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    AutomationCompatibleInterface
{
    using SafeERC20 for IERC20;
    using LendefiRates for *;
    using LendefiConstants for *;
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    // ========== STATE VARIABLES ==========

    uint256 public baseDecimals;
    uint256 public totalSuppliedLiquidity;
    uint256 public totalAccruedInterest;
    uint256 public totalBase;
    uint256 public totalBorrow;

    /// @notice Counter for the number of times the upkeep has been performed
    uint256 public counter;
    /// @notice Interval for the upkeep to be performed
    uint256 public interval;
    /// @notice Timestamp of the last upkeep performed
    uint256 public lastTimeStamp;
    /// @notice Version of the contract
    uint32 public version;
    /// @notice Address of the por feed for the token
    address public porFeed;
    /// @notice Address of the Lendefi protocol contract
    address public lendefiCore;
    /// @notice Address of the ecosystem contract
    address public ecosystem;
    /// @notice Protocol config
    IPROTOCOL.ProtocolConfig public protocolConfig; // Cached protocol config to avoid callbacks
    /// @notice Borrower debt
    mapping(address => uint256) public borrowerDebt;

    /**
     * @dev Tracks the last block when operations were performed for each liquidity provider
     * @dev Key: User address, Value: Block number of last operation
     */
    mapping(address => uint256) internal liquidityOperationBlock;

    // ========== EVENTS ==========

    event Initialized(address indexed admin);
    event SupplyLiquidity(address indexed user, uint256 amount);
    event YieldBoosted(address indexed user, uint256 amount);
    event Exchange(address indexed user, uint256 shares, uint256 amount);
    event FlashLoan(address indexed user, address indexed receiver, address indexed asset, uint256 amount, uint256 fee);
    event FlashLoanFeeUpdated(uint256 oldFee, uint256 newFee);
    event Reward(address indexed user, uint256 amount);
    /// @notice Emitted when the contract is undercollateralized
    /// @param timestamp The timestamp of the event
    /// @param tvl The total value locked in the protocol
    /// @param totalSupply The total supply of the token
    event CollateralizationAlert(uint256 timestamp, uint256 tvl, uint256 totalSupply);
    // ========== ERRORS ==========

    error ZeroAddress();
    error MEVSameBlockOperation();
    error ZeroAmount();
    error LowLiquidity();
    error FlashLoanFailed();
    error RepaymentFailed();
    error InvalidFee();

    modifier validAmount(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }

    modifier validAddress(address addr) {
        if (addr == address(0)) revert ZeroAddress();
        _;
    }

    // ========== CONSTRUCTOR ==========
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    // ========== INITIALIZATION ==========

    function initialize(
        address timelock,
        address core,
        address baseAsset,
        address _ecosystem,
        string memory name,
        string memory symbol
    ) external initializer {
        if (baseAsset == address(0)) revert ZeroAddress();
        if (timelock == address(0)) revert ZeroAddress();
        if (core == address(0)) revert ZeroAddress();
        if (_ecosystem == address(0)) revert ZeroAddress();

        baseDecimals = 10 ** IERC20Metadata(baseAsset).decimals();
        lendefiCore = core;
        ecosystem = _ecosystem;
        version = 1;
        interval = 12 hours;
        lastTimeStamp = block.timestamp;
        porFeed = address(new LendefiPoRFeed());
        IPoRFeed(porFeed).initialize(baseAsset, address(this), timelock);
        // Initialize protocol config from core
        protocolConfig = IPROTOCOL(core).getConfig();

        __ERC4626_init(IERC20(baseAsset));
        __ERC20_init(name, symbol);
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, timelock);
        _grantRole(LendefiConstants.PAUSER_ROLE, timelock);
        _grantRole(LendefiConstants.PROTOCOL_ROLE, core);
        _grantRole(LendefiConstants.UPGRADER_ROLE, timelock);
        _grantRole(LendefiConstants.MANAGER_ROLE, timelock);

        emit Initialized(msg.sender);
    }

    // ========== CONFIGURATION FUNCTIONS ==========

    /**
     * @notice Updates the protocol configuration (only callable by core)
     * @param _config The new protocol configuration
     */
    function setProtocolConfig(IPROTOCOL.ProtocolConfig calldata _config)
        external
        onlyRole(LendefiConstants.PROTOCOL_ROLE)
    {
        // Validate flash loan fee
        if (_config.flashLoanFee > 100 || _config.flashLoanFee < 1) revert InvalidFee(); // Maximum 1% (100 basis points)

        uint32 oldFee = protocolConfig.flashLoanFee;
        protocolConfig = _config;

        // Emit event if flash loan fee changed
        if (oldFee != _config.flashLoanFee) {
            emit FlashLoanFeeUpdated(oldFee, _config.flashLoanFee);
        }
    }

    // ========== FLASH LOAN FUNCTIONS ==========

    /**
     * @notice Flash loan function
     * @param receiver The address of the receiver
     * @param amount The amount of the flash loan
     * @param params The parameters of the flash loan
     */
    function flashLoan(address receiver, uint256 amount, bytes calldata params)
        external
        validAmount(amount)
        validAddress(receiver)
        nonReentrant
        whenNotPaused
    {
        // Cache asset address to avoid multiple external calls
        address cachedAsset = asset();
        IERC20 baseAssetInstance = IERC20(cachedAsset);
        uint256 initialBalance = baseAssetInstance.balanceOf(address(this));
        if (amount > initialBalance) revert LowLiquidity();

        // Calculate fee and record initial balance
        uint256 fee = (amount * protocolConfig.flashLoanFee) / 10000;
        uint256 requiredBalance = initialBalance + fee;
        totalBase += fee;

        // Transfer flash loan amount
        baseAssetInstance.safeTransfer(receiver, amount);

        // Execute flash loan operation using cached asset address
        bool success = IFlashLoanReceiver(receiver).executeOperation(cachedAsset, amount, fee, msg.sender, params);

        // Verify both the return value AND the actual balance
        if (!success) revert FlashLoanFailed(); // Flash loan failed (incorrect return value)

        uint256 currentBalance = baseAssetInstance.balanceOf(address(this));
        if (currentBalance < requiredBalance) revert RepaymentFailed(); // Repay failed (insufficient funds returned)

        // Update protocol state only after all verifications succeed using cached asset address
        emit FlashLoan(msg.sender, receiver, cachedAsset, amount, fee);
    }

    // ========== ADMIN FUNCTIONS ==========
    /**
     * @notice Pause the vault
     * @dev Only callable by admin
     */
    function pause() external onlyRole(LendefiConstants.PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the vault
     * @dev Only callable by admin
     */
    function unpause() external onlyRole(LendefiConstants.PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Performs automated Proof of Reserve updates at regular intervals
     * @dev This function is called by Chainlink Automation nodes when checkUpkeep returns true
     *      It updates the PoR feed with current TVL and monitors protocol collateralization
     *
     * The function:
     * 1. Updates lastTimeStamp to track intervals
     * 2. Increments the counter for monitoring purposes
     * 3. Checks protocol collateralization status
     * 4. Updates the Chainlink PoR feed with current TVL
     * 5. Emits alert if protocol becomes undercollateralized
     *
     * @custom:automation This function is part of Chainlink's AutomationCompatibleInterface
     * @custom:interval Updates occur every 12 hours (defined by interval state variable)
     *
     * @custom:emits CollateralizationAlert when protocol becomes undercollateralized
     */
    function performUpkeep(bytes calldata /* performData */ ) external override {
        if ((block.timestamp - lastTimeStamp) > interval) {
            lastTimeStamp = block.timestamp;
            counter = counter + 1;

            // Use the stored TVL value instead of parameter
            (bool collateralized, uint256 tvl) = IPROTOCOL(lendefiCore).isCollateralized();

            // Update the reserves on the feed
            IPoRFeed(porFeed).updateReserves(tvl);
            if (!collateralized) {
                emit CollateralizationAlert(block.timestamp, tvl, totalSupply());
            }
        }
    }

    /**
     * @notice Checks if upkeep needs to be performed for Proof of Reserve updates
     * @dev This function is called by Chainlink Automation nodes to determine if performUpkeep should be executed
     *      The upkeep is needed when the time elapsed since the last update exceeds the defined interval
     * @return upkeepNeeded Boolean indicating if upkeep should be performed
     * @return performData Encoded data to be passed to performUpkeep (returns empty bytes)
     *
     * @custom:automation This function is part of Chainlink's AutomationCompatibleInterface
     * @custom:interval The check uses the contract's interval variable (default 12 hours)
     */
    function checkUpkeep(bytes calldata /* checkData */ )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        upkeepNeeded = (block.timestamp - lastTimeStamp) > interval;
        performData = "0x00";
    }

    /**
     * @notice Boost yield by adding liquidity
     * @dev Only callable by protocol role (used during liquidations)
     * @param user The user whose liquidation generated the yield
     * @param amount The amount of liquidity to add
     */
    function boostYield(address user, uint256 amount)
        external
        onlyRole(LendefiConstants.MANAGER_ROLE)
        whenNotPaused
        nonReentrant
    {
        totalBase += amount;
        totalAccruedInterest += amount;
        emit YieldBoosted(user, amount);
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Claims accumulated rewards for eligible liquidity providers
     * @dev Calculates time-based rewards and transfers them to the caller if eligible
     * @return finalReward amount
     * @custom:requirements
     *   - Caller must have sufficient time since last claim (>= rewardInterval)
     *   - Caller must have supplied minimum amount (>= rewardableSupply)
     *
     * @custom:state-changes
     *   - Resets liquidityOperationBlock[msg.sender] if rewards are claimed
     *
     * @custom:emits
     *   - Reward(msg.sender, rewardAmount) if rewards are issued
     *
     * @custom:access-control Available to any caller when protocol is not paused
     */
    function claimReward() external nonReentrant whenNotPaused returns (uint256 finalReward) {
        if (isRewardable(msg.sender)) {
            // Get config from core
            IPROTOCOL.ProtocolConfig memory config = IPROTOCOL(lendefiCore).getConfig();

            // Cache ecosystem contract to avoid multiple storage reads
            IECOSYSTEM cachedEcosystem = IECOSYSTEM(ecosystem);

            // Calculate reward amount based on blocks elapsed
            uint256 lastOperationBlock = liquidityOperationBlock[msg.sender];
            uint256 currentBlock = block.number;
            uint256 blocksElapsed = currentBlock - lastOperationBlock;
            uint256 reward = (config.rewardAmount * blocksElapsed) / config.rewardInterval;

            // Apply maximum reward cap using cached ecosystem reference
            uint256 maxReward = cachedEcosystem.maxReward();
            finalReward = reward > maxReward ? maxReward : reward;

            // Reset block number for next reward period
            liquidityOperationBlock[msg.sender] = currentBlock;

            // Emit event and issue reward using cached ecosystem reference
            emit Reward(msg.sender, finalReward);
            cachedEcosystem.reward(msg.sender, finalReward);
        }
    }

    /**
     * @notice Deposit base asset into the vault
     * @param amount The amount of base asset to deposit
     * @param receiver The address to receive the shares
     * @return The number of shares minted
     */
    function deposit(uint256 amount, address receiver)
        public
        override
        validAmount(amount)
        validAddress(receiver)
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        // MEV protection: prevent same-block operations
        uint256 lastOperationBlock = liquidityOperationBlock[receiver];
        uint256 currentBlock = block.number;
        if (lastOperationBlock >= currentBlock) revert MEVSameBlockOperation();
        liquidityOperationBlock[receiver] = currentBlock;

        uint256 shares = super.deposit(amount, receiver);
        totalBase += amount;
        totalSuppliedLiquidity += amount;
        return shares;
    }

    /**
     * @notice Mint shares for the vault
     * @param shares The number of shares to mint
     * @param receiver The address to receive the shares
     * @return The amount of base asset minted
     */
    function mint(uint256 shares, address receiver)
        public
        override
        validAmount(shares)
        validAddress(receiver)
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        // MEV protection: prevent same-block operations
        uint256 lastOperationBlock = liquidityOperationBlock[receiver];
        uint256 currentBlock = block.number;
        if (lastOperationBlock >= currentBlock) revert MEVSameBlockOperation();
        liquidityOperationBlock[receiver] = currentBlock;

        uint256 amount = super.mint(shares, receiver);
        totalBase += amount;
        totalSuppliedLiquidity += amount;
        return amount;
    }

    /**
     * @notice Withdraw base asset from the vault
     * @param amount The amount of base asset to withdraw
     * @param receiver The address to receive the base asset
     * @param owner The address of the owner
     * @return The number of shares withdrawn
     */
    function withdraw(uint256 amount, address receiver, address owner)
        public
        override
        validAddress(receiver)
        validAddress(owner)
        validAmount(amount)
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        // MEV protection: prevent same-block operations
        uint256 lastOperationBlock = liquidityOperationBlock[owner];
        uint256 currentBlock = block.number;
        if (lastOperationBlock >= currentBlock) revert MEVSameBlockOperation();
        liquidityOperationBlock[owner] = currentBlock;

        uint256 shares = super.withdraw(amount, receiver, owner);
        totalBase -= amount;
        totalSuppliedLiquidity -= amount;
        return shares;
    }

    /**
     * @notice Redeem shares for base asset
     * @param shares The number of shares to redeem
     * @param receiver The address to receive the base asset
     * @param owner The address of the owner
     * @return The amount of base asset redeemed
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        validAmount(shares)
        validAddress(receiver)
        validAddress(owner)
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        // MEV protection: prevent same-block operations
        uint256 lastOperationBlock = liquidityOperationBlock[owner];
        uint256 currentBlock = block.number;
        if (lastOperationBlock >= currentBlock) revert MEVSameBlockOperation();
        liquidityOperationBlock[owner] = currentBlock;

        uint256 amount = super.redeem(shares, receiver, owner);
        totalBase -= amount;
        totalSuppliedLiquidity -= amount;
        return amount;
    }

    /**
     * @notice Borrow base asset from the vault
     * @dev Only callable by admin
     * @param amount The amount of base asset to borrow
     * @param receiver The address to receive the base asset
     */
    function borrow(uint256 amount, address receiver)
        public
        onlyRole(LendefiConstants.PROTOCOL_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (totalBorrow + amount > totalSuppliedLiquidity) revert LowLiquidity();
        totalBorrow += amount;
        borrowerDebt[receiver] += amount; // Track by actual borrower
        IERC20(asset()).safeTransfer(receiver, amount);
    }

    /**
     * @notice Repay borrowed base asset
     * @dev Only callable by admin
     * @param amount The amount of base asset to repay
     * @param sender The address of the user repaying the debt
     */
    function repay(uint256 amount, address sender)
        public
        onlyRole(LendefiConstants.PROTOCOL_ROLE)
        whenNotPaused
        nonReentrant
    {
        uint256 debt = borrowerDebt[sender];
        uint256 principalRepaid = amount > debt ? debt : amount;
        uint256 interestPaid = amount > debt ? amount - debt : 0;

        totalBorrow -= principalRepaid;
        borrowerDebt[sender] -= principalRepaid;
        totalBase += amount;
        totalAccruedInterest += interestPaid;

        // Cache asset address to avoid external call
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Returns the total amount of base asset in the vault
     * @return The total amount of base asset in the vault
     */
    function totalAssets() public view override returns (uint256) {
        return totalBase;
    }

    /**
     * @notice Calculates the current protocol utilization rate
     * @dev Utilization = totalBorrow / totalSuppliedLiquidity, in baseDecimals format
     * @return u The protocol's current utilization rate (0-1e6)
     */
    function utilization() public view returns (uint256 u) {
        // Cache storage reads to avoid multiple SLOADs
        uint256 cachedSupply = totalSuppliedLiquidity;
        uint256 cachedBorrow = totalBorrow;

        (cachedSupply == 0 || cachedBorrow == 0) ? u = 0 : u = (baseDecimals * cachedBorrow) / cachedSupply;
    }

    /**
     * @notice Determines if a user is eligible for liquidity provider rewards
     * @dev Checks if the required time has passed and minimum supply amount is met
     * @param user Address of the user to check for reward eligibility
     * @return True if the user is eligible for rewards, false otherwise
     */
    function isRewardable(address user) public view returns (bool) {
        uint256 lastBlock = liquidityOperationBlock[user];
        if (lastBlock == 0) return false; // Never had liquidity operation

        IPROTOCOL.ProtocolConfig memory config = protocolConfig;
        if (config.rewardAmount == 0) return false; // Rewards disabled
        uint256 baseAmount = previewRedeem(balanceOf(user));

        return block.number - lastBlock >= config.rewardInterval && baseAmount >= config.rewardableSupply;
    }

    /**
     * @notice Calculates the current supply interest rate for liquidity providers
     * @dev Based on utilization, protocol fees, and available liquidity
     * @return The current annual supply interest rate in baseDecimals format
     */
    function getSupplyRate() public view returns (uint256) {
        return LendefiRates.getSupplyRate(
            totalSupply(), totalBorrow, totalSuppliedLiquidity, protocolConfig.profitTargetRate, totalAssets()
        );
    }

    /**
     * @notice Authorizes the upgrade of the contract
     * @dev Only callable by admin
     */
    function _authorizeUpgrade(address) internal override onlyRole(LendefiConstants.UPGRADER_ROLE) {
        version++;
    }
}
