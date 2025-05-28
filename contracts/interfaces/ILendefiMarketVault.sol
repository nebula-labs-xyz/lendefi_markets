// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IFlashLoanReceiver} from "../interfaces/IFlashLoanReceiver.sol";

interface ILendefiMarketVault is IERC4626, IFlashLoanReceiver {
    // Events
    event WrapperInitialized(address indexed core, address indexed asset);
    event SupplyLiquidity(address indexed user, uint256 amount);
    event CollectInterest(address indexed user, uint256 amount);
    event Exchange(address indexed user, uint256 shares, uint256 amount);
    event FlashLoan(address indexed user, address indexed receiver, address indexed asset, uint256 amount, uint256 fee);

    // Errors
    error ZeroAddress();
    error MEVSameBlockOperation();
    error ZeroAmount();
    error LowLiquidity();
    error FlashLoanFailed();
    error RepaymentFailed();

    // Functions

    function totalSuppliedLiquidity() external view returns (uint256);
    function totalAccruedInterest() external view returns (uint256);
    function totalBase() external view returns (uint256);
    function totalBorrow() external view returns (uint256);
    function utilization() external view returns (uint256);

    function flashLoan(address receiver, uint256 amount, bytes calldata params) external;
    function pause() external;
    function unpause() external;
    function collectInterest(uint256 amount) external;
    function borrow(uint256 amount, address receiver) external;
    function repay(uint256 amount, address sender) external;
    function deposit(uint256 amount, address receiver) external returns (uint256);
    function mint(uint256 shares, address receiver) external returns (uint256);
    function withdraw(uint256 amount, address receiver, address owner) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function totalAssets() external view returns (uint256);
    function boostYield(address user, uint256 amount) external;
}
