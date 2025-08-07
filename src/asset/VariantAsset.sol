// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.22;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../interfaces/IAsset.sol";
import "../interfaces/IRelativePriceProvider.sol";
import "./Asset.sol";

/**
 * @title VariantAsset
 * @notice Contract presenting an asset in a pool
 * @dev Expect to be owned by Timelock for management, and _pool links to Pool for coordination
 */
abstract contract VariantAsset is IRelativePriceProvider, Asset {
    /**
     * @notice Initializer.
     * @dev max decimal points for underlying token is 18.
     * @param underlyingToken_ The token represented by the asset
     * @param name_ The name of the asset
     * @param symbol_ The symbol of the asset
     * @param aggregateAccount_ The aggregate account to which the asset belongs
     */
    function __VariantAsset_init(
        address underlyingToken_,
        string memory name_,
        string memory symbol_,
        address aggregateAccount_
    ) internal onlyInitializing {
        super._initialize(underlyingToken_, name_, symbol_, aggregateAccount_);
    }

    /**
     * @notice Overriding the Asset.sol initialize() function to disable it.
     * @dev Derived contracts should have their own initializer that calls __VariantAsset_init.
     */
    function initialize(address, string memory, string memory, address) external virtual override {
        revert("VariantAsset: initialize function is disabled");
    }

    /**
     * @notice Get the relative price of 1 unit of token in WAD
     * @dev This function should be overridden by the subclass, unless the asset price is used as the base price for other assets in the pool.
     * @dev The overridden function should ensure the price is reasonable, and the price feed is not stale.
     * If it is stale, it should revert and swap/withdrawFromOtherAsset would be disabled, but deposit and withdrawal would still be permitted.
     */
    function getRelativePrice() external view virtual returns (uint256) {
        return 1e18;
    }
}
