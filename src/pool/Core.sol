// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.22;

import {UD60x18, ud, UNIT} from "@prb/math/src/UD60x18.sol";

/**
 * @title Core
 * @notice Handles math operations of Mobius protocol.
 * @dev Utilizes prb math for precision accuracy, protection against overflow and underflow, and gas efficiency in math operations.
 */
contract Core {
    /// @notice Accommodates unforeseen upgrades to Core.
    bytes32[64] internal __gap;

    /// Errors
    error LiabilityZero();
    error TotalSupplyZero();
    error RThresholdZero();
    error RZero();
    error PriceZero();

    /**
     * @notice Convert x from d decimals to WAD (18 decimals).
     * @param x The uint256 amount that is upscaled to d decimals.
     * @param d The number of decimals of the input amount.
     * @return The amount in WAD.
     */
    function _toWad(uint256 x, uint8 d) internal pure returns (uint256) {
        if (d < 18) {
            return x * 10 ** (18 - d);
        } else if (d > 18) {
            return (x / (10 ** (d - 18)));
        }
        return x;
    }

    /**
     * @notice Convert x from WAD (18 decimals) to d decimals.
     * @param x The amount in WAD to convert from
     * @param d The number of decimals of the output amount.
     * @return The amount in d decimals.
     */
    function _fromWad(uint256 x, uint8 d) internal pure returns (uint256) {
        if (d < 18) {
            return (x / (10 ** (18 - d)));
        } else if (d > 18) {
            return x * 10 ** (d - 18);
        }
        return x;
    }

    /**
     * @notice Whitepaper Def. 2.1 coverage ratio
     * @dev coverage ratio = cash / liability. Make sure liability is not 0 before calling this function.
     * @param cashInWad cash position of asset in WAD
     * @param liabilityInWad liability position of asset in WAD
     * @return The coverage ratio of the asset, in WAD
     */
    function _coverageRatio(uint256 cashInWad, uint256 liabilityInWad) internal pure returns (uint256) {
        UD60x18 cash = ud(cashInWad);
        UD60x18 liability = ud(liabilityInWad);

        if (liability == ud(0)) revert LiabilityZero();

        return (cash / liability).unwrap();
    }

    /**
     * @notice Whitepaper Def. 5.1 Converts LP token amount to token amount
     * @dev LP token to underlying token amount ratio = liability / total supply
     * @param liquidityInWad amount of LP token in WAD
     * @param liabilityInWad liability of asset in WAD
     * @param totalSupplyInWad total supply of asset in WAD
     * @return The token amount of the asset, in WAD
     */
    function _liquidityToTokenAmount(uint256 liquidityInWad, uint256 liabilityInWad, uint256 totalSupplyInWad)
        internal
        pure
        returns (uint256)
    {
        UD60x18 liquidity = ud(liquidityInWad);
        UD60x18 liability = ud(liabilityInWad);
        UD60x18 totalSupply = ud(totalSupplyInWad);

        if (totalSupply == ud(0)) revert TotalSupplyZero();
        if (liability == ud(0)) revert LiabilityZero();
        return (liquidity * liability / totalSupply).unwrap();
    }

    /**
     * @notice Whitepaper Def. 5.1 Converts token amount to LP token amount
     * @dev underlying token to LP token amount ratio = total supply / liability
     * @param tokenAmountInWad amount of token in WAD
     * @param liabilityInWad liability of asset in WAD
     * @param totalSupplyInWad total supply of asset in WAD
     * @return The LP token amount of the asset, in WAD
     */
    function _tokenAmountToLiquidity(uint256 tokenAmountInWad, uint256 liabilityInWad, uint256 totalSupplyInWad)
        internal
        pure
        returns (uint256)
    {
        UD60x18 tokenAmount = ud(tokenAmountInWad);
        UD60x18 liability = ud(liabilityInWad);
        UD60x18 totalSupply = ud(totalSupplyInWad);

        if (totalSupply == ud(0)) revert TotalSupplyZero();
        if (liability == ud(0)) revert LiabilityZero();
        return (tokenAmount * totalSupply / liability).unwrap();
    }

    /**
     * @notice Whitepaper Formula 4.2 compute the definite integral F(r) = ∫ -p(s) ds from r to 1
     * @dev integral of the solvency curve
     * @param rThresInWad r threshold parameter in WAD
     * @param rInWad coverage ratio of asset in WAD
     * @return The value of the integral of the solvency curve, in WAD
     */
    function _solvencyCurveIntegral(uint256 rThresInWad, uint256 rInWad) internal pure returns (uint256) {
        UD60x18 r = ud(rInWad);
        UD60x18 rThres = ud(rThresInWad);

        if (rThres == ud(0)) revert RThresholdZero();
        if (r == ud(0)) revert RZero();

        // case 1: r <= rThres
        if (r <= rThres) {
            return ((UNIT - rThres) / ud(5e18) + rThres - r).unwrap();
        } else if (r < UNIT) {
            // case 2: rThres < r < UNIT
            return ((UNIT - r).powu(5) / (ud(5e18) * (UNIT - rThres).powu(4))).unwrap();
        } else {
            // case 3: r >= UNIT
            return 0;
        }
    }

    /**
     * @notice Whitepaper Def. 4.1 compute the value of ∫ -p(r) dr from r_lower to r_upper / (r_upper - r_lower)
     * @param rThresInWad r threshold parameter in WAD
     * @param cashInWad cash position of asset in WAD
     * @param liabilityInWad liability position of asset in WAD
     * @param cashChangeInWad cashChange of asset in WAD
     * @param addCash true if we are adding cash, false otherwise
     * @return The solvency score of an asset during a change in cash position, always positive
     */
    function _solvencyScore(
        uint256 rThresInWad,
        uint256 cashInWad,
        uint256 liabilityInWad,
        uint256 cashChangeInWad,
        bool addCash
    ) internal pure returns (uint256) {
        UD60x18 a0 = ud(cashInWad);
        UD60x18 l0 = ud(liabilityInWad);
        if (l0 == ud(0)) revert LiabilityZero();

        UD60x18 covBefore = a0 / l0;
        UD60x18 covAfter;
        if (addCash) {
            covAfter = (a0 + ud(cashChangeInWad)) / l0;
        } else {
            covAfter = (a0 - ud(cashChangeInWad)) / l0;
        }

        // if cov stays unchanged, solvency score is 0
        if (covBefore == covAfter) {
            return 0;
        }

        UD60x18 solvencyIntegralBefore = ud(_solvencyCurveIntegral(rThresInWad, covBefore.unwrap()));
        UD60x18 solvencyIntegralAfter = ud(_solvencyCurveIntegral(rThresInWad, covAfter.unwrap()));

        if (covBefore > covAfter) {
            return ((solvencyIntegralAfter - solvencyIntegralBefore) / (covBefore - covAfter)).unwrap();
        } else {
            return ((solvencyIntegralBefore - solvencyIntegralAfter) / (covAfter - covBefore)).unwrap();
        }
    }

    /**
     * @notice Whitepaper Def. 4.1.  Swap rate
     * Computes the toAmount using the solvency scores and the given toAmount.
     * Uses the formula toAmount = fromAmount * (1 + Si - Sj)
     * @param siInWad solvency score of the from token in WAD
     * @param sjInWad solvency score of the to token in WAD
     * @param fromAmountInWad The initial fromAmount in WAD
     * @return The computed toAmount in WAD
     */
    function _computeToAmount(uint256 siInWad, uint256 sjInWad, uint256 fromAmountInWad)
        internal
        pure
        returns (uint256)
    {
        UD60x18 si = ud(siInWad);
        UD60x18 sj = ud(sjInWad);
        UD60x18 fromAmount = ud(fromAmountInWad);

        return (fromAmount * (UNIT + si - sj)).unwrap();
    }

    /**
     * @notice Applies haircut rate to amount
     * @param amountInWad The amount that will receive the discount, in WAD
     * @param rateInWad The rate to be applied, in WAD
     * @return The amount of haircut, in the same decimals as amount
     */
    function _haircut(uint256 amountInWad, uint256 rateInWad) internal pure returns (uint256) {
        UD60x18 amount = ud(amountInWad);
        UD60x18 rate = ud(rateInWad);
        return (amount * rate).unwrap();
    }

    /**
     * @notice Calculate the dividend to be paid to the LPs
     * @dev dividend ratio = 1 - retention ratio
     * @param amountInWad The amount that will receive the discount, in WAD
     * @param retentionRatioInWad The ratio to be stay in the pool surplus, in WAD
     * @return The amount of dividend, in WAD
     */
    function _dividend(uint256 amountInWad, uint256 retentionRatioInWad) internal pure returns (uint256) {
        UD60x18 amount = ud(amountInWad);
        UD60x18 retentionRatio = ud(retentionRatioInWad);

        return (amount * (UNIT - retentionRatio)).unwrap();
    }

    /**
     * @notice Whitepaper Formula 3.2. Withdrawal Fee
     * @dev When covBefore >= 1, fee is 0
     * @dev When covBefore < 1, we apply a fee to prevent withdrawal arbitrage
     * @param rThresInWad r threshold parameter in WAD
     * @param cash cash position of asset in WAD
     * @param liability liability position of asset in WAD
     * @param amountInWad amount of liability to be withdrawn in WAD
     * @return The final fee to be applied in WAD
     */
    function _withdrawalFee(uint256 rThresInWad, uint256 cash, uint256 liability, uint256 amountInWad)
        internal
        pure
        returns (uint256)
    {
        UD60x18 a0 = ud(cash);
        UD60x18 l0 = ud(liability);
        UD60x18 rThres = ud(rThresInWad);
        UD60x18 deltaLiability = ud(amountInWad);

        UD60x18 covBefore = a0 / l0;

        if (covBefore >= UNIT) {
            // case 1: covBefore >= 1, fee is 0
            return 0;
        } else {
            // case 2: covBefore < 1, we apply a fee to prevent withdrawal arbitrage
            // fee formula:
            // a = (l0 - t) * [1 - (( M * N ) / ( N + (M * l0^3 - N) * ((l0 - t)/l0)^3 ))^(1/3) ]
            // where: M = (1 - rThres)^4, N = (1 - a0/l0)^3 * l0^3
            UD60x18 M = (UNIT - rThres).powu(4);
            UD60x18 N = (UNIT - a0 / l0).powu(3).mul(l0.powu(3));
            UD60x18 t = deltaLiability;

            UD60x18 a =
                (l0 - t) * (UNIT - (M * N / (N + (M * l0.powu(3) - N) * ((l0 - t) / l0).powu(3))).pow(UNIT / ud(3e18)));

            // deltaCash = initial cash - post-withdraw cash = a0 - a
            // fee = the difference between the liability burned, and the cash withdrawn = deltaLiability - deltaCash

            assert(a < a0); // cash change should not be negative
            UD60x18 deltaCash = a0 - a;
            assert(deltaCash < deltaLiability); // fee should not be negative
            UD60x18 fee = deltaLiability - deltaCash;
            return fee.unwrap();
        }
    }

    /**
     * @notice Converts an amount from one token to another using their relative prices
     * such that the value of the amount in the destination token is equivalent to the value of the amount in the source token
     * @dev Formula: toAmount = fromAmount * (fromPrice / toPrice)
     * @param fromAmountInWad Amount of the source token (in WAD)
     * @param fromPriceInWad Price of the source token (in WAD)
     * @param toPriceInWad Price of the destination token (in WAD)
     * @return toAmountInWad Equivalent amount of the destination token (in WAD)
     */
    function _convertTokenAmount(uint256 fromAmountInWad, uint256 fromPriceInWad, uint256 toPriceInWad)
        internal
        pure
        returns (uint256 toAmountInWad)
    {
        UD60x18 fromAmount = ud(fromAmountInWad);
        UD60x18 fromPrice = ud(fromPriceInWad);
        UD60x18 toPrice = ud(toPriceInWad);

        if (toPrice == ud(0) || fromPrice == ud(0)) revert PriceZero();

        UD60x18 toAmount = fromAmount * fromPrice / toPrice;
        toAmountInWad = toAmount.unwrap();
    }
}
