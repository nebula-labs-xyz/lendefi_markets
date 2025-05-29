// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

/**
 * @title LendefiView
 * @notice View-only module for Lendefi protocol providing user-friendly data accessors
 * @dev Separating these functions reduces the main contract's size while providing
 *      convenient aggregated views of protocol state for front-end applications
 * @author Lendefi Protocol Team
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */
import {IPROTOCOL} from "../interfaces/IProtocol.sol";
import {IASSETS} from "../interfaces/IASSETS.sol";
import {ILendefiMarketVault} from "../interfaces/ILendefiMarketVault.sol";
import {IECOSYSTEM} from "../interfaces/IEcosystem.sol";
import {ILENDEFIVIEW} from "../interfaces/ILendefiView.sol";

/**
 * @notice LendefiView provides consolidated view functions for the protocol's state
 * @dev This contract doesn't hold any assets or modify state, it only aggregates data
 */
contract LendefiView is ILENDEFIVIEW {
    /// @notice Main protocol contract reference
    IPROTOCOL internal immutable protocol;

    /// @notice Market vault contract reference
    ILendefiMarketVault internal immutable marketVault;

    /// @notice Ecosystem contract reference for rewards calculation
    IECOSYSTEM internal immutable ecosystem;

    /**
     * @notice Initializes the LendefiView contract with required contract references
     * @dev All address parameters must be non-zero to ensure proper functionality
     * @param _protocol Address of the main Lendefi protocol contract
     * @param _marketVault Address of the market vault contract
     * @param _ecosystem Address of the ecosystem contract for rewards
     */
    constructor(address _protocol, address _marketVault, address _ecosystem) {
        require(_protocol != address(0) && _marketVault != address(0) && _ecosystem != address(0), "ZERO_ADDRESS");

        protocol = IPROTOCOL(_protocol);
        marketVault = ILendefiMarketVault(_marketVault);
        ecosystem = IECOSYSTEM(_ecosystem);
    }

    /**
     * @notice Provides a comprehensive summary of a user's position
     * @dev Aggregates multiple protocol calls into one convenient view function
     * @param user The address of the position owner
     * @param positionId The ID of the position to query
     * @return Summary struct containing all position data
     */
    function getPositionSummary(address user, uint256 positionId) external view returns (PositionSummary memory) {
        IPROTOCOL.UserPosition memory position = protocol.getUserPosition(user, positionId);

        uint256 totalCollateralValue = protocol.calculateCollateralValue(user, positionId);
        uint256 currentDebt = protocol.calculateDebtWithInterest(user, positionId);
        uint256 availableCredit = protocol.calculateCreditLimit(user, positionId);
        uint256 healthFactor = protocol.healthFactor(user, positionId);

        return PositionSummary({
            totalCollateralValue: totalCollateralValue,
            currentDebt: currentDebt,
            availableCredit: availableCredit,
            healthFactor: healthFactor,
            isIsolated: position.isIsolated,
            status: position.status
        });
    }

    /**
     * @notice Provides detailed information about a user's liquidity provision
     * @dev Calculates the current value of LP tokens and pending rewards
     * @param user The address of the liquidity provider
     * @return lpTokenBalance The user's balance of LP tokens
     * @return usdcValue The current USDC value of the user's LP tokens
     * @return lastAccrualBlock The block number of the last liquidity operation for the user
     * @return isRewardEligible Whether the user is eligible for rewards
     * @return pendingRewards The amount of pending rewards available to the user
     */
    function getLPInfo(address user)
        external
        view
        returns (
            uint256 lpTokenBalance,
            uint256 usdcValue,
            uint256 lastAccrualBlock,
            bool isRewardEligible,
            uint256 pendingRewards
        )
    {
        lpTokenBalance = marketVault.balanceOf(user);

        // Calculate the current USDC value based on the user's share of the total LP tokens
        uint256 totalAssets = marketVault.totalAssets();
        uint256 totalSupply = marketVault.totalSupply();
        usdcValue = totalSupply > 0 ? (lpTokenBalance * totalAssets) / totalSupply : 0;

        // Get last operation block from vault (liquidityOperationBlock mapping)
        // Since it's internal, we need to check if user is rewardable instead
        isRewardEligible = marketVault.isRewardable(user);

        // For last accrual block, we can't directly access it, so return 0
        // Frontend can track this separately or we need to add a getter to vault
        lastAccrualBlock = 0;

        // Calculate pending rewards if eligible
        if (isRewardEligible) {
            IPROTOCOL.ProtocolConfig memory config = protocol.getConfig();
            // Since we can't access liquidityOperationBlock directly, estimate from current eligibility
            // If eligible, they must have waited at least rewardInterval blocks
            uint256 estimatedBlocksElapsed = config.rewardInterval;
            uint256 reward = (config.rewardAmount * estimatedBlocksElapsed) / config.rewardInterval;
            uint256 maxReward = ecosystem.maxReward();
            pendingRewards = reward > maxReward ? maxReward : reward;
        }
    }

    /**
     * @notice Gets a comprehensive snapshot of the entire protocol's state
     * @dev Aggregates multiple protocol metrics into a single convenient struct
     * @return A ProtocolSnapshot struct containing all key protocol metrics and parameters
     */
    function getProtocolSnapshot() external view returns (ProtocolSnapshot memory) {
        IPROTOCOL.ProtocolConfig memory config = protocol.getConfig();

        // Get flash loan fee from vault
        uint256 flashLoanFee = marketVault.flashLoanFee();

        return ProtocolSnapshot({
            utilization: marketVault.utilization(),
            borrowRate: protocol.getBorrowRate(IASSETS.CollateralTier.CROSS_A),
            supplyRate: protocol.getSupplyRate(),
            totalBorrow: marketVault.totalBorrow(),
            totalSuppliedLiquidity: marketVault.totalSuppliedLiquidity(),
            targetReward: config.rewardAmount,
            rewardInterval: config.rewardInterval, // Now in blocks
            rewardableSupply: config.rewardableSupply,
            baseProfitTarget: config.profitTargetRate,
            liquidatorThreshold: config.liquidatorThreshold,
            flashLoanFee: flashLoanFee
        });
    }
}
