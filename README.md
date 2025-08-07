# Möbius Exchange Contracts

## Contracts

### Pool

The Möbius protocol features two types of pools:

**StablePool**: A pool designed for stable assets (like USDC, USDT, USDe) that maintains 1:1 price ratios. It uses the standard `Asset` contract and implements the core Möbius AMM logic with solvency-based pricing.

**VariantPool**: A pool designed for pegged assets with a gradually changing rates (like ETH, cmETH, mETH) that can have varying price ratios. It uses `VariantAsset` contracts that implement price feeds to determine relative prices between assets.

Both pools inherit from `Core` which contains the mathematical formulas for:
- Solvency curve calculations
- Swap rate computations using solvency scores
- Withdrawal fee calculations
- Token amount conversions

Key features:
- **Deposit/Withdrawal**: Users can deposit tokens to receive LP tokens and withdraw tokens by burning LP tokens
- **Swaps**: Direct token-to-token swaps with solvency-based pricing
- **Cross-asset withdrawals**: Withdraw one asset using LP tokens from another asset
- **Haircut fees**: Small fees applied to swaps (0.03% default)
- **Retention ratio**: Controls how much of fees go to LPs vs pool surplus

### Asset

Assets represent tokens within a pool and are implemented as ERC20 LP tokens:

**Standard Asset**: Used in StablePool, represents stable assets with 1:1 price ratios.

**VariantAsset**: Used in VariantPool, represents volatile assets with price feeds. Subclasses like `cmETHAsset` and `mETHAsset` implement price oracle integration to determine relative prices.

Key features:
- **LP Token**: Each asset mints/burns LP tokens representing pool share
- **Cash/Liability tracking**: Tracks actual token balance and total liability
- **Max supply**: Configurable supply caps for risk management
- **Aggregate accounts**: Groups related assets together

### Router

The `MobiusRouter` provides a unified interface for multi-hop swaps across different pools:

**Key Functions**:
- `swapTokensForTokens()`: Execute multi-hop swaps through multiple pools
- `quotePotentialSwaps()`: Get quotes for potential swap outcomes
- `approveSpendingByPool()`: Approve tokens for pool spending

**Features**:
- **Multi-hop routing**: Swap through multiple pools in a single transaction
- **Path optimization**: Route through optimal pools for best rates
- **Deadline protection**: Prevent stale transactions
- **Slippage protection**: Ensure minimum output amounts

## DEX Aggregator Integration

Other protocols can integrate with Möbius pools for token swaps in several ways:

#### Direct Pool Integration

```solidity
// Direct swap through a single pool
IPool pool = IPool(poolAddress);
(uint256 amountOut, uint256 haircut) = pool.swap(
    fromToken,
    toToken, 
    fromAmount,
    minimumToAmount,
    recipient,
    deadline
);
```

#### Router Integration (Recommended)

```solidity
// Multi-hop swap through router
IMobiusRouter router = IMobiusRouter(routerAddress);
address[] memory tokenPath = [tokenA, tokenB, tokenC];
address[] memory poolPath = [pool1, pool2];
(uint256 amountOut, uint256 haircut) = router.swapTokensForTokens(
    tokenPath,
    poolPath,
    fromAmount,
    minimumToAmount,
    recipient,
    deadline
);
```

#### Quote Integration

```solidity
// Get swap quotes before execution
(uint256 toAmount, uint256 haircut) = pool.quotePotentialSwap(
    fromToken,
    toToken,
    fromAmount
);
```

#### Integration Best Practices

1. **Always use quotes**: Get potential swap outcomes before executing
2. **Set appropriate slippage**: Use `minimumToAmount` to protect against slippage
3. **Handle deadlines**: Set reasonable deadlines to prevent stale transactions
4. **Check pool state**: Verify pools are not paused before swapping
5. **Monitor haircuts**: Account for swap fees in your calculations

#### Example Integration Contract

```solidity
contract MobiusIntegration {
    IMobiusRouter public immutable router;
    
    constructor(address _router) {
        router = IMobiusRouter(_router);
    }
    
    function swapTokens(
        address[] calldata tokenPath,
        address[] calldata poolPath,
        uint256 fromAmount,
        uint256 minimumToAmount
    ) external returns (uint256 amountOut, uint256 haircut) {
        // Transfer tokens from user to this contract
        IERC20(tokenPath[0]).transferFrom(msg.sender, address(this), fromAmount);
        
        // Approve router to spend tokens
        IERC20(tokenPath[0]).approve(address(router), fromAmount);
        
        // Execute swap
        (amountOut, haircut) = router.swapTokensForTokens(
            tokenPath,
            poolPath,
            fromAmount,
            minimumToAmount,
            msg.sender, // Send tokens directly to user
            block.timestamp + 300 // 5 minute deadline
        );
    }
}
```

## Deployment contracts

### Mantle Mainnet

Deployment StablePool on Mantle Mainnet

| Contract Name    | Address                                    |
| ---------------- | ------------------------------------------ |
| StablePool             | 0x3c056E0efaE7218b257868734b1dA7719B41F920 |
| StablePool Proxy Admin | 0x700Bca702333C6f15aE9AadACf698009d5E57c47 |
| USDe                   | 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34 |
| LP-USDe                | 0x362F4D6F539201dB13A7305369a48FaC58960be5 |
| LP-USDe    Proxy Admin | 0xD4b0285C8eB4fAFeBB2dd3651C28EE4b342b1fc2 |
| USDC                   | 0x09Bc4E0D864854c6aFB6eB9A9cdF58aC190D0dF9 |
| LP-USDC                | 0xb8Ca9787Cf03c6f1fA6ef207aB93e875F3B84426 |
| LP-USDC    Proxy Admin | 0xe4979c6bd07b8E5d153D824d7C5a5F55Cb559863 |
| USDT                   | 0x201EBa5CC46D216Ce6DC03F6a759e8E766e956aE |
| LP-USDT                | 0x6A7D252b807887AfEE870d14C5D7eb25f00A7044 |
| LP-USDT    Proxy Admin | 0xA439255d28132642A5cC82F1DD9C08511Af02ae2 |
| AggregateAccount       | 0x7f63b4B1B9177BD064040D4F7ceBEef328f33e20 |

Deployment VariantPool on Mantle Mainnet

| Contract Name    | Address                                    |
| ---------------- | ------------------------------------------ |
| VariantPool             | 0xF95595635D4b09aE4c662069e82CA43012118707 |
| VariantPool Proxy Admin | 0x6Fbd633F00ff80907a9813E7A36d560B3974616E |
| cmETH                   | 0xE6829d9a7eE3040e1276Fa75293Bde931859e8fA |
| LP-cmETH                | 0x801f29bB8fa066b71bF2f4e1Af34D7E4682cCecc |
| LP-cmETH    Proxy Admin | 0x094939b373f61F68b17705DA4A873D11883d6eF5 |
| mETH                    | 0xcDA86A272531e8640cD7F1a92c01839911B90bb0 |
| LP-mETH                 | 0x88837Ef995907016C5ca0776693f6B2339A44E35 |
| LP-mETH     Proxy Admin | 0x98b909C4bcDbb6802adE20851e52a0562DE6e35E |
| WETH                    | 0xdEAddEaDdeadDEadDEADDEAddEADDEAddead1111 |
| LP-WETH                 | 0x6d01Ad49e74aa488EB293c1869D4aCDC39359B4b |
| LP-WETH     Proxy Admin | 0x90F9471E8A97D0732579898009c9927F4AD67a27 |
| AggregateAccount        | 0x927348962E7Bf9e156845585Cf858c613D389f4B |

Deployment Router on Mantle Mainnet

| Contract Name | Address                                    |
| ------------- | ------------------------------------------ |
| Router        | 0x06367aDe2EFEEe82C0E27390db4fc2fAE80308b6 |
