// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

abstract contract SingleCallPerTransactionBase is Initializable, OwnableUpgradeable {
    /**
     * @notice The gas cost for accessing an address balance for the first time (cold access) is currently 2631 on Ethereum.
     * This value may change if the EVM is upgraded or may differ on other chains. In such cases, the owner should update it using setColdAccessGasCost.
     * Setting the value to -1 will disable the modifier's behavior, allowing multiple calls per transaction.
     */
    int256 private coldAccessGasCost;

    error AlreadyCalledInThisTransaction();

    function __SingleCallPerTransactionBase_init() internal onlyInitializing {
        __Ownable_init(msg.sender);
        coldAccessGasCost = 2631; // Default gas cost for cold access
    }

    // @dev Set the gas cost for cold access, in case EVM upgrade changes the gas cost for cold access
    function setColdAccessGasCost(int256 newColdAccessGasCost) external onlyOwner {
        coldAccessGasCost = newColdAccessGasCost;
    }

    /**
     * @notice Section 3 A in the paper
     * V. Callens, Z. Meghji and J. Gorzny, "Temporarily Restricting Solidity Smart Contract Interactions,"
     * 2024 IEEE International Conference on Decentralized Applications and Infrastructures (DAPPS), Shanghai, China, 2024
     * @dev This modifier ensures that a function can only be called once per transaction.
     * @dev If multiple functions are protected by this modifier, only one of them can be called per transaction.
     * @dev If the coldAccessGasCost is set to -1, the modifier behavior will not be applied.
     * The "conditionally" in the modifier name reminds the developer that this modifier is not applied when the coldAccessGasCost is set to -1.
     */
    modifier conditionallySingleCallPerTransaction() {
        if (coldAccessGasCost != -1) {
            address addressToCheck = address(uint160(bytes20(blockhash(block.number))));
            uint256 initialGas = gasleft();
            uint256 temp = addressToCheck.balance;
            uint256 gasConsumed = initialGas - gasleft();
            if (gasConsumed != uint256(coldAccessGasCost)) revert AlreadyCalledInThisTransaction();
        }
        _;
    }
}
