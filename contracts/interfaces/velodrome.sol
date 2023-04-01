// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;

interface IVelodromeRouter {

    struct route {
        address from;
        address to;
        bool stable;
    }

    function sortTokens(address tokenA, address tokenB) external pure returns (address token0, address token1);

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(address tokenA, address tokenB, bool stable) external view returns (address pair);

    // fetches and sorts the reserves for a pair
    function getReserves(address tokenA, address tokenB, bool stable) external view returns (uint reserveA, uint reserveB);

    // performs chained getAmountOut calculations on any number of pairs
    function getAmountOut(uint amountIn, address tokenIn, address tokenOut) external view returns (uint amount, bool stable);

    // performs chained getAmountOut calculations on any number of pairs
    function getAmountsOut(uint amountIn, route[] memory routes) external view returns (uint[] memory amounts);

    function isPair(address pair) external view returns (bool);

    function swapExactTokensForTokensSimple(
        uint amountIn,
        uint amountOutMin,
        address tokenFrom,
        address tokenTo,
        bool stable,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        route[] calldata routes,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapExactETHForTokens(uint amountOutMin, route[] calldata routes, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);

    function swapExactTokensForETH(uint amountIn, uint amountOutMin, route[] calldata routes, address to, uint deadline)
        external
        returns (uint[] memory amounts);

    function UNSAFE_swapExactTokensForTokens(
        uint[] memory amounts,
        route[] calldata routes,
        address to,
        uint deadline
    ) external returns (uint[] memory);
}
