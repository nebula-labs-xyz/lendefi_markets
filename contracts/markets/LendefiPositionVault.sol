// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

/**
 * @title LendefiPositionVault
 * @notice Minimal vault for isolating user position collateral
 */
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract LendefiPositionVault is Initializable {
    using SafeERC20 for IERC20;

    address public core;
    address public owner;

    error OnlyCORE();
    error CantChangeOwner();

    function initialize(address _core) external initializer {
        core = _core;
    }

    function setOwner(address _owner) external {
        if (msg.sender != core) revert OnlyCORE();
        if (owner != address(0)) revert CantChangeOwner();
        owner = _owner;
    }

    /**
     * @notice Transfers tokens from the vault to a recipient
     * @param token Address of the token to transfer
     * @param amount Amount to transfer
     */
    function withdrawToken(address token, uint256 amount) external {
        if (msg.sender != core) revert OnlyCORE();
        IERC20(token).safeTransfer(owner, amount);
    }

    /**
     * @notice Transfer multiple token types to the liquidator
     * @param tokens Array of token addresses to liquidate
     * @param liquidator Address receiving the tokens
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
