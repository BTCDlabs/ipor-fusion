# Deploy & Configure LitePSMSupplyFuse on Production

The LitePSMSupplyFuse atomically handles USDC-sUSDS conversions via LitePSM in a single fuse call. It supports `enter`/`exit` (called by the monitor via `execute`) and `instantWithdraw` (called by the vault during `redeem`). All token/PSM addresses are hardcoded to mainnet in the Solidity contract -- the only constructor parameter is a `marketId`.

## Prerequisites

- Choose an **unused market ID** for this fuse (fork tests use `999`)
- Look up the **existing sUSDS market ID** by calling `MARKET_ID()` on the deployed `Erc4626SupplyFuseSUSDS` (`0x83Be46881AaeBA80B3d647e08a47301Db2e4E754`). In fork tests this returns `100002`.

## Deployments

### 1. Deploy LitePSMSupplyFuse

Constructor arg: `marketId` (your chosen market ID).

Hardcoded addresses inside the contract:

- USDC: `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`
- USDS: `0xdC035D45d973E3EC169d2276DDab16f1e407384F`
- sUSDS: `0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD`
- LitePSM: `0xA188EEC8F81263234dA3622A406892F3D630f98c`

### 2. Deploy ZeroBalanceFuse

Constructor arg: **same market ID** as step 1.

After `execute`, the vault calls `updateMarketsBalances` which delegatecalls the balance fuse for the fuse's market. Without a balance fuse registered, the vault calls `address(0)` and reverts with `AddressEmptyCode`. The ZeroBalanceFuse returns `0` for `balanceOf()`, satisfying the vault without affecting accounting -- the LitePSMSupplyFuse doesn't hold assets, it moves them through to sUSDS which is tracked by its own market/balance fuse.

## Governance Calls (in order)

All calls require appropriate AccessManager roles (atomist/admin).

### 1. Register supply fuse

```
PlasmaVaultGovernance.addFuses([litePSMSupplyFuseAddr])
```

### 2. Register balance fuse

```
PlasmaVaultGovernance.addBalanceFuse(marketId, zeroBalanceFuseAddr)
```

### 3. Configure dependency balance graph (CRITICAL)

```
PlasmaVaultGovernance.updateDependencyBalanceGraphs(
    [litePSMMarketId],
    [[susdsMarketId]]
)
```

After `instantWithdraw`, the vault calls `_updateMarketsBalances` with only the fuse's own market ID. The ZeroBalanceFuse returns `0`, so the new market is correctly at zero. But the sUSDS that was drained by `instantWithdraw` is tracked by a different market (the existing sUSDS market). Without the dependency edge, the sUSDS market's stored balance stays stale, `totalAssets` becomes inflated (double-counts the USDC the vault now holds + the stale sUSDS balance), and `convertToAssets` returns a value larger than the vault's actual USDC balance -- causing `safeTransfer` to revert with "ERC20: transfer amount exceeds balance".

The dependency graph tells `_checkBalanceFusesDependencies` to expand `[litePSMMarketId]` into `[litePSMMarketId, susdsMarketId]`, refreshing both balance fuses after withdrawal.

### 4. Configure instant withdrawal fuse

```
PlasmaVaultGovernance.configureInstantWithdrawalFuses([{
    fuse: litePSMSupplyFuseAddr,
    params: [
        bytes32(0),  // amount placeholder (overwritten at runtime by withdrawFromMarkets)
        bytes32(0)   // allowedTout = 0 (revert if LitePSM governance enables exit fees)
    ]
}])
```

LitePSM currently has zero fees (`tout()=0`). The `allowedTout=0` param causes the fuse to revert if `tout > 0`, protecting the vault from silently paying unexpected fees. If LitePSM governance enables fees in the future, this param would need to be updated.

## Post-Deployment

1. Add `"LitePSMSupplyFuse": "0x..."` to `contracts/addresses/mainnet.json`
2. Set `BLOCKCHAIN_LITE_PSM_SUPPLY_FUSE_ADDRESS` env var for the vault service

## Verification

1. **enter path**: Monitor calls `execute` with `LitePSMSupplyFuse.enter(amount, 0)` -- vault USDC decreases, sUSDS increases
2. **exit path**: Monitor calls `execute` with `LitePSMSupplyFuse.exit(amount, 0)` -- vault sUSDS decreases, USDC increases
3. **instantWithdraw path**: User calls `redeem` when vault has no idle USDC (all in sUSDS) -- vault sources USDC via `instantWithdraw`, dependency graph refreshes sUSDS market balance, transfer succeeds
4. **Fee protection**: If `tout > 0` on LitePSM, `instantWithdraw` should revert (fuse enforces `allowedTout=0`)
