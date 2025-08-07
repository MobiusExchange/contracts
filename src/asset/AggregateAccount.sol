// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.22;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title AggregateAccount
 * @notice AggregateAccount represents groups of assets
 * @dev Aggregate Account has to be set for Asset
 */
contract AggregateAccount is Initializable, OwnableUpgradeable {
    /// @notice name of the account. E.g USDT for aggregate account containing USDT, USDC etc.
    string public accountName;

    /**
     * @notice Initializer.
     * @param accountName_ The name of the aggregate account
     */
    function initialize(string memory accountName_) external initializer {
        require(bytes(accountName_).length > 0, "PLT:ACCOUNT_NAME_VOID");

        __Ownable_init(msg.sender);

        accountName = accountName_;
    }

    /**
     * @notice Changes Account Name. Can only be set by the contract owner.
     * @param accountName_ the new name
     */
    function setAccountName(string memory accountName_) external onlyOwner {
        require(bytes(accountName_).length > 0, "Mobius: Aggregate account name cannot be zero");
        accountName = accountName_;
    }
}
