# Möbius Pool Integration for DEX Aggregators

This repository contains Python code for integrating with Mobius pools, specifically designed for DEX aggregators. The implementation mirrors the mathematical functions from the Solidity contracts, allowing for accurate off-chain quote calculations.

## Overview

Möbius is a DeFi protocol with two types of pools:
- **StablePool**: For stable assets (USDe, USDC, USDT) using 1:1 exchange rates
- **VariantPool**: For variable assets (cmETH, mETH, WETH) using price oracles

## Key Features

- **Accurate Quote Calculation**: Implements the exact mathematical formulas from Core.sol
- **State Management**: Track pool state (cash, liability, coverage ratios) for off-chain calculations
- **Swap Construction**: Generate transaction parameters for direct pool swaps
- **Router Integration**: Support for multi-hop swaps through the Möbius router
- **Validation**: Pre-validate swaps before execution

## Installation

```bash
pip install decimal
```

## Quick Start

### 1. Create Pool Instance

```python
from mobius_pool_integration import MobiusPool, PoolConfig, create_mantle_mainnet_stable_pool

# Create a stable pool instance
pool = create_mantle_mainnet_stable_pool()
```

### 2. Update Pool State

```python
# Update asset state (call this regularly to sync with on-chain state)
pool.update_asset_state(
    token_address="0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34",  # USDe
    asset_address="0x362F4D6F539201dB13A7305369a48FaC58960be5",  # USDe Asset
    cash=1000000000000000000000,  # 1000 USDe in wei
    liability=1000000000000000000000,  # 1000 USDe in wei
    underlying_token_decimals=18,
    aggregate_account="0x7f63b4B1B9177BD064040D4F7ceBEef328f33e20",
    values_in_wad=True,  # Values are in WAD format
    price_wad=None  # Stable asset, no price needed
)

# For stable pools (no price needed)
pool.update_asset_state(
    token_address="0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34",  # USDe
    asset_address="0x362F4D6F539201dB13A7305369a48FaC58960be5",  # USDe Asset
    cash=1000000000000000000000,  # 1000 USDe in wei
    liability=1000000000000000000000,  # 1000 USDe in wei
    underlying_token_decimals=18,
    aggregate_account="0x7f63b4B1B9177BD064040D4F7ceBEef328f33e20",
    values_in_wad=True,  # Values are in WAD format
    price_wad=None  # Stable asset, no price needed
)

# For variant pools, include prices
pool.update_asset_state(
    token_address="0xE6829d9a7eE3040e1276Fa75293Bde931859e8fA",  # cmETH
    asset_address="0x801f29bB8fa066b71bF2f4e1Af34D7E4682cCecc",  # cmETH Asset
    cash=100000000000000000000,  # 100 cmETH in wei
    liability=100000000000000000000,  # 100 cmETH in wei
    underlying_token_decimals=18,
    aggregate_account="0x927348962E7Bf9e156845585Cf858c613D389f4B",
    values_in_wad=True,  # Values are in WAD format
    price_wad=1072690000000000000  # 1.07269 in WAD
)

# Or update prices separately
pool.update_asset_price(
    token_address="0xE6829d9a7eE3040e1276Fa75293Bde931859e8fA",  # cmETH
    price_wad=1072690000000000000  # 1.07269 in WAD
)
```

### 3. Get Quote

```python
# Get quote for a swap
to_amount, haircut = pool.quote_swap(
    from_token="0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34",  # USDe
    to_token="0x09Bc4E0D864854c6aFB6eB9A9cdF58aC190D0dF9",   # USDC
    from_amount=100000000000000000000  # 100 USDe
)

print(f"Output: {to_amount / (10**6)} USDC")  # USDC has 6 decimals
print(f"Haircut: {haircut / (10**6)} USDC")
```

### 4. Construct Swap Transaction (Note: Use Router for All Swaps)

```python
# Get swap parameters
swap_params = pool.get_swap_parameters(
    from_token="0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34",
    to_token="0x09Bc4E0D864854c6aFB6eB9A9cdF58aC190D0dF9",
    from_amount=100000000000000000000,
    minimum_to_amount=int(to_amount * 0.995),  # 0.5% slippage
    to_address="0x742d35Cc6634C0532925a3b8D4C9db96C4b4d8b6",
    deadline=1234567890
)

print(f"Function: {pool.get_swap_function_signature()}")
print(f"Pool Address: {pool.pool_address}")
print(f"Parameters: {swap_params}")
```

## Contract Addresses

### Mantle Mainnet

| Contract | Address |
|----------|---------|
| StablePool | `0x3c056E0efaE7218b257868734b1dA7719B41F920` |
| VariantPool | `0xF95595635D4b09aE4c662069e82CA43012118707` |
| Router | `0x06367aDe2EFEEe82C0E27390db4fc2fAE80308b6` |

**Tokens:**
- USDe: `0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34`
- USDC: `0x09Bc4E0D864854c6aFB6eB9A9cdF58aC190D0dF9`
- USDT: `0x201EBa5CC46D216Ce6DC03F6a759e8E766e956aE`
- cmETH: `0xE6829d9a7eE3040e1276Fa75293Bde931859e8fA`
- mETH: `0xcDA86A272531e8640cD7F1a92c01839911B90bb0`
- WETH: `0xdEAddEaDdeadDEadDEADDEAddEADDEAddead1111`

## Pool Configuration

### Stable Pool
- **r_threshold**: 0.23 (23% coverage ratio threshold)
- **haircut_rate**: 0.005% (0.005% haircut for stable assets)
- **retention_ratio**: 20% (20% retention)

### Variant Pool (cmETH Pool)
- **r_threshold**: 0.20 (20% coverage ratio threshold)
- **haircut_rate**: 0.005% (0.005% haircut for variable assets)
- **retention_ratio**: 20% (20% retention)

## Mathematical Formulas

The implementation includes all mathematical functions from Core.sol:

### Solvency Score Calculation
```python
def _solvency_score(self, r_thres_wad, cash_wad, liability_wad, cash_change_wad, add_cash):
    """
    Compute solvency score during a change in cash position.
    Whitepaper Def. 4.1
    """
```

### Swap Rate Calculation
```python
def _compute_to_amount(self, si_wad, sj_wad, from_amount_wad):
    """
    Compute toAmount using solvency scores.
    Whitepaper Def. 4.1: toAmount = fromAmount * (1 + Si - Sj)
    """
```

### Solvency Curve Integral
```python
def _solvency_curve_integral(self, r_thres_wad, r_wad):
    """
    Compute the definite integral F(r) = ∫ -p(s) ds from r to 1
    Whitepaper Formula 4.2
    """
```

## Router Integration (Required for All Swaps)

For all swaps, use the Mobius router:

```python
# Router function signature
router_function = "swapTokensForTokens(address[],address[],uint256,uint256,address,uint256)"

# Example: USDe -> USDC (through stable pool)
token_path = [
    "0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34",  # USDe
    "0x09Bc4E0D864854c6aFB6eB9A9cdF58aC190D0dF9",  # USDC
]

pool_path = [
    "0x3c056E0efaE7218b257868734b1dA7719B41F920",  # StablePool
]

# When we have multiple stable pool in the future
token_path = [
    "{token_1_address}",  # Token 1 address
    "{token_2_address}",  # Token 2 address
    "{token_3_address}",  # Token 3 address
]

pool_path = [
    "{pool_A_address}",  # address of Pool A containing Token 1 and Token 2
    "{pool_B_address}",  # address of Pool B containing Token 2 and Token 3
]

```

## State Synchronization

DEX aggregators should regularly update pool state by calling:

```python
def update_asset_state(self, token_address, asset_address, cash, liability, 
                      decimals, underlying_token_decimals, aggregate_account, price_wad=0):
    """
    Update the state of an asset in the pool.
    Called by DEX aggregators to sync pool state.
    """
```

Required state data:
- **cash**: Current cash balance in token decimals
- **liability**: Current liability in token decimals
- **underlying_token_decimals**: Underlying token decimals
- **aggregate_account**: Aggregate account address
- **price_wad**: Price in WAD (None for stable assets, actual price for variant assets)

For variant pools, prices can also be updated separately:

```python
def update_asset_price(self, token_address, price_wad):
    """
    Update the price of a variant asset.
    Called by DEX aggregators to sync price oracle data.
    """
```

**Price Examples:**
- Stable assets (USDe, USDC, USDT): `None` (no price needed for StablePool, only needed for VariantPool)
- WETH (base asset): `1000000000000000000` (1.0 in WAD)
- cmETH/mETH: `1072690000000000000` (1.07269 in WAD)

**Token Configuration:**
The integration includes a `TOKEN_CONFIG` dictionary with all token information:

```python
TOKEN_CONFIG = {
    "USDe": {"decimals": 18, "address": "0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34"},
    "USDC": {"decimals": 6, "address": "0x09Bc4E0D864854c6aFB6eB9A9cdF58aC190D0dF9"},
    "USDT": {"decimals": 6, "address": "0x201EBa5CC46D216Ce6DC03F6a759e8E766e956aE"},
    "cmETH": {"decimals": 18, "address": "0xE6829d9a7eE3040e1276Fa75293Bde931859e8fA"},
    "mETH": {"decimals": 18, "address": "0xcDA86A272531e8640cD7F1a92c01839911B90bb0"},
    "WETH": {"decimals": 18, "address": "0xdEAddEaDdeadDEadDEADDEAddEADDEAddead1111"}
}
```

**Helper Functions:**
- `get_token_decimals(token_address)`: Get token decimals by address
- `get_token_name(token_address)`: Get token name by address

## Error Handling

The implementation includes comprehensive error handling:

```python
try:
    to_amount, haircut = pool.quote_swap(from_token, to_token, from_amount)
except ValueError as e:
    # Handle validation errors
    print(f"Validation error: {e}")
except Exception as e:
    # Handle other errors
    print(f"Unexpected error: {e}")
```

## Validation

Before executing swaps, validate them:

```python
if pool.validate_swap(from_token, to_token, from_amount):
    # Swap is valid, proceed with execution
    pass
else:
    # Swap is invalid, handle accordingly
    pass
```

## Testing

Run the example code to test the integration:

```bash
python mobius_pool_integration.py
```

This will demonstrate:
- Stable pool quotes
- Variant pool quotes
- Router integration for all swaps

## Important Notes

1. **State Updates**: Regularly update pool state to ensure accurate quotes.

2. **Price Oracles**: For variant pools, regularly call the on-chain price oracle and use `update_asset_price()` to sync the prices, similar to how pool states are updated.

3. **Slippage Protection**: Always include slippage tolerance in minimum output amounts.

4. **Deadlines**: Set appropriate deadlines for swap transactions.

5. **Gas Estimation**: Consider gas costs when constructing transactions.

6. **Router Usage**: Use the Möbius router for all swaps instead of direct pool calls.

## For DEX Aggregator Integration

DEX aggregators will need to:
1. Create pool instances using the provided factory functions
2. Regularly call `update_asset_state()` to sync pool state
3. For variant pools, also call `update_asset_price()` to update the new price of the underlying asset. (e.g., for mETH and cmETH, https://market.api3.org/mantle/meth-eth-exchange-rate)
4. Use `quote_swap()` for off-chain quote calculations
5. Use the router integration for all swap transactions

## Support

For questions or issues with the integration, please contact the Möbius team.
