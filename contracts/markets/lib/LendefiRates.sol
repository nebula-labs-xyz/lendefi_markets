// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title LendefiRates
 * @notice Library for core calculation functions used by Lendefi protocol
 * @dev Contains math-heavy functions to reduce main contract size
 */

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library LendefiRates {
    /// @dev base scale
    uint256 internal constant WAD = 1e6;
    /// @dev ray scale
    uint256 internal constant RAY = 1e27;
    /// @dev seconds per year on ray scale
    uint256 internal constant SECONDS_PER_YEAR_RAY = 365 * 86400 * RAY;

    /**
     * @dev rmul function - multiplies two RAY-scaled numbers
     * @param x amount in RAY
     * @param y amount in RAY
     * @return z value in RAY
     */
    function rmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = Math.mulDiv(x, y, RAY, Math.Rounding.Ceil);
    }

    /**
     * @dev rdiv function - divides two numbers and scales to RAY
     * @param x amount
     * @param y amount
     * @return z value in RAY
     */
    function rdiv(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = Math.mulDiv(x, RAY, y, Math.Rounding.Ceil);
    }

    /**
     * @dev rpow function - Calculates x raised to the power of n with RAY precision
     * @param x base value (in RAY precision)
     * @param n exponent
     * @return z result (in RAY precision)
     */
    function rpow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        // Initialize result to RAY (1.0 in ray precision)
        z = RAY;

        // Early return for x^0 = 1 and x^1 = x cases
        if (n == 0) {
            return z;
        }
        if (n == 1) {
            return x;
        }

        // Binary exponentiation algorithm
        while (n > 0) {
            // If the lowest bit of n is 1, multiply result by x
            if (n & 1 == 1) {
                z = rmul(z, x);
            }
            // Square the base
            x = rmul(x, x);
            // Shift n right by one bit (divide by 2)
            n = n >> 1;
        }
    }

    /**
     * @dev Converts rate to rateRay
     * @param rate annual rate in WAD
     * @return r rateRay
     */
    function annualRateToRay(uint256 rate) internal pure returns (uint256 r) {
        // First convert rate from WAD to RAY, then divide by seconds per year
        uint256 rateInRay = Math.mulDiv(rate, RAY, WAD, Math.Rounding.Floor);
        r = RAY + Math.mulDiv(rateInRay, RAY, SECONDS_PER_YEAR_RAY, Math.Rounding.Floor);
    }

    /**
     * @dev Accrues compounded interest
     * @param principal amount
     * @param rateRay rateray
     * @param time duration
     * @return amount (principal + compounded interest)
     */
    function accrueInterest(uint256 principal, uint256 rateRay, uint256 time) internal pure returns (uint256) {
        return rmul(principal, rpow(rateRay, time));
    }

    /**
     * @dev Calculates compounded interest
     * @param principal amount
     * @param rateRay rateray
     * @param time duration
     * @return amount (compounded interest)
     */
    function getInterest(uint256 principal, uint256 rateRay, uint256 time) internal pure returns (uint256) {
        return rmul(principal, rpow(rateRay, time)) - principal;
    }

    /**
     * @dev Calculates breakeven borrow rate
     * @param loan amount
     * @param supplyInterest amount
     * @return breakeven borrow rate
     */
    function breakEvenRate(uint256 loan, uint256 supplyInterest) internal pure returns (uint256) {
        return Math.mulDiv(WAD, loan + supplyInterest, loan, Math.Rounding.Floor) - WAD;
    }

    /**
     * @notice Calculates debt with accrued interest
     * @param debtAmount Current debt amount
     * @param borrowRate Borrow rate for the tier
     * @param timeElapsed Time since last accrual
     * @return Total debt with interest
     */
    function calculateDebtWithInterest(uint256 debtAmount, uint256 borrowRate, uint256 timeElapsed)
        internal
        pure
        returns (uint256)
    {
        if (debtAmount == 0) return 0;
        return accrueInterest(debtAmount, annualRateToRay(borrowRate), timeElapsed);
    }

    /**
     * @notice Calculates supply rate based on protocol metrics
     * @param totalSupply Total LP token supply
     * @param totalBorrow Current borrowed amount
     * @param totalSuppliedLiquidity Total liquidity supplied
     * @param baseProfitTarget Protocol profit target
     * @param usdcBalance Current USDC balance
     * @return Supply rate in parts per million
     */
    function getSupplyRate(
        uint256 totalSupply,
        uint256 totalBorrow,
        uint256 totalSuppliedLiquidity,
        uint256 baseProfitTarget,
        uint256 usdcBalance
    ) internal pure returns (uint256) {
        if (totalSuppliedLiquidity == 0) return 0;

        uint256 fee = 0;
        uint256 target = Math.mulDiv(totalSupply, baseProfitTarget, WAD, Math.Rounding.Floor);
        uint256 total = usdcBalance + totalBorrow;

        if (total >= totalSuppliedLiquidity + target) {
            fee = target;
        }

        return Math.mulDiv(WAD, total, totalSuppliedLiquidity + fee, Math.Rounding.Floor) - WAD;
    }

    /**
     * @notice Calculates borrow rate for a tier
     * @param utilization Protocol utilization rate
     * @param baseBorrowRate Base borrow rate
     * @param baseProfitTarget Protocol profit target
     * @param supplyRate Current supply rate
     * @param tierJumpRate Jump rate for the tier
     * @return Borrow rate in parts per million
     */
    function getBorrowRate(
        uint256 utilization,
        uint256 baseBorrowRate,
        uint256 baseProfitTarget,
        uint256 supplyRate,
        uint256 tierJumpRate
    ) internal pure returns (uint256) {
        if (utilization == 0) return baseBorrowRate;

        uint256 duration = 365 days;
        uint256 defaultSupply = WAD;
        uint256 loan = Math.mulDiv(defaultSupply, utilization, WAD, Math.Rounding.Floor);

        // Calculate base rate from supply rate
        uint256 supplyRateRay = annualRateToRay(supplyRate);
        uint256 supplyInterest = getInterest(defaultSupply, supplyRateRay, duration);
        uint256 breakEven = breakEvenRate(loan, supplyInterest);

        // Calculate final rate with tier premium
        uint256 rate = breakEven + baseProfitTarget;
        uint256 baseRate = rate > baseBorrowRate ? rate : baseBorrowRate;

        return baseRate + Math.mulDiv(tierJumpRate, utilization, WAD, Math.Rounding.Floor);
    }
}
