// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.22;

interface IRelativePriceProvider {
    /**
     * @notice get the relative price in WAD
     */
    function getRelativePrice() external view returns (uint256);
}
