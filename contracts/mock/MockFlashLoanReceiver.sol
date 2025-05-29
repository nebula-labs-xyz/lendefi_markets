// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IFlashLoanReceiver} from "../interfaces/IFlashLoanReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockFlashLoanReceiver
 * @notice Mock implementation of IFlashLoanReceiver for testing flash loan functionality
 */
contract MockFlashLoanReceiver is IFlashLoanReceiver {
    bool public shouldFail;
    bool public shouldReturnLessFunds;

    function setShouldFail(bool _fail) external {
        shouldFail = _fail;
    }

    function setShouldReturnLessFunds(bool _returnLess) external {
        shouldReturnLessFunds = _returnLess;
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 fee,
        address, // initiator
        bytes calldata // params
    ) external returns (bool) {
        if (shouldFail) {
            return false;
        }

        // Calculate repayment
        uint256 repayAmount = amount + fee;

        if (shouldReturnLessFunds) {
            repayAmount = amount; // Don't include fee
        }

        // Repay the flash loan
        IERC20(asset).transfer(msg.sender, repayAmount);

        return true;
    }
}
