// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.22;

interface IMobiusRouter {
    function swapTokensForTokens(
        address[] calldata tokenPath,
        address[] calldata poolPath,
        uint256 fromAmount,
        uint256 minimumToAmount,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut, uint256 haircut);
}
