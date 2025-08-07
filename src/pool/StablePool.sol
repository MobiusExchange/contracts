// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.22;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../asset/Asset.sol";
import "./Core.sol";
import "../interfaces/IPool.sol";
import "../util/SingleCallPerTransactionBase.sol";
/**
 * @title StablePool
 * @notice Manages deposits, withdrawals and swaps. Holds a mapping of assets and parameters.
 * @dev The main entry-point of Mobius protocol
 *
 * Note The Pool is ownable and the owner wields power.
 * Note The ownership will be transferred to a governance contract once Mobius community can show to govern itself.
 * Note The d.p table. WAD means 18 decimal. by convention from DSMath.sol
 *  |-------------------------------------------------------|------------------------------------|
 *  | variable	                                            | dp                                 |
 *  |-------------------------------------------------------|------------------------------------|
 *  | asset	                                                | WAD                                |
 *  | liability	                                            | WAD                                |
 *  | amount	                                            | WAD                                |
 *  | amount (token amount when swap from/deposit)	        | Underlying token dp                |
 *  | liquidity (LP token, Asset contract ERC20)	        | WAD                                |
 *  |-------------------------------------------------------|------------------------------------|
 *
 */

contract StablePool is
    Initializable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    Core,
    SingleCallPerTransactionBase,
    IPool
{
    using SafeERC20 for IERC20;

    /// @notice Asset Map struct holds assets
    struct AssetMap {
        address[] keys;
        mapping(address => Asset) values;
        mapping(address => uint256) indexOf;
        mapping(address => bool) inserted;
    }

    /// @notice Wei in 1 ether
    uint256 private constant ETH_UNIT = 10 ** 18;

    /// @notice parameter rThreshold
    uint256 private _rThreshold;

    /// @notice Haircut rate
    uint256 private _haircutRate;

    /// @notice Retention ratio
    uint256 private _retentionRatio;

    /// @notice Dev address
    address private _dev;

    /// @notice A record of assets inside Pool
    AssetMap private _assets;

    /// @notice An event emitted when an asset is added to Pool
    event AssetAdded(address indexed token, address indexed asset);

    /// @notice An event emitted when a deposit is made to Pool
    event Deposit(address indexed sender, address token, uint256 amount, uint256 liquidity, address indexed to);

    /// @notice An event emitted when a withdrawal is made from Pool
    event Withdraw(address indexed sender, address token, uint256 amount, uint256 liquidity, address indexed to);

    /// @notice An event emitted when dev is updated
    event DevUpdated(address indexed previousDev, address indexed newDev);

    /// @notice An event emitted when param is updated
    event ParamRThresholdUpdated(uint256 previousRThreshold, uint256 newRThreshold);

    /// @notice An event emitted when haircut is updated
    event HaircutRateUpdated(uint256 previousHaircut, uint256 newHaircut);

    /// @notice An event emitted when retention ratio is updated
    event RetentionRatioUpdated(uint256 previousRetentionRatio, uint256 newRetentionRatio);

    /// @notice An event emitted when a swap is made in Pool
    event Swap(
        address indexed sender,
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 toAmount,
        address indexed to
    );

    /// Errors
    error Pool_AddressShouldNotBeZero();
    error Pool_AssetShouldHaveSameAggregateAccount();
    error Pool_InputAmountZero();
    error Pool_TokensShouldBeDifferent();
    error Pool_CoverageRatioTooLow();
    error Pool_CoverageRatioTooHigh();
    error Pool_DustAmount();
    error Pool_OutputAmountLessThanRequested();
    error Pool_InsufficientCash();
    error Pool_Forbidden();
    error Pool_Expired();
    error Pool_InvalidRThreshold();
    error Pool_InvalidHaircutRate();
    error Pool_InvalidRetentionRatio();
    error Pool_AssetAlreadyExists();
    error Pool_AssetDoesNotExist();
    error Pool_InvalidTokenDecimals();

    /// @dev Modifier ensuring that certain function can only be called by developer
    modifier onlyDev() {
        if (_dev != msg.sender) revert Pool_Forbidden();
        _;
    }

    /// @dev Modifier ensuring a certain deadline for a function to complete execution
    modifier before(uint256 deadline) {
        if (deadline < block.timestamp) revert Pool_Expired();
        _;
    }

    /// @dev Modifier ensuring valid swap parameters
    modifier validSwap(address fromToken, address toToken, uint256 fromAmount) {
        if (fromToken == address(0) || toToken == address(0)) {
            revert Pool_AddressShouldNotBeZero();
        }
        if (fromToken == toToken) {
            revert Pool_TokensShouldBeDifferent();
        }

        if (fromAmount == 0) {
            revert Pool_InputAmountZero();
        }
        _;
    }

    function _checkSameAggregateAccount(Asset initialAsset, Asset wantedAsset) private view {
        if (wantedAsset.aggregateAccount() != initialAsset.aggregateAccount()) {
            revert Pool_AssetShouldHaveSameAggregateAccount();
        }
    }

    /// @dev Modifier ensuring address is not zero
    modifier addressNonZero(address address_) {
        if (address_ == address(0)) {
            revert Pool_AddressShouldNotBeZero();
        }
        _;
    }

    /**
     * @notice Initializes pool. Dev is set to be the account calling this function.
     */
    function initialize() external initializer {
        __SingleCallPerTransactionBase_init();
        __ReentrancyGuard_init_unchained();
        __Pausable_init_unchained();

        // set variables
        _rThreshold = 0.25e18;
        _haircutRate = 0.0003e18; // 0.03%
        _retentionRatio = 1e18; // 1

        // set dev
        _dev = msg.sender;
    }

    // Getters //

    /**
     * @notice Gets current Dev address
     * @return The current Dev address for Pool
     */
    function getDev() external view returns (address) {
        return _dev;
    }

    /**
     * @notice Gets current rThreshold parameter
     * @return The current rThreshold parameter in Pool
     */
    function getRThreshold() external view returns (uint256) {
        return _rThreshold;
    }

    /**
     * @notice Gets current Haircut parameter
     * @return The current Haircut parameter in Pool
     */
    function getHaircutRate() external view returns (uint256) {
        return _haircutRate;
    }

    /**
     * @notice Gets current retention ratio parameter
     * @return The current retention ratio parameter in Pool
     */
    function getRetentionRatio() external view returns (uint256) {
        return _retentionRatio;
    }

    /**
     * @dev pause pool, restricting certain operations
     */
    function pause() external onlyDev {
        _pause();
    }

    /**
     * @dev unpause pool, enabling certain operations
     */
    function unpause() external onlyDev {
        _unpause();
    }

    // Setters //
    /**
     * @notice Changes the contract dev. Can only be set by the contract owner.
     * @param dev new contract dev address
     */
    function setDev(address dev) external onlyOwner {
        if (dev == address(0)) revert Pool_AddressShouldNotBeZero();
        emit DevUpdated(_dev, dev);
        _dev = dev;
    }

    /**
     * @notice Changes the pool rThreshold param. Can only be set by the contract owner.
     * @param rThreshold_ new pool's rThreshold param
     */
    function setRThreshold(uint256 rThreshold_) external onlyOwner {
        if (rThreshold_ == 0 || rThreshold_ > ETH_UNIT) revert Pool_InvalidRThreshold();

        emit ParamRThresholdUpdated(_rThreshold, rThreshold_);
        _rThreshold = rThreshold_;
    }

    /**
     * @notice Changes the pools haircutRate. Can only be set by the contract owner.
     * @param haircutRate_ new pool's haircutRate_
     */
    function setHaircutRate(uint256 haircutRate_) external onlyOwner {
        if (haircutRate_ > ETH_UNIT) revert Pool_InvalidHaircutRate();
        emit HaircutRateUpdated(_haircutRate, haircutRate_);
        _haircutRate = haircutRate_;
    }

    /**
     * @notice Changes the pools retentionRatio. Can only be set by the contract owner.
     * @param retentionRatio_ new pool's retentionRatio
     */
    function setRetentionRatio(uint256 retentionRatio_) external onlyOwner {
        if (retentionRatio_ > ETH_UNIT) revert Pool_InvalidRetentionRatio();
        emit RetentionRatioUpdated(_retentionRatio, retentionRatio_);
        _retentionRatio = retentionRatio_;
    }

    // Asset struct functions //

    /**
     * @notice Gets asset with token address key
     * @param key The address of token
     * @return the corresponding asset in state
     */
    function _getAsset(address key) private view returns (Asset) {
        return _assets.values[key];
    }

    /**
     * @notice Looks if the asset is contained by the list
     * @param key The address of token to look for
     * @return bool true if the asset is in asset list, false otherwise
     */
    function _containsAsset(address key) private view returns (bool) {
        return _assets.inserted[key];
    }

    /**
     * @notice Adds asset to the list
     * @param key The address of token to look for
     * @param val The asset to add
     */
    function _addAsset(address key, Asset val) private {
        _assets.inserted[key] = true;
        _assets.values[key] = val;
        _assets.indexOf[key] = _assets.keys.length;
        _assets.keys.push(key);
    }

    /**
     * @notice Removes asset from asset struct
     * @dev Can only be called by owner
     * @param key The address of token to remove
     */
    function removeAsset(address key) external onlyOwner {
        if (!_assets.inserted[key]) {
            return;
        }

        delete _assets.inserted[key];
        delete _assets.values[key];

        uint256 index = _assets.indexOf[key];
        uint256 lastIndex = _assets.keys.length - 1;
        address lastKey = _assets.keys[lastIndex];

        _assets.indexOf[lastKey] = index;
        delete _assets.indexOf[key];

        _assets.keys[index] = lastKey;
        _assets.keys.pop();
    }

    // Pool Functions //
    /**
     * @notice Adds asset to pool, reverts if asset already exists in pool
     * @param token The address of token
     * @param asset The address of the mobius Asset contract
     */
    function addAsset(address token, address asset) external onlyOwner {
        if (token == address(0)) revert Pool_AddressShouldNotBeZero();
        if (IERC20Metadata(token).decimals() > 18) revert Pool_InvalidTokenDecimals();
        if (asset == address(0)) revert Pool_AddressShouldNotBeZero();
        if (_containsAsset(token)) revert Pool_AssetAlreadyExists();

        _addAsset(token, Asset(asset));

        emit AssetAdded(token, asset);
    }

    /**
     * @notice Gets Asset corresponding to ERC20 token. Reverts if asset does not exists in Pool.
     * @param token The address of ERC20 token
     */
    function _assetOf(address token) private view returns (Asset) {
        if (!_containsAsset(token)) revert Pool_AssetDoesNotExist();
        return _getAsset(token);
    }

    /**
     * @notice Gets Asset corresponding to ERC20 token. Reverts if asset does not exists in Pool.
     * @dev to be used externally
     * @param token The address of ERC20 token
     */
    function assetOf(address token) external view returns (address) {
        return address(_assetOf(token));
    }

    /**
     * @notice Deposits asset in Pool
     * @param asset The asset to be deposited
     * @param amountInWad The amount to be deposited in WAD
     * @param to The user accountable for deposit, receiving the mobius assets (lp)
     * @return liquidity Total asset liquidity minted
     */
    function _deposit(Asset asset, uint256 amountInWad, address to) private returns (uint256 liquidity) {
        uint256 totalSupply = asset.totalSupply();
        uint256 liability = asset.liability();

        // Calculate amount of LP to mint : deposit * TotalAssetSupply / Liability
        if (liability == 0) {
            liquidity = amountInWad;
        } else {
            liquidity = _tokenAmountToLiquidity(amountInWad, liability, totalSupply);
        }

        if (liquidity == 0) revert Pool_DustAmount();

        asset.addCash(amountInWad);
        asset.addLiability(amountInWad);
        asset.mint(to, liquidity);
    }

    /**
     * @notice Deposits amount of tokens into pool ensuring deadline
     * @dev Asset needs to be created and added to pool before any operation
     * @param token The token address to be deposited
     * @param amount The amount to be deposited, in token decimals
     * @param to The user accountable for deposit, receiving the mobius assets (lp)
     * @param deadline The deadline to be respected
     * @return liquidity Total asset liquidity minted
     */
    function deposit(address token, uint256 amount, address to, uint256 deadline)
        external
        conditionallySingleCallPerTransaction
        before(deadline)
        nonReentrant
        whenNotPaused
        addressNonZero(to)
        returns (uint256 liquidity)
    {
        if (amount == 0) revert Pool_InputAmountZero();

        IERC20 erc20 = IERC20(token);
        Asset asset = _assetOf(token);

        erc20.safeTransferFrom(address(msg.sender), address(asset), amount);
        liquidity = _deposit(asset, _toWad(amount, asset.underlyingTokenDecimals()), to);
        emit Deposit(msg.sender, token, amount, liquidity, to);
    }

    /**
     * @notice Calculates fee and liability to burn in case of withdrawal
     * @param asset The asset willing to be withdrawn
     * @param liquidity The liquidity willing to be withdrawn
     * @return amountInWad Total amount to be withdrawn from Pool
     * @return liabilityToBurn Total liability to be burned by Pool
     * @return feeInWad The fee of the withdraw operation
     */
    function _quoteWithdraw(Asset asset, uint256 liquidity)
        private
        view
        returns (uint256 amountInWad, uint256 liabilityToBurn, uint256 feeInWad)
    {
        uint256 assetCash = asset.cash();
        uint256 assetLiability = asset.liability();
        uint256 assetTotalSupply = asset.totalSupply();

        liabilityToBurn = _liquidityToTokenAmount(liquidity, assetLiability, assetTotalSupply);
        if (liabilityToBurn == 0) revert Pool_DustAmount();

        feeInWad = _withdrawalFee(_rThreshold, assetCash, assetLiability, liabilityToBurn);
        amountInWad = liabilityToBurn - feeInWad;

        // ensure enough cash
        if (assetCash < amountInWad) revert Pool_InsufficientCash();
    }

    /**
     * @notice Withdraws liquidity amount of asset to `to` address ensuring minimum amount required
     * @param asset The asset to be withdrawn
     * @param liquidity The liquidity to be withdrawn
     * @param minimumAmount The minimum amount that will be accepted by user
     * @param to The user receiving the withdrawal
     * @return amount The total amount withdrawn
     */
    function _withdraw(Asset asset, uint256 liquidity, uint256 minimumAmount, address to)
        private
        returns (uint256 amount)
    {
        // calculate liabilityToBurn and Fee
        uint256 liabilityToBurn;
        uint256 amountInWad;
        (amountInWad, liabilityToBurn,) = _quoteWithdraw(asset, liquidity);

        // require amount to be higher than the amount specified
        if (_toWad(minimumAmount, asset.underlyingTokenDecimals()) > amountInWad) {
            revert Pool_OutputAmountLessThanRequested();
        }

        asset.burn(msg.sender, liquidity);
        asset.removeCash(amountInWad);
        asset.removeLiability(liabilityToBurn);

        // if it is not a full withdrawal, check if cov ratio >= rThreshold
        if (asset.liability() > 0) {
            if (_coverageRatio(asset.cash(), asset.liability()) < _rThreshold) {
                revert Pool_CoverageRatioTooLow();
            }
        }

        amount = _fromWad(amountInWad, asset.underlyingTokenDecimals());
        asset.transferUnderlyingToken(to, amount);
    }

    /**
     * @notice Withdraws liquidity amount of asset to `to` address ensuring minimum amount required
     * @param token The token to be withdrawn
     * @param liquidity The liquidity to be withdrawn
     * @param minimumAmount The minimum amount that will be accepted by user
     * @param to The user receiving the withdrawal
     * @param deadline The deadline to be respected
     * @return amount The total amount withdrawn, in token decimals
     */
    function withdraw(address token, uint256 liquidity, uint256 minimumAmount, address to, uint256 deadline)
        external
        conditionallySingleCallPerTransaction
        before(deadline)
        nonReentrant
        whenNotPaused
        addressNonZero(to)
        returns (uint256 amount)
    {
        if (liquidity == 0) revert Pool_InputAmountZero();

        Asset asset = _assetOf(token);
        amount = _withdraw(asset, liquidity, minimumAmount, to);

        emit Withdraw(msg.sender, token, amount, liquidity, to);
    }

    /**
     * @notice Enables withdrawing liquidity from an asset using LP from a different asset in the same aggregate
     * @param initialToken The corresponding token user holds the LP (Asset) from
     * @param wantedToken The token wanting to be withdrawn (needs to be well covered)
     * @param liquidity The liquidity of the initial token to be withdrawn (in WAD)
     * @param minimumAmount The minimum amount that will be accepted by user (in wantedToken decimals)
     * @param to The user receiving the withdrawal
     * @param deadline The deadline to be respected
     * @dev initialToken and wantedToken assets' must be in the same aggregate
     * @dev Also, cov of wantedAsset must be higher than 1 after withdrawal for this to be accepted
     * @return amount The total amount withdrawn, in wantedToken decimals
     */
    function withdrawFromOtherAsset(
        address initialToken,
        address wantedToken,
        uint256 liquidity,
        uint256 minimumAmount,
        address to,
        uint256 deadline
    )
        external
        conditionallySingleCallPerTransaction
        before(deadline)
        nonReentrant
        whenNotPaused
        addressNonZero(to)
        returns (uint256 amount)
    {
        if (liquidity == 0) revert Pool_InputAmountZero();
        if (initialToken == wantedToken) revert Pool_TokensShouldBeDifferent();

        // get corresponding assets
        Asset initialAsset = _assetOf(initialToken);
        Asset wantedAsset = _assetOf(wantedToken);
        _checkSameAggregateAccount(initialAsset, wantedAsset);

        // initialAsset should have cov ratio < 1
        if (_coverageRatio(initialAsset.cash(), initialAsset.liability()) >= ETH_UNIT) {
            revert Pool_CoverageRatioTooHigh();
        }

        // converts LP token of initial asset to equivalent value of LP token of wantedAsset
        uint256 tokenAmount = _liquidityToTokenAmount(liquidity, initialAsset.liability(), initialAsset.totalSupply());
        uint256 liquidityInWantedAsset =
            _tokenAmountToLiquidity(tokenAmount, wantedAsset.liability(), wantedAsset.totalSupply());

        // require liquidity in wanted asset to be > 0
        if (liquidityInWantedAsset == 0) revert Pool_DustAmount();

        // calculate liabilityToBurn and amount
        uint256 amountInWad;
        (amountInWad,,) = _quoteWithdraw(wantedAsset, liquidityInWantedAsset);
        amount = _fromWad(amountInWad, wantedAsset.underlyingTokenDecimals());
        // require amount to be higher than the amount specified
        if (amount < minimumAmount) revert Pool_OutputAmountLessThanRequested();

        // calculate liability to burn in initialAsset
        uint256 liabilityToBurn =
            _liquidityToTokenAmount(liquidity, initialAsset.liability(), initialAsset.totalSupply());

        // burn initial asset liquidity
        initialAsset.burn(address(msg.sender), liquidity);
        initialAsset.removeLiability(liabilityToBurn); // remove liability from initial asset
        wantedAsset.removeCash(amountInWad); // remove cash from wanted asset

        wantedAsset.transferUnderlyingToken(to, amount); // transfer wanted token to user
        emit Withdraw(msg.sender, wantedToken, amount, liquidity, to);

        // require post-withdrawal coverage of wantedAsset to >= 1
        uint256 postWithdrawalCoverage = _coverageRatio(wantedAsset.cash(), wantedAsset.liability());
        if (postWithdrawalCoverage < ETH_UNIT) revert Pool_CoverageRatioTooLow();
    }

    /**
     * @notice Swap fromToken for toToken, ensures deadline and minimumToAmount and sends quoted amount to `to` address
     * @param fromToken The token being inserted into Pool by user for swap
     * @param toToken The token wanted by user, leaving the Pool
     * @param fromAmount The amount of from token inserted
     * @param minimumToAmount The minimum amount that will be accepted by user as result, in toToken decimals
     * @param to The user receiving the result of swap
     * @param deadline The deadline to be respected
     * @return actualToAmount The actual amount user receive, in toToken decimals
     * @return haircut The haircut that would be applied, in toToken decimals
     */
    function swap(
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 minimumToAmount,
        address to,
        uint256 deadline
    )
        external
        conditionallySingleCallPerTransaction
        before(deadline)
        nonReentrant
        whenNotPaused
        validSwap(fromToken, toToken, fromAmount)
        addressNonZero(to)
        returns (uint256 actualToAmount, uint256 haircut)
    {
        IERC20 fromERC20 = IERC20(fromToken);
        Asset fromAsset = _assetOf(fromToken);
        Asset toAsset = _assetOf(toToken);
        _checkSameAggregateAccount(fromAsset, toAsset);

        uint256 actualToAmountInWad;
        uint256 haircutInWad;
        (actualToAmountInWad, haircutInWad) =
            _quoteSwap(fromAsset, toAsset, _toWad(fromAmount, fromAsset.underlyingTokenDecimals()));

        actualToAmount = _fromWad(actualToAmountInWad, toAsset.underlyingTokenDecimals());
        haircut = _fromWad(haircutInWad, toAsset.underlyingTokenDecimals());

        // require actualToAmount to be higher than the amount specified
        if (actualToAmount < minimumToAmount) revert Pool_OutputAmountLessThanRequested();

        fromERC20.safeTransferFrom(address(msg.sender), address(fromAsset), fromAmount);
        fromAsset.addCash(_toWad(fromAmount, fromAsset.underlyingTokenDecimals()));
        toAsset.removeCash(actualToAmountInWad);
        toAsset.addLiability(_dividend(haircutInWad, _retentionRatio));
        toAsset.transferUnderlyingToken(to, actualToAmount);

        emit Swap(msg.sender, fromToken, toToken, fromAmount, actualToAmount, to);

        // require post-swap coverage for toAsset to be >= rThreshold
        if (_coverageRatio(toAsset.cash(), toAsset.liability()) < _rThreshold) {
            revert Pool_CoverageRatioTooLow();
        }
    }

    /**
     * @notice Quotes the actual amount user would receive in a swap, taking in account solvency and haircut
     * @param fromAsset The initial asset
     * @param toAsset The asset wanted by user
     * @param fromAmount The amount to quote, in WAD
     * @return actualToAmount The actual amount user would receive, in WAD
     * @return haircut The haircut that will be applied, in WAD
     */
    function _quoteSwap(Asset fromAsset, Asset toAsset, uint256 fromAmount)
        private
        view
        returns (uint256 actualToAmount, uint256 haircut)
    {
        uint256 idealToAmount = fromAmount;
        if (toAsset.cash() < idealToAmount) revert Pool_InsufficientCash();

        uint256 solvencyFrom = _solvencyScore(_rThreshold, fromAsset.cash(), fromAsset.liability(), fromAmount, true);
        uint256 solvencyTo = _solvencyScore(_rThreshold, toAsset.cash(), toAsset.liability(), idealToAmount, false);
        uint256 toAmount = _computeToAmount(solvencyFrom, solvencyTo, idealToAmount);
        haircut = _haircut(toAmount, _haircutRate);
        actualToAmount = toAmount - haircut;
    }

    /**
     * @notice Quotes potential outcome of a swap given current state, taking in account solvency and haircut
     * @dev To be used by frontend
     * @param fromToken The initial ERC20 token
     * @param toToken The token wanted by user
     * @param fromAmount The amount to quote, in fromToken decimals
     * @return toAmount The potential amount user would receive, in toToken decimals
     * @return haircut The haircut that would be applied, in toToken decimals
     */
    function quotePotentialSwap(address fromToken, address toToken, uint256 fromAmount)
        external
        view
        whenNotPaused
        validSwap(fromToken, toToken, fromAmount)
        returns (uint256 toAmount, uint256 haircut)
    {
        Asset fromAsset = _assetOf(fromToken);
        Asset toAsset = _assetOf(toToken);
        _checkSameAggregateAccount(fromAsset, toAsset);

        (uint256 toAmountInWad, uint256 haircutInWad) =
            _quoteSwap(fromAsset, toAsset, _toWad(fromAmount, fromAsset.underlyingTokenDecimals()));

        toAmount = _fromWad(toAmountInWad, toAsset.underlyingTokenDecimals());
        haircut = _fromWad(haircutInWad, toAsset.underlyingTokenDecimals());

        // require post-swap coverage for toAsset to be >= rThreshold
        if (
            _coverageRatio(
                toAsset.cash() - toAmountInWad, toAsset.liability() + _dividend(haircutInWad, _retentionRatio)
            ) < _rThreshold
        ) {
            revert Pool_CoverageRatioTooLow();
        }
    }

    /**
     * @notice Quotes potential withdrawal from pool
     * @dev To be used by frontend
     * @param token The token to be withdrawn by user
     * @param liquidity The liquidity (amount of lp assets) to be withdrawn
     * @return amount The potential amount user would receive
     * @return fee The fee that would be applied
     */
    function quotePotentialWithdraw(address token, uint256 liquidity)
        external
        view
        whenNotPaused
        returns (uint256 amount, uint256 fee)
    {
        if (liquidity == 0) revert Pool_InputAmountZero();
        Asset asset = _assetOf(token);
        uint256 amountInWad;
        uint256 feeInWad;
        uint256 liabilityToBurn;
        (amountInWad, liabilityToBurn, feeInWad) = _quoteWithdraw(asset, liquidity);
        amount = _fromWad(amountInWad, asset.underlyingTokenDecimals());
        fee = _fromWad(feeInWad, asset.underlyingTokenDecimals());

        // if it is not a full withdrawal, check if cov ratio >= rThreshold
        if (asset.liability() - liabilityToBurn > 0) {
            if (_coverageRatio(asset.cash() - amountInWad, asset.liability() - liabilityToBurn) < _rThreshold) {
                revert Pool_CoverageRatioTooLow();
            }
        }
    }

    /**
     * @notice Quotes potential withdrawal from other asset in the same aggregate
     * @dev To be used by frontend. Reverts if not possible
     * @param initialToken The users holds LP corresponding to this initial token
     * @param wantedToken The token to be withdrawn by user
     * @param liquidity The liquidity of the initial token to be withdrawn (in WAD)
     * @return amount The potential amount user would receive
     * @return fee The fee that would be applied
     */
    function quotePotentialWithdrawFromOtherAsset(address initialToken, address wantedToken, uint256 liquidity)
        external
        view
        whenNotPaused
        returns (uint256 amount, uint256 fee)
    {
        if (liquidity == 0) revert Pool_InputAmountZero();
        if (initialToken == wantedToken) revert Pool_TokensShouldBeDifferent();

        Asset initialAsset = _assetOf(initialToken);
        Asset wantedAsset = _assetOf(wantedToken);
        _checkSameAggregateAccount(initialAsset, wantedAsset);
        // initialAsset should have cov ratio < 1
        if (_coverageRatio(initialAsset.cash(), initialAsset.liability()) >= ETH_UNIT) {
            revert Pool_CoverageRatioTooHigh();
        }

        // converts LP token of initial asset to equivalent value of LP token of wantedAsset
        uint256 tokenAmount = _liquidityToTokenAmount(liquidity, initialAsset.liability(), initialAsset.totalSupply());
        uint256 liquidityInWantedAsset =
            _tokenAmountToLiquidity(tokenAmount, wantedAsset.liability(), wantedAsset.totalSupply());

        uint256 amountInWad;
        uint256 feeInWad;
        (amountInWad,, feeInWad) = _quoteWithdraw(wantedAsset, liquidityInWantedAsset);
        amount = _fromWad(amountInWad, wantedAsset.underlyingTokenDecimals());
        fee = _fromWad(feeInWad, wantedAsset.underlyingTokenDecimals());
        if (amount == 0) revert Pool_DustAmount();

        // require post-withdrawal coverage for wantedAsset to >= 1
        uint256 postWithdrawalCash = wantedAsset.cash() - amountInWad;
        uint256 postWithdrawalLiability = wantedAsset.liability();
        uint256 postWithdrawalCoverage = _coverageRatio(postWithdrawalCash, postWithdrawalLiability);
        if (postWithdrawalCoverage < ETH_UNIT) revert Pool_CoverageRatioTooLow();
    }

    /// @notice Gets max withdrawable amount in initial token
    /// @notice Taking into account that coverage must be over >= 1 in wantedAsset
    /// @param initialToken the initial token to be evaluated
    /// @param wantedToken the wanted token to withdraw in
    /// @return maxInitialLiquidityAmount the maximum amount of initialToken liquidity that can be used to withdraw wantedToken
    function quoteMaxInitialLiquidityWithdrawable(address initialToken, address wantedToken)
        external
        view
        whenNotPaused
        returns (uint256 maxInitialLiquidityAmount)
    {
        Asset initialAsset = _assetOf(initialToken);
        Asset wantedAsset = _assetOf(wantedToken);
        if (initialAsset == wantedAsset) revert Pool_TokensShouldBeDifferent();

        uint256 wantedAssetCov = _coverageRatio(wantedAsset.cash(), wantedAsset.liability());

        if (wantedAssetCov > ETH_UNIT) {
            uint256 excessCoverage = wantedAssetCov - ETH_UNIT;
            uint256 maxWantedLiquidityAmount = excessCoverage * wantedAsset.totalSupply() / ETH_UNIT;
            uint256 maxWantedTokenAmount =
                _liquidityToTokenAmount(maxWantedLiquidityAmount, wantedAsset.liability(), wantedAsset.totalSupply());
            uint256 maxInitialTokenAmount = maxWantedTokenAmount;
            maxInitialLiquidityAmount =
                _tokenAmountToLiquidity(maxInitialTokenAmount, initialAsset.liability(), initialAsset.totalSupply());
        } else {
            maxInitialLiquidityAmount = 0;
        }
    }

    /**
     * @notice Gets addresses of underlying token in pool
     * @dev To be used externally
     * @return addresses of assets in the pool
     */
    function getTokenAddresses() external view returns (address[] memory) {
        return _assets.keys;
    }
}
