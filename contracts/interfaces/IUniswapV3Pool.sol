// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    function token0() external view returns (address);
    function token1() external view returns (address);

    // Add this function to get pool liquidity
    function liquidity() external view returns (uint128);
}
