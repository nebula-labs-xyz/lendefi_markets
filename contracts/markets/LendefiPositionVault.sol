// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

/**
 * @title LendefiPositionVault
 * @author alexei@nebula-labs(dot)xyz
 * @notice Minimal isolated vault for holding individual user position collateral assets
 * @dev This contract serves as a secure custody solution for user collateral within the Lendefi protocol.
 *      Each user position gets its own dedicated vault instance to ensure complete asset isolation
 *      and prevent cross-contamination between different user positions.
 *
 *      Key characteristics:
 *      - Deployed as minimal proxy clones for gas efficiency
 *      - Provides complete asset isolation per user position
 *      - Only the LendefiCore contract can perform operations
 *      - Supports both individual withdrawals and batch liquidations
 *      - Immutable ownership once set (prevents ownership hijacking)
 *
 *      Security model:
 *      - All operations restricted to the LendefiCore contract
 *      - Owner can only be set once during position creation
 *      - No direct user interaction (all operations via core)
 *      - Supports emergency liquidation scenarios
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract LendefiPositionVault is Initializable {
    using SafeERC20 for IERC20;

    // ========== STATE VARIABLES ==========

    /// @notice Address of the LendefiCore contract that controls this vault
    /// @dev Only this address can perform operations on the vault, ensuring centralized control
    ///      and preventing unauthorized access to user collateral assets
    address public core;

    /// @notice Address of the user who owns the collateral stored in this vault
    /// @dev Set once during position creation and cannot be changed thereafter.
    ///      All withdrawn assets are transferred to this address unless liquidated.
    address public owner;

    // ========== ERRORS ==========

    /// @notice Thrown when a caller other than the LendefiCore contract attempts an operation
    error OnlyCORE();

    // ========== INITIALIZATION ==========

    /**
     * @notice Initializes the position vault with the controlling core contract and owner
     * @dev This function is called immediately after the vault is deployed as a minimal proxy.
     *      It establishes the connection between this vault and the LendefiCore contract
     *      that will manage all operations on the stored collateral, and sets the owner
     *      who owns the collateral stored in this vault.
     * @param _core Address of the LendefiCore contract that will control this vault
     * @param _owner Address of the user who will own the collateral in this vault
     *
     * @custom:requirements
     *   - Function can only be called once during deployment
     *   - _core address will be the only address authorized to perform operations
     *   - _owner cannot be changed after initialization
     *
     * @custom:state-changes
     *   - Sets the core address to _core
     *   - Sets the owner address to _owner
     *   - Initializes the contract for proxy usage
     *
     * @custom:access-control Only callable during contract initialization
     * @custom:proxy-pattern Used with OpenZeppelin's minimal proxy factory pattern
     */
    function initialize(address _core, address _owner) external initializer {
        core = _core;
        owner = _owner;
    }

    // ========== COLLATERAL OPERATIONS ==========

    /**
     * @notice Withdraws a specific amount of tokens from the vault to the owner
     * @dev Transfers collateral tokens from this vault to the position owner.
     *      This function is called when users withdraw collateral from their positions
     *      or when positions are closed and collateral is returned.
     * @param token Address of the ERC20 token to transfer
     * @param amount Amount of tokens to transfer to the owner
     *
     * @custom:requirements
     *   - Caller must be the LendefiCore contract
     *   - Vault must contain sufficient balance of the specified token
     *   - Owner address must have been set previously
     *
     * @custom:state-changes
     *   - Reduces the token balance held by this vault
     *   - Increases the token balance of the owner address
     *
     * @custom:access-control Restricted to LendefiCore contract only
     * @custom:safety Uses SafeERC20 for secure token transfers
     * @custom:error-cases
     *   - OnlyCORE: When caller is not the LendefiCore contract
     *   - May revert if insufficient token balance or transfer failure
     */
    function withdrawToken(address token, uint256 amount) external {
        if (msg.sender != core) revert OnlyCORE();
        IERC20(token).safeTransfer(owner, amount);
    }

    /**
     * @notice Transfers all balances of specified tokens to a liquidator during liquidation
     * @dev Handles the liquidation process by transferring all specified collateral tokens
     *      to the liquidator. This function is called when a position becomes undercollateralized
     *      and needs to be liquidated to repay the debt.
     *
     *      The function iterates through all provided token addresses and transfers
     *      the entire balance of each token to the liquidator, ensuring complete
     *      liquidation of the position's collateral.
     * @param tokens Array of token addresses to liquidate from this vault
     * @param liquidator Address that will receive all the liquidated collateral tokens
     *
     * @custom:requirements
     *   - Caller must be the LendefiCore contract
     *   - tokens array can contain any number of token addresses
     *   - liquidator must be a valid address capable of receiving tokens
     *
     * @custom:state-changes
     *   - Transfers entire balance of each specified token to liquidator
     *   - Reduces all token balances in this vault to zero
     *
     * @custom:gas-optimization Skips tokens with zero balance to save gas
     * @custom:access-control Restricted to LendefiCore contract only
     * @custom:safety Uses SafeERC20 for secure token transfers
     * @custom:liquidation This is the primary liquidation mechanism for positions
     * @custom:error-cases
     *   - OnlyCORE: When caller is not the LendefiCore contract
     *   - May revert if any token transfer fails
     *
     * @custom:batch-operation Processes multiple tokens in a single transaction for efficiency
     */
    function liquidate(address[] calldata tokens, address liquidator) external {
        if (msg.sender != core) revert OnlyCORE();

        uint256 length = tokens.length;
        for (uint256 i = 0; i < length; i++) {
            address token = tokens[i];
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                IERC20(token).safeTransfer(liquidator, balance);
            }
        }
    }
}
