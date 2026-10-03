// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// SaucerSwap V2 (Uniswap V3 fork) router, multi-hop exact-input swap.
interface ISaucerSwapV2Router {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// The slice of a SaucerSwap V2 pool the vault reads for spot prices.
interface ISaucerSwapV2Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
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
}

/// SaucerSwap's WhbarHelper: `deposit()` credits the caller with WHBAR for the HBAR sent.
interface IWhbarHelper {
    function deposit() external payable;
}
