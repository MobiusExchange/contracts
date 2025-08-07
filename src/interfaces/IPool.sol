// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.22;

interface IPool {
    function assetOf(address token) external view returns (address);

    function deposit(address token, uint256 amount, address to, uint256 deadline)
        external
        returns (uint256 liquidity);

    function withdraw(address token, uint256 liquidity, uint256 minimumAmount, address to, uint256 deadline)
        external
        returns (uint256 amount);

    function withdrawFromOtherAsset(
        address initialToken,
        address wantedToken,
        uint256 liquidity,
        uint256 minimumAmount,
        address to,
        uint256 deadline
    ) external returns (uint256 amount);

    function swap(
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 minimumToAmount,
        address to,
        uint256 deadline
    ) external returns (uint256 actualToAmount, uint256 haircut);

    function quotePotentialSwap(address fromToken, address toToken, uint256 fromAmount)
        external
        view
        returns (uint256 toAmount, uint256 haircut);

    function quotePotentialWithdraw(address token, uint256 liquidity)
        external
        view
        returns (uint256 amount, uint256 fee);

    function quotePotentialWithdrawFromOtherAsset(address initialToken, address wantedToken, uint256 liquidity)
        external
        view
        returns (uint256 amount, uint256 fee);

    function quoteMaxInitialLiquidityWithdrawable(address initialToken, address wantedToken)
        external
        view
        returns (uint256 maxInitialLiquidityAmount);

    function getTokenAddresses() external view returns (address[] memory);
}
