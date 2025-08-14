from typing import Dict, List, Tuple, Optional
from dataclasses import dataclass
from decimal import Decimal, getcontext
import math

# Set precision for decimal calculations
getcontext().prec = 28

# Constants
WAD = Decimal('1000000000000000000')  # 18 decimals
UNIT = WAD

@dataclass
class AssetState:
    """Represents the state of an asset in the pool"""
    token_address: str
    cash: Decimal  # in WAD
    liability: Decimal  # in WAD
    underlying_token_decimals: int
    aggregate_account: str
    price_wad: Optional[Decimal] = None  # Price in WAD (None for stable assets, actual price for variant assets)
    
    @property
    def coverage_ratio(self) -> Decimal:
        """Calculate coverage ratio = cash / liability"""
        if self.liability == 0:
            raise ValueError("Liability cannot be zero")
        return self.cash / self.liability

@dataclass
class PoolConfig:
    """Pool configuration parameters"""
    r_threshold: Decimal  # in WAD
    haircut_rate: Decimal  # in WAD
    retention_ratio: Decimal  # in WAD
    pool_type: str  # "stable" or "variant"

class MobiusPool:
    """
    Python implementation of Mobius Pool for DEX aggregator integration.
    Mirrors the mathematical functions from Core.sol and pool state management.
    """
    
    def __init__(self, pool_address: str, pool_config: PoolConfig):
        self.pool_address = pool_address
        self.config = pool_config
        self.assets: Dict[str, AssetState] = {}
        self.asset_addresses: Dict[str, str] = {}  # token_address -> asset_address
        
    def update_asset_state(self, token_address: str, asset_address: str, 
                          cash: int, liability: int,
                          underlying_token_decimals: int, aggregate_account: str,
                          values_in_wad: bool, price_wad: Optional[int] = None):
        """
        Update the state of an asset in the pool.
        Called by DEX aggregators to sync pool state.
        
        Args:
            token_address: ERC20 token address
            asset_address: Asset contract address
            cash: Cash balance (in WAD if values_in_wad=True, otherwise in token decimals)
            liability: Liability (in WAD if values_in_wad=True, otherwise in token decimals)
            underlying_token_decimals: Underlying token decimals
            aggregate_account: Aggregate account address
            price_wad: Price in WAD (None for stable assets, actual price for variant assets)
            values_in_wad: If True, cash and liability are already in WAD format
        """
        # Convert to WAD for internal calculations if needed
        if values_in_wad:
            cash_wad = Decimal(str(cash))
            liability_wad = Decimal(str(liability))
        else:
            cash_wad = self._to_wad(cash, underlying_token_decimals)
            liability_wad = self._to_wad(liability, underlying_token_decimals)
        
        price_decimal = Decimal(str(price_wad)) if price_wad is not None else None
        
        self.assets[token_address] = AssetState(
            token_address=token_address,
            cash=cash_wad,
            liability=liability_wad,
            underlying_token_decimals=underlying_token_decimals,
            aggregate_account=aggregate_account,
            price_wad=price_decimal
        )
        self.asset_addresses[token_address] = asset_address
    
    def get_asset_state(self, token_address: str) -> Optional[AssetState]:
        """Get current state of an asset"""
        return self.assets.get(token_address)
    
    def is_stable_asset(self, token_address: str) -> bool:
        """Check if an asset is a stable asset (no price oracle needed)"""
        asset = self.assets.get(token_address)
        return asset is not None and asset.price_wad is None
    
    def update_asset_price(self, token_address: str, price_wad: int):
        """
        Update the price of a variant asset.
        Called by DEX aggregators to sync price oracle data.
        
        Args:
            token_address: ERC20 token address
            price_wad: Price in WAD (e.g., 1072690000000000000 for 1.07269)
        """
        if token_address not in self.assets:
            raise ValueError("Asset not found in pool")
        
        asset = self.assets[token_address]
        asset.price_wad = Decimal(str(price_wad))
    
    def quote_swap(self, from_token: str, to_token: str, from_amount: int) -> Tuple[int, int]:
        """
        Quote a swap between two tokens.
        Returns (to_amount, haircut) in to_token decimals.
        
        Args:
            from_token: Source token address
            to_token: Destination token address
            from_amount: Amount to swap in from_token decimals
            
        Returns:
            Tuple of (to_amount, haircut) in to_token decimals
        """
        from_asset = self.assets.get(from_token)
        to_asset = self.assets.get(to_token)
        
        if not from_asset or not to_asset:
            raise ValueError("Asset not found in pool")
        
        if from_asset.aggregate_account != to_asset.aggregate_account:
            raise ValueError("Assets must be in the same aggregate account")
        
        # Convert from_amount to WAD
        from_amount_wad = self._to_wad(from_amount, from_asset.underlying_token_decimals)
        
        # Calculate quote in WAD
        to_amount_wad, haircut_wad = self._quote_swap_internal(from_asset, to_asset, from_amount_wad)
        
        # Convert back to token decimals
        to_amount = self._from_wad(to_amount_wad, to_asset.underlying_token_decimals)
        haircut = self._from_wad(haircut_wad, to_asset.underlying_token_decimals)
        
        return int(to_amount), int(haircut)
    
    def _quote_swap_internal(self, from_asset: AssetState, to_asset: AssetState, 
                           from_amount_wad: Decimal) -> Tuple[Decimal, Decimal]:
        """
        Internal quote calculation in WAD.
        Mirrors the _quoteSwap function from StablePool.sol and VariantPool.sol
        """
        if self.config.pool_type == "stable":
            ideal_to_amount = from_amount_wad
        else:  # variant pool
            ideal_to_amount = self._quote_ideal_to_amount(from_asset, to_asset, from_amount_wad)
        
        if to_asset.cash < ideal_to_amount:
            raise ValueError("Insufficient cash in destination asset")
        
        # Calculate solvency scores
        solvency_from = self._solvency_score(
            self.config.r_threshold,
            from_asset.cash,
            from_asset.liability,
            from_amount_wad,
            True  # add_cash
        )
        
        solvency_to = self._solvency_score(
            self.config.r_threshold,
            to_asset.cash,
            to_asset.liability,
            ideal_to_amount,
            False  # add_cash
        )
        
        # Calculate to_amount using solvency scores (convert to WAD format)
        to_amount = self._compute_to_amount(solvency_from * UNIT, solvency_to * UNIT, ideal_to_amount)
        
        # Apply haircut
        haircut = self._haircut(to_amount, self.config.haircut_rate)
        actual_to_amount = to_amount - haircut
        
        return actual_to_amount, haircut
    
    def _quote_ideal_to_amount(self, from_asset: AssetState, to_asset: AssetState, 
                              from_amount_wad: Decimal) -> Decimal:
        """
        Quote ideal amount for variant pools using price oracles.
        Uses the stored prices in the asset states.
        """
        from_price = from_asset.price_wad
        to_price = to_asset.price_wad
        
        if to_price is None or from_price is None:
            raise ValueError("Invalid price - price not set for variant asset")
        
        return self._convert_token_amount(from_amount_wad, from_price, to_price)
    
    # Mathematical functions from Core.sol
    
    def _to_wad(self, x: int, d: int) -> Decimal:
        """Convert x from d decimals to WAD (18 decimals)"""
        x_decimal = Decimal(str(x))
        if d < 18:
            return x_decimal * (10 ** (18 - d))
        elif d > 18:
            return x_decimal / (10 ** (d - 18))
        return x_decimal
    
    def _from_wad(self, x: Decimal, d: int) -> Decimal:
        """Convert x from WAD (18 decimals) to d decimals"""
        if d < 18:
            return x / (10 ** (18 - d))
        elif d > 18:
            return x * (10 ** (d - 18))
        return x
    
    def _coverage_ratio(self, cash_wad: Decimal, liability_wad: Decimal) -> Decimal:
        """Calculate coverage ratio = cash / liability"""
        if liability_wad == 0:
            raise ValueError("Liability cannot be zero")
        return cash_wad / liability_wad
    
    def _solvency_curve_integral(self, r_thres_wad: Decimal, r_wad: Decimal) -> Decimal:
        """
        Compute the definite integral F(r) = ∫ -p(s) ds from r to 1
        Whitepaper Formula 4.2
        """
        if r_thres_wad == 0:
            raise ValueError("R threshold cannot be zero")
        if r_wad == 0:
            raise ValueError("R cannot be zero")
        
        # Case 1: r <= rThres
        if r_wad <= r_thres_wad:
            return (UNIT - r_thres_wad) / Decimal('5000000000000000000') + r_thres_wad - r_wad
        elif r_wad < UNIT:
            # Case 2: rThres < r < UNIT
            return ((UNIT - r_wad) ** 5) / (Decimal('5000000000000000000') * (UNIT - r_thres_wad) ** 4)
        else:
            # Case 3: r >= UNIT
            return Decimal('0')
    
    def _solvency_score(self, r_thres_wad: Decimal, cash_wad: Decimal, liability_wad: Decimal,
                       cash_change_wad: Decimal, add_cash: bool) -> Decimal:
        """
        Compute solvency score during a change in cash position.
        Whitepaper Def. 4.1
        """
        if liability_wad == 0:
            raise ValueError("Liability cannot be zero")
        
        cov_before = cash_wad / liability_wad
        
        if add_cash:
            cov_after = (cash_wad + cash_change_wad) / liability_wad
        else:
            cov_after = (cash_wad - cash_change_wad) / liability_wad
        
        # If coverage stays unchanged, solvency score is 0
        if cov_before == cov_after:
            return Decimal('0')
        
        # Convert coverage ratios to WAD for the integral calculation (like Solidity's .unwrap())
        cov_before_wad = cov_before * UNIT
        cov_after_wad = cov_after * UNIT
        
        solvency_integral_before = self._solvency_curve_integral(r_thres_wad, cov_before_wad)
        solvency_integral_after = self._solvency_curve_integral(r_thres_wad, cov_after_wad)
        
        if cov_before > cov_after:
            return (solvency_integral_after - solvency_integral_before) / (cov_before - cov_after)
        else:
            return (solvency_integral_before - solvency_integral_after) / (cov_after - cov_before)
    
    def _compute_to_amount(self, si_wad: Decimal, sj_wad: Decimal, from_amount_wad: Decimal) -> Decimal:
        """
        Compute toAmount using solvency scores.
        Whitepaper Def. 4.1: toAmount = fromAmount * (1 + Si - Sj)
        """
        # The solvency scores are in WAD, and we use them directly like in Solidity
        # Formula: toAmount = fromAmount * (UNIT + si - sj)
        return from_amount_wad * (UNIT + si_wad - sj_wad) / UNIT
    
    def _haircut(self, amount_wad: Decimal, rate_wad: Decimal) -> Decimal:
        """Apply haircut rate to amount"""
        # The rate is in WAD, and we use it directly like in Solidity
        # Formula: haircut = amount * rate
        return amount_wad * rate_wad / UNIT
    
    def _convert_token_amount(self, from_amount_wad: Decimal, from_price_wad: Decimal, 
                            to_price_wad: Decimal) -> Decimal:
        """
        Convert amount from one token to another using relative prices.
        Formula: toAmount = fromAmount * (fromPrice / toPrice)
        """
        if to_price_wad == 0 or from_price_wad == 0:
            raise ValueError("Price cannot be zero")
        return from_amount_wad * from_price_wad / to_price_wad
    
    def get_swap_function_signature(self) -> str:
        """Return the function signature for the swap function"""
        return "swap(address,address,uint256,uint256,address,uint256)"
    
    def get_swap_parameters(self, from_token: str, to_token: str, from_amount: int,
                          minimum_to_amount: int, to_address: str, deadline: int) -> List:
        """
        Get the parameters for the swap function call.
        Returns parameters in the order expected by the swap function.
        """
        return [
            from_token,
            to_token,
            from_amount,
            minimum_to_amount,
            to_address,
            deadline
        ]
    
    def validate_swap(self, from_token: str, to_token: str, from_amount: int) -> bool:
        """
        Validate if a swap is possible with current pool state.
        Returns True if swap is valid, False otherwise.
        """
        try:
            from_asset = self.assets.get(from_token)
            to_asset = self.assets.get(to_token)
            
            if not from_asset or not to_asset:
                return False
            
            if from_asset.aggregate_account != to_asset.aggregate_account:
                return False
            
            if from_amount <= 0:
                return False
            
            # Check if destination asset has sufficient cash
            from_amount_wad = self._to_wad(from_amount, from_asset.underlying_token_decimals)
            if self.config.pool_type == "stable":
                ideal_to_amount = from_amount_wad
            else:
                ideal_to_amount = self._quote_ideal_to_amount(from_asset, to_asset, from_amount_wad)
            
            if to_asset.cash < ideal_to_amount:
                return False
            
            return True
            
        except Exception:
            return False


# Example usage and helper functions

# Token configuration
TOKEN_CONFIG = {
    "USDe": {"decimals": 18, "address": "0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34"},
    "USDC": {"decimals": 6, "address": "0x09Bc4E0D864854c6aFB6eB9A9cdF58aC190D0dF9"},
    "USDT": {"decimals": 6, "address": "0x201EBa5CC46D216Ce6DC03F6a759e8E766e956aE"},
    "cmETH": {"decimals": 18, "address": "0xE6829d9a7eE3040e1276Fa75293Bde931859e8fA"},
    "mETH": {"decimals": 18, "address": "0xcDA86A272531e8640cD7F1a92c01839911B90bb0"},
    "WETH": {"decimals": 18, "address": "0xdEAddEaDdeadDEadDEADDEAddEADDEAddead1111"}
}

# Contract addresses from README
MANTLE_MAINNET_ADDRESSES = {
    "stable_pool": "0x3c056E0efaE7218b257868734b1dA7719B41F920",
    "variant_pool": "0xF95595635D4b09aE4c662069e82CA43012118707",
    "router": "0x06367aDe2EFEEe82C0E27390db4fc2fAE80308b6",
    "tokens": {
        "USDe": "0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34",
        "USDC": "0x09Bc4E0D864854c6aFB6eB9A9cdF58aC190D0dF9",
        "USDT": "0x201EBa5CC46D216Ce6DC03F6a759e8E766e956aE",
        "cmETH": "0xE6829d9a7eE3040e1276Fa75293Bde931859e8fA",
        "mETH": "0xcDA86A272531e8640cD7F1a92c01839911B90bb0",
        "WETH": "0xdEAddEaDdeadDEadDEADDEAddEADDEAddead1111"
    },
    "assets": {
        "USDe": "0x362F4D6F539201dB13A7305369a48FaC58960be5",
        "USDC": "0xb8Ca9787Cf03c6f1fA6ef207aB93e875F3B84426",
        "USDT": "0x6A7D252b807887AfEE870d14C5D7eb25f00A7044",
        "cmETH": "0x801f29bB8fa066b71bF2f4e1Af34D7E4682cCecc",
        "mETH": "0x88837Ef995907016C5ca0776693f6B2339A44E35",
        "WETH": "0x6d01Ad49e74aa488EB293c1869D4aCDC39359B4b"
    },
    "aggregate_accounts": {
        "stable": "0x7f63b4B1B9177BD064040D4F7ceBEef328f33e20",
        "variant": "0x927348962E7Bf9e156845585Cf858c613D389f4B"
    }
}

def get_token_decimals(token_address: str) -> int:
    """Get token decimals by address"""
    for token_name, config in TOKEN_CONFIG.items():
        if config["address"] == token_address:
            return config["decimals"]
    return 18  # Default to 18 decimals if not found

def get_token_name(token_address: str) -> str:
    """Get token name by address"""
    for token_name, config in TOKEN_CONFIG.items():
        if config["address"] == token_address:
            return token_name
    return "Unknown"

def display_pool_state(pool: MobiusPool):
    """Display current pool state in a readable format"""
    print(f"\n=== Pool State for {pool.pool_address} ===")
    for token_address, asset in pool.assets.items():
        token_name = get_token_name(token_address)
        # Convert from WAD to readable amounts
        # The values are stored in WAD (18 decimals), so divide by 10^18
        cash_readable = asset.cash / (10 ** 18)
        liability_readable = asset.liability / (10 ** 18)
        coverage_ratio = asset.coverage_ratio
        
        print(f"{token_name}:")
        print(f"  Cash: {cash_readable:,.2f}")
        print(f"  Liability: {liability_readable:,.2f}")
        print(f"  Coverage Ratio: {coverage_ratio:.4f}")
        if asset.price_wad is not None:
            price_readable = asset.price_wad / (10 ** 18)
            print(f"  Price: {price_readable:.6f} ETH")
        print()

def create_mantle_mainnet_stable_pool() -> MobiusPool:
    """Create Mantle mainnet stable pool instance"""
    config = PoolConfig(
        r_threshold=Decimal('230000000000000000'),  # 0.23 in WAD
        haircut_rate=Decimal('50000000000000'),  # 0.005% haircut
        retention_ratio=Decimal('200000000000000000'),  # 20% retention
        pool_type="stable"
    )
    return MobiusPool(MANTLE_MAINNET_ADDRESSES["stable_pool"], config)

def create_mantle_mainnet_variant_pool() -> MobiusPool:
    """Create Mantle mainnet variant pool instance"""
    config = PoolConfig(
        r_threshold=Decimal('200000000000000000'),  # 0.20 in WAD
        haircut_rate=Decimal('50000000000000'),  # 0.005% haircut
        retention_ratio=Decimal('200000000000000000'),  # 20% retention
        pool_type="variant"
    )
    return MobiusPool(MANTLE_MAINNET_ADDRESSES["variant_pool"], config)

def setup_stable_pool_state(pool: MobiusPool, addresses: dict):
    """
    Setup stable pool with USDe, USDC, USDT assets using real on-chain data
    """
    # USDe (18 decimals) - Real on-chain data
    pool.update_asset_state(
        token_address=addresses["tokens"]["USDe"],
        asset_address=addresses["assets"]["USDe"],
        cash=21564039972018040980967,  # Real USDe cash
        liability=24336765812301186559140,  # Real USDe liability
        underlying_token_decimals=18,
        aggregate_account=addresses["aggregate_accounts"]["stable"],
        values_in_wad=True,  # Values are in WAD format
        price_wad=None  # Stable asset, no price needed
    )
    
    # USDC (6 decimals) - Real on-chain data (in micro units)
    pool.update_asset_state(
        token_address=addresses["tokens"]["USDC"],
        asset_address=addresses["assets"]["USDC"],
        cash=21491644533317066991913,  # Real USDC cash (in micro units)
        liability=18717507771725148273016,  # Real USDC liability (in micro units)
        underlying_token_decimals=6,
        aggregate_account=addresses["aggregate_accounts"]["stable"],
        values_in_wad=True,  # Values are in WAD format
        price_wad=None  # Stable asset, no price needed
    )
    
    # USDT (6 decimals) - Real on-chain data (in micro units)
    pool.update_asset_state(
        token_address=addresses["tokens"]["USDT"],
        asset_address=addresses["assets"]["USDT"],
        cash=17494532897516387104081,  # Real USDT cash (in micro units)
        liability=17494496221405803482740,  # Real USDT liability (in micro units)
        underlying_token_decimals=6,
        aggregate_account=addresses["aggregate_accounts"]["stable"],
        values_in_wad=True,  # Values are in WAD format
        price_wad=None  # Stable asset, no price needed
    )

def setup_variant_pool_state(pool: MobiusPool, addresses: dict):
    """
    Setup variant pool with cmETH, mETH, WETH assets
    """
    # WETH (18 decimals) - Base asset, price = 1
    pool.update_asset_state(
        token_address=addresses["tokens"]["WETH"],
        asset_address=addresses["assets"]["WETH"],
        cash=100000000000000000000,  # 100 WETH
        liability=100000000000000000000,  # 100 WETH
        underlying_token_decimals=18,
        aggregate_account=addresses["aggregate_accounts"]["variant"],
        values_in_wad=True,  # Values are in WAD format
        price_wad=1000000000000000000  # 1.0 in WAD (base asset)
    )
    
    # cmETH (18 decimals) - Price = 1.07269
    # price from https://market.api3.org/mantle/meth-eth-exchange-rate 
    # cmETH has the same price as mETH
    pool.update_asset_state(
        token_address=addresses["tokens"]["cmETH"],
        asset_address=addresses["assets"]["cmETH"],
        cash=100000000000000000000,  # 100 cmETH
        liability=100000000000000000000,  # 100 cmETH
        underlying_token_decimals=18,
        aggregate_account=addresses["aggregate_accounts"]["variant"],
        values_in_wad=True,  # Values are in WAD format
        price_wad=1072690000000000000  # 1.07269 in WAD
    )
    
    # mETH (18 decimals) - Price = 1.07269 (same as cmETH)
    # price from https://market.api3.org/mantle/meth-eth-exchange-rate
    pool.update_asset_state(
        token_address=addresses["tokens"]["mETH"],
        asset_address=addresses["assets"]["mETH"],
        cash=100000000000000000000,  # 100 mETH
        liability=100000000000000000000,  # 100 mETH
        underlying_token_decimals=18,
        aggregate_account=addresses["aggregate_accounts"]["variant"],
        values_in_wad=True,  # Values are in WAD format
        price_wad=1072690000000000000  # 1.07269 in WAD
    )

def example_stable_pool_quotes():
    """Example of getting quotes from stable pool"""
    print("=== Stable Pool Quote Examples ===")
    
    # Create mainnet stable pool
    pool = create_mantle_mainnet_stable_pool()
    setup_stable_pool_state(pool, MANTLE_MAINNET_ADDRESSES)
    
    # Display current pool state
    display_pool_state(pool)
    
    # Example quotes
    test_cases = [
        ("USDe", "USDC", 100000000000000000000),  # 100 USDe -> USDC
        ("USDe", "USDT", 50000000000000000000),   # 50 USDe -> USDT
        ("USDC", "USDe", 100000000),              # 100 USDC -> USDe
        ("USDT", "USDe", 200000000),              # 200 USDT -> USDe
        ("USDT", "USDe", 2500000000),             # 2500 USDT -> USDe
        ("USDe", "USDT", 3000000000000000000000), # 3000 USDe -> USDT
    ]
    
    for from_token, to_token, amount in test_cases:
        try:
            to_amount, haircut = pool.quote_swap(
                MANTLE_MAINNET_ADDRESSES["tokens"][from_token],
                MANTLE_MAINNET_ADDRESSES["tokens"][to_token],
                amount
            )
            
            # Convert to human readable amounts using token configuration
            from_decimals = TOKEN_CONFIG.get(from_token, {}).get("decimals", 18)
            to_decimals = TOKEN_CONFIG.get(to_token, {}).get("decimals", 18)
            
            from_amount_readable = amount / (10 ** from_decimals)
            to_amount_readable = to_amount / (10 ** to_decimals)
            haircut_readable = haircut / (10 ** to_decimals)
            
            print(f"{from_amount_readable} {from_token} -> {to_amount_readable} {to_token} (haircut: {haircut_readable} {to_token})")
            
        except Exception as e:
            print(f"Error quoting {from_token} -> {to_token}: {e}")

def example_variant_pool_quotes():
    """Example of getting quotes from variant pool"""
    print("\n=== Variant Pool Quote Examples ===")
    
    # Create mainnet variant pool
    pool = create_mantle_mainnet_variant_pool()
    setup_variant_pool_state(pool, MANTLE_MAINNET_ADDRESSES)
    
    # Example quotes
    test_cases = [
        ("cmETH", "mETH", 10000000000000000000),  # 10 cmETH -> mETH
        ("mETH", "WETH", 50000000000000000000),   # 50 mETH -> WETH
        ("WETH", "cmETH", 20000000000000000000),  # 20 WETH -> cmETH
    ]
    
    for from_token, to_token, amount in test_cases:
        try:
            to_amount, haircut = pool.quote_swap(
                MANTLE_MAINNET_ADDRESSES["tokens"][from_token],
                MANTLE_MAINNET_ADDRESSES["tokens"][to_token],
                amount
            )
            
            # Convert to human readable amounts
            from_amount_readable = amount / (10 ** 18)
            to_amount_readable = to_amount / (10 ** 18)
            haircut_readable = haircut / (10 ** 18)
            
            print(f"{from_amount_readable} {from_token} -> {to_amount_readable} {to_token} (haircut: {haircut_readable} {to_token})")
            
        except Exception as e:
            print(f"Error quoting {from_token} -> {to_token}: {e}")
    
    # Example of updating prices dynamically
    print("\n=== Price Update Example ===")
    print("Updating cmETH and mETH prices to 1.1 ETH...")
    
    # Update prices (simulating price oracle update)
    new_price_wad = 1100000000000000000  # 1.1 in WAD
    pool.update_asset_price(MANTLE_MAINNET_ADDRESSES["tokens"]["cmETH"], new_price_wad)
    pool.update_asset_price(MANTLE_MAINNET_ADDRESSES["tokens"]["mETH"], new_price_wad)
    
    # Test quote with updated prices
    try:
        to_amount, haircut = pool.quote_swap(
            MANTLE_MAINNET_ADDRESSES["tokens"]["WETH"],
            MANTLE_MAINNET_ADDRESSES["tokens"]["cmETH"],
            10000000000000000000  # 10 WETH
        )
        
        to_amount_readable = to_amount / (10 ** 18)
        haircut_readable = haircut / (10 ** 18)
        
        print(f"10 WETH -> {to_amount_readable} cmETH (haircut: {haircut_readable} cmETH) [with updated price]")
        
    except Exception as e:
        print(f"Error with updated prices: {e}")

def example_swap_construction():
    """Example of constructing swap transactions"""
    print("\n=== Swap Transaction Construction ===")
    
    # Create pool instance
    pool = create_mantle_mainnet_stable_pool()
    setup_stable_pool_state(pool, MANTLE_MAINNET_ADDRESSES)
    
    # Get quote first
    from_token = MANTLE_MAINNET_ADDRESSES["tokens"]["USDe"]
    to_token = MANTLE_MAINNET_ADDRESSES["tokens"]["USDC"]
    from_amount = 100000000000000000000  # 100 USDe
    
    try:
        to_amount, haircut = pool.quote_swap(from_token, to_token, from_amount)
        
        # Add some slippage tolerance (0.5%)
        slippage_tolerance = 0.995
        minimum_to_amount = int(to_amount * slippage_tolerance)
        
        # Get swap parameters
        swap_params = pool.get_swap_parameters(
            from_token=from_token,
            to_token=to_token,
            from_amount=from_amount,
            minimum_to_amount=minimum_to_amount,
            to_address="0x742d35Cc6634C0532925a3b8D4C9db96C4b4d8b6",  # Example recipient
            deadline=1234567890
        )
        
        print(f"Swap Function: {pool.get_swap_function_signature()}")
        print(f"Pool Address: {pool.pool_address}")
        print(f"Parameters: {swap_params}")
        usdc_decimals = get_token_decimals(to_token)
        print(f"Expected Output: {to_amount / (10 ** usdc_decimals)} USDC")
        print(f"Minimum Output: {minimum_to_amount / (10 ** usdc_decimals)} USDC")
        print(f"Haircut: {haircut / (10 ** usdc_decimals)} USDC")
        
    except Exception as e:
        print(f"Error constructing swap: {e}")

def example_router_integration():
    """Example of router integration for multi-hop swaps"""
    print("\n=== Router Integration Example ===")
    
    # Router function signature
    router_function = "swapTokensForTokens(address[],address[],uint256,uint256,address,uint256)"

    # Example: USDe -> USDC -> USDT (through stable pool)
    token_path = [
        MANTLE_MAINNET_ADDRESSES["tokens"]["USDe"],
        MANTLE_MAINNET_ADDRESSES["tokens"]["USDC"],
        MANTLE_MAINNET_ADDRESSES["tokens"]["USDT"]
    ]

    # Note: this example demonstrates multi-hop routing through the same pool
    # which is not recommended in practice,
    # directly swapping from USDe to USDT would yield a better rate
    # But in the future when we have multiple stable pools, this multi-hoppattern would become relevant.
    pool_path = [
        MANTLE_MAINNET_ADDRESSES["stable_pool"],
        MANTLE_MAINNET_ADDRESSES["stable_pool"]
    ]
    
    from_amount = 100000000000000000000  # 100 USDe
    minimum_to_amount = 99000000  # 99 USDT (with slippage)
    to_address = "0x742d35Cc6634C0532925a3b8D4C9db96C4b4d8b6"
    deadline = 1234567890
    
    router_params = [
        token_path,
        pool_path,
        from_amount,
        minimum_to_amount,
        to_address,
        deadline
    ]
    
    print(f"Router Function: {router_function}")
    print(f"Router Address: {MANTLE_MAINNET_ADDRESSES['router']}")
    print(f"Token Path: {token_path}")
    print(f"Pool Path: {pool_path}")
    usde_decimals = get_token_decimals(token_path[0])
    usdt_decimals = get_token_decimals(token_path[2])
    print(f"From Amount: {from_amount / (10 ** usde_decimals)} USDe")
    print(f"Minimum To Amount: {minimum_to_amount / (10 ** usdt_decimals)} USDT")


if __name__ == "__main__":
    example_stable_pool_quotes()
    example_variant_pool_quotes()
    example_swap_construction()
    example_router_integration() 