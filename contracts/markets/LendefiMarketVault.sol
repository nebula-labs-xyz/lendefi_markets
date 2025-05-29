// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title LendefiMarketVault
 * @author alexei@nebula-labs(dot)xyz
 * @notice ERC-4626 compliant wrapper for the LendefiCore protocol
 * @dev Handles base currency tokenization while LendefiCore handles collateral and lending logic
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {LendefiConstants} from "./lib/LendefiConstants.sol";
import {IFlashLoanReceiver} from "../interfaces/IFlashLoanReceiver.sol";

/// @custom:oz-upgrades
contract LendefiMarketVault is
    Initializable,
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using LendefiConstants for *;
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    // ========== STATE VARIABLES ==========

    uint256 public WAD;
    uint256 public totalSuppliedLiquidity;
    uint256 public totalAccruedInterest;
    uint256 public totalBase;
    uint256 public totalBorrow;
    uint32 public version;
    uint32 public flashLoanFee = 9; // Default: 9 basis points (0.09%)
    address public lendefiCore;
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

    function initialize(address timelock, address core, address baseAsset, string memory name, string memory symbol)
        external
        initializer
    {
        if (baseAsset == address(0)) revert ZeroAddress();
        if (timelock == address(0)) revert ZeroAddress();
        if (core == address(0)) revert ZeroAddress();

        WAD = 10 ** IERC20Metadata(baseAsset).decimals();
        lendefiCore = core;
        version = 1;

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
        IERC20 baseAssetInstance = IERC20(asset());
        uint256 initialBalance = baseAssetInstance.balanceOf(address(this));
        if (amount > initialBalance) revert LowLiquidity();

        // Calculate fee and record initial balance
        uint256 fee = (amount * flashLoanFee) / 10000;
        uint256 requiredBalance = initialBalance + fee;
        totalBase += fee;

        // Transfer flash loan amount
        baseAssetInstance.safeTransfer(receiver, amount);

        // Execute flash loan operation
        bool success = IFlashLoanReceiver(receiver).executeOperation(address(asset()), amount, fee, msg.sender, params);

        // Verify both the return value AND the actual balance
        if (!success) revert FlashLoanFailed(); // Flash loan failed (incorrect return value)

        uint256 currentBalance = baseAssetInstance.balanceOf(address(this));
        if (currentBalance < requiredBalance) revert RepaymentFailed(); // Repay failed (insufficient funds returned)

        // Update protocol state only after all verifications succeed
        emit FlashLoan(msg.sender, receiver, address(asset()), amount, fee);
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
     * @notice Update the flash loan fee
     * @dev Only callable by manager role
     * @param newFee The new flash loan fee in basis points (max 100 = 1%)
     */
    function setFlashLoanFee(uint32 newFee) external onlyRole(LendefiConstants.MANAGER_ROLE) {
        if (newFee > 100 || newFee < 1) revert InvalidFee(); // Maximum 1% (100 basis points)
        uint32 oldFee = flashLoanFee;
        flashLoanFee = uint32(newFee);
        emit FlashLoanFeeUpdated(oldFee, newFee);
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
        if (liquidityOperationBlock[receiver] >= block.number) revert MEVSameBlockOperation();
        liquidityOperationBlock[receiver] = block.number;

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
        if (liquidityOperationBlock[receiver] >= block.number) revert MEVSameBlockOperation();
        liquidityOperationBlock[receiver] = block.number;

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
        if (liquidityOperationBlock[owner] >= block.number) revert MEVSameBlockOperation();
        liquidityOperationBlock[owner] = block.number;

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
        if (liquidityOperationBlock[owner] >= block.number) revert MEVSameBlockOperation();
        liquidityOperationBlock[owner] = block.number;

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
     * @dev Utilization = totalBorrow / totalSuppliedLiquidity, in WAD format
     * @return u The protocol's current utilization rate (0-1e6)
     */
    function utilization() public view returns (uint256 u) {
        (totalSuppliedLiquidity == 0 || totalBorrow == 0) ? u = 0 : u = (WAD * totalBorrow) / totalSuppliedLiquidity;
    }

    /**
     * @notice Authorizes the upgrade of the contract
     * @dev Only callable by admin
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(LendefiConstants.UPGRADER_ROLE) {}
}
