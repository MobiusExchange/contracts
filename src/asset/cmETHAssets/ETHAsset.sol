// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.22;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../VariantAsset.sol";

contract ETHAsset is Initializable, VariantAsset {
    function initialize(address underlyingToken_, string memory name_, string memory symbol_, address aggregateAccount_)
        external
        override
        initializer
    {
        __VariantAsset_init(underlyingToken_, name_, symbol_, aggregateAccount_);
    }
}
