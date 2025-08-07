// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.22;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../VariantAsset.sol";

interface IApi3ReaderProxy {
    function read() external view returns (int224 value, uint32 timestamp);
}

contract cmETHAsset is Initializable, VariantAsset {
    address public exchangeRateOracle;

    function initialize(
        address underlyingToken_,
        string memory name_,
        string memory symbol_,
        address aggregateAccount_,
        address _exchangeRateOracle
    ) external initializer {
        __VariantAsset_init(underlyingToken_, name_, symbol_, aggregateAccount_);
        exchangeRateOracle = _exchangeRateOracle;
    }

    /**
     * @notice Get the relative price of the asset.
     * @dev The price is fetched from the price feed and converted to a relative price against ETH.
     * @dev The price feed is considered stale if it is older than 24 hours.
     * https://market.api3.org/mantle/meth-eth-exchange-rate/ has a heartbeat of 24 hours.
     * @return The relative price of the asset.
     */
    function getRelativePrice() external view override returns (uint256) {
        int224 value;
        uint32 timestamp;
        (value, timestamp) = IApi3ReaderProxy(exchangeRateOracle).read();
        require(timestamp > block.timestamp - 1 days, "MBS: pricefeed is too old");
        require(value > 1e18, "MBS: cmETHAsset price is too low");
        return uint256(int256(value));
    }
}
