# Degen Curator (dCURATOR) — Full Architecture

**Status:** Pre-build spec, synthesized from Research / Architect / Security / CTO sub-agent outputs
**Target chain:** Base (mainnet sequencer)
**Cap:** $1M deposits / 1,000 depositors / weekly cycle
**Launch target:** Day 7 testnet · Day 14 mainnet beta @ $250K cap · $1M after 48h clean

---

## Problem statement

Build a no-loss convex lottery vault on the Morpho stack. User deposits USDC, principal sits 100% in a curated Morpho USDC vault, and only weekly accrued yield is deployed into a curator-selected basket of Pendle Points YTs filtered by the V2 strategy (cheap-FDV bottom quartile + positive 30d momentum). Worst case: user foregoes yield. Best case: convex YT positions hit TGE and pay out pro-rata. **Zero leverage, zero liquidation, zero on-chain oracles.**

## Mechanism overview

This is a hybrid mechanism with three primitives composed:

1. **ERC-4626 wrapper over a curated Morpho USDC vault** — holds 100% of user principal
2. **Sushibar-style share-index payout pool** — distributes settled YT winnings pro-rata to dCURATOR holders, separate from `pricePerShare`
3. **Curator-discretion strategy executor** — buys long-only Pendle Points YTs from a timelocked whitelist via Pendle Router V4

**Closest analog:** PoolTogether V5. Differs in three material ways:
- **Yield source:** convex YT bets vs. PoolTogether's passive lending
- **Payout:** pro-rata to all holders vs. PoolTogether's random-winner-by-tier
- **Attribution:** position-attribution (you accrue from a YT only if your shares existed at the YT's entry block) vs. PoolTogether's TWAB

## Contract Manifest

### Core (Immutable, no proxy)

| Contract | Purpose | Lines | Inherits | Holds Funds |
|---|---|---|---|---|
| `PrincipalVault.sol` | ERC-4626 over USDC. Sole custodian of principal. Funds flow user ↔ Morpho USDC vault only. | ~250 | OZ ERC4626, ReentrancyGuardTransient | **YES** (Morpho vault shares) |
| `LotteryTreasury.sol` | Receives swept yield + YT settlement proceeds. Sushibar share-index payout. | ~180 | ReentrancyGuardTransient | **YES** (USDC + Pendle YT/SY tokens in flight) |
| `PositionManager.sol` | YT position state machine. EnumerableSet of active IDs. | ~200 | ReentrancyGuardTransient | NO (accounting only) |

### Periphery (Upgradeable, UUPS + EIP-7201 storage + 48h timelock)

| Contract | Purpose | Lines | Proxy | Inherits |
|---|---|---|---|---|
| `StrategyExecutor.sol` | Pendle Router V4 calls. Whitelist-gated. Per-market entry cap enforcement. | ~300 | UUPS | UUPSUpgradeable, AccessControlUpgradeable |
| `Curator.sol` | 2/3 multisig + 48h timelock. Whitelist & basket management. | ~220 | UUPS | UUPSUpgradeable, TimelockControllerUpgradeable |
| `YieldSweeper.sol` | HWM-based yield computation. Routes Morpho yield → LotteryTreasury. | ~120 | UUPS | UUPSUpgradeable |
| `Wiring.sol` | Address registry. Allows clean replacement of strategy logic without touching cores. | ~90 | UUPS | UUPSUpgradeable |

**Total surface: 7 contracts, ~1,360 LOC.** Audit-attractive.

## Storage Layout

### `PrincipalVault` (immutable, no proxy)

```
slot N   (packed): uint128 depositCap | uint32 depositorCount | uint64 lastSweepTs | bool paused
slot N+1 (immut):  IMorphoVault MORPHO, IERC20 USDC, IWiring WIRING (baked)
slot N+2:          uint256 principalHWM     (USDC-denominated)
slot N+3:          mapping(address => bool) _hasBalance
```

### `LotteryTreasury` (immutable)

```
slot 0 (packed):  uint128 totalUnsettled | uint128 totalSettled
slot 1:           uint256 globalShareIndex     (1e30 precision, sushibar pattern)
slot 2:           mapping(address => uint256) userIndexCheckpoint
slot 3:           mapping(address => uint256) userClaimable
```

### `PositionManager` (immutable)

```
slot 0 (packed):  uint64 nextPositionId | uint32 activeCount | bool emergencyMode
slot 1:           EnumerableSet.UintSet _activeIds
slot 2:           mapping(uint256 => Position positions)

Position struct (3 slots packed):
  slot A: address market (20) | uint64 openedAt (8) | uint8 state (1)
  slot B: uint128 ytAmount (16) | uint128 usdcCost (16)
  slot C: uint128 settledUsdc (16) | uint64 maturityTs (8)
```

### Periphery (UUPS, EIP-7201 namespaced storage)

```
namespace = keccak256(abi.encode(uint256(keccak256("dcurator.storage.v1.<Contract>")) - 1)) & ~bytes32(uint256(0xff))
```

Each periphery contract has a single struct in its namespace + `uint256[50] __gap` for upgrade safety.

## Access Control Matrix

| Role | Actions | Fund Access | Blast Radius if Compromised | Recovery |
|---|---|---|---|---|
| `USER` | deposit/withdraw on PrincipalVault | own shares | none | n/a |
| `KEEPER` (bot or EOA) | sweepYield, runWeeklyCycle (within committed basket) | none | one cycle's slippage | rotate instantly |
| `CURATOR` (2/3 Safe + 48h timelock) | proposeBasket, proposeWhitelist, setFee | none directly | drain ~1 cycle's yield (~$2K) into hostile market AFTER timelock | 48h window for guardian veto |
| `GUARDIAN` (1/N hot key, separate device) | pause (granular, auto-expires 7d), emergencyExit, veto pending whitelist | none | soft DoS via pause | ADMIN renews/replaces |
| `ADMIN` (3/5 Safe + 48h timelock) | UUPS upgrade (periphery only), set caps, replace roles | **Cannot touch principal — by construction** | brick periphery (replaceable) | multisig threshold |
| **Immutable cores** | n/a | n/a | n/a | n/a |

**Cardinal property:** `ADMIN.canTouchPrincipal == false` is enforced because `PrincipalVault` has no admin function and no upgrade path.

## System-Level Invariants

### I1 — Principal Conservation (CARDINAL)
```
PrincipalVault.totalAssets() ≥ Σ user_deposits − Σ user_withdrawals  (always)
```
- **Enforcement:** `StrategyExecutor` has zero compile-time references to `PrincipalVault`. `sweepYield()` callable only by `Wiring.yieldSweeper()`, computes `currentAssets - principalHWM`, mathematically cannot withdraw below user principal.
- **Test:** Foundry invariant suite, 50K runs × 256 calls.
- **Max loss if violated:** $1M.

### I2 — Strategy Spend Bound
```
cumulative_strategy_spend ≤ cumulative_yield_swept
```
- **Test:** `invariant_treasurySpendBoundedByYield`.

### I3 — Long-Only Convexity
```
∀ position: position.cost_paid ≤ position.max_loss = position.cost_paid
            position.payout ≥ 0
```
- **Enforcement:** Whitelist enforces YT-only markets; no PT, no LP, no debt instruments.

### I4 — Share Index Monotonicity
```
LotteryTreasury.globalShareIndex(t+1) ≥ LotteryTreasury.globalShareIndex(t)
```

### I5 — Total Supply Conservation
```
PrincipalVault.totalSupply() == Σ balanceOf(user)
```

## Value Flow Diagrams

### Deposit
```
User
  │ approve(USDC, PrincipalVault, amt)
  │ deposit(amt, receiver)
  ▼
PrincipalVault
  │ USDC.transferFrom(user, self, amt)
  │ principalHWM += amt
  │ MorphoVault.deposit(amt, self)
  │ _mint(receiver, shares with virtualOffset=6)
  │ depositorCount++ if first balance
  └─ emits Deposited(user, amt, shares, depositorCount, totalAssets)
```

### Weekly Cycle
```
Time:  Mon 17:00 UTC
Step 1 — Keeper:
  YieldSweeper.sweep()
    ├─ y = MorphoVault.convertToAssets(self.balance) - PrincipalVault.principalHWM
    ├─ MorphoVault.withdraw(y, self, self)
    └─ USDC.transfer(LotteryTreasury, y); LotteryTreasury.creditYield(y)

Step 2 — Curator (within whitelist):
  Curator.setBasket(markets[])  // already whitelisted, no timelock for selection

Step 3 — Keeper:
  for each market in basket:
    StrategyExecutor.runWeeklyCycle()
      ├─ approve(USDC, PendleRouter, amt)  [exact amount]
      ├─ PendleRouter.swapExactTokenForYt(...)
      ├─ approve(USDC, PendleRouter, 0)    [revoke]
      ├─ PositionManager.openPosition(market, ytAmount, usdcCost, maturityTs)
      └─ emits RebalanceExecuted(cycleId, basket, allocations, edgeMetrics)
```

### Settlement (close at 5x trigger or T-7d AMM mark — NOT hold to maturity)
```
Anyone (pull-based, with bounty):
  StrategyExecutor.closeYT(positionId, minUsdcOut)
    ├─ PendleRouter.swapExactYtForToken(...) → USDC to LotteryTreasury
    ├─ PositionManager.closePosition(id, usdcReceived)
    └─ LotteryTreasury.settle(id, usdcReceived)
        ├─ if profit > 0: fee = profit × 10%; USDC.transfer(feeRecipient, fee)
        ├─ delta = (usdcReceived - fee) × 1e30 / totalSupply
        ├─ globalShareIndex += delta  [floor div, dust stays in treasury]
        └─ emits PositionSettled(id, payout, multiplier)
```

### Withdraw
```
User
  │ withdraw(assets, receiver, owner) OR redeem(shares, receiver, owner)
  ▼
PrincipalVault
  │ accrueLottery(owner)            [snapshots user's claimable lottery USDC]
  │ MorphoVault.withdraw(assets, self, self)
  │ USDC.transfer(receiver, assets)
  │ _burn(owner, shares)
  │ principalHWM -= assets
  │ depositorCount-- if balance now 0
  └─ emits Withdrawn(user, amt, shares)

(separately, anytime: LotteryTreasury.claim() → unclaimed[user] → USDC)
```

### Emergency Exit
```
Guardian (only, paused state required):
  StrategyExecutor.emergencyExit(maxToProcess ≤ 25)
    │ ids = PositionManager.activeIds()
    │ for i in 0..min(maxToProcess, ids.length):
    │   try this.closeYT(ids[i], minOut=0) {} catch { /* keep going */ }
    │ Curator.pauseAll()
    └─ emits EmergencyExit(reason)
```

## Deployment Sequence

1. Deploy `Wiring` proxy (UUPS), deployer = admin
2. Deploy `PrincipalVault` (immutable) — args `(USDC, MORPHO_USDC_VAULT, wiring, depositCap=1e12)`
3. Deploy `PositionManager` (immutable) — args `(wiring)`
4. Deploy `LotteryTreasury` (immutable) — args `(USDC, wiring)`
5. Deploy `Curator` proxy (UUPS) — init `(safeMultisig, timelockDelay=48h, guardian)`
6. Deploy `StrategyExecutor` proxy (UUPS) — init `(PendleRouterV4, wiring, slippageBps=300)`
7. Deploy `YieldSweeper` proxy (UUPS) — init `(wiring)`
8. `Wiring.setAll(...)` — wire all addresses; transfer Wiring ownership to Curator
9. Curator timelocked: whitelist initial 5-10 Pendle Points YT markets
10. **Renounce deployer admin everywhere.** Keys destroyed; only Curator (multisig+timelock) + Guardian retain control.

### Constructor Arg Sources (Base mainnet)

| Arg | Address | Notes |
|---|---|---|
| `USDC` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | canonical Base USDC |
| `MORPHO_USDC_VAULT` | TBD — pick deepest curated USDC vault on Base (Steakhouse / Gauntlet / MEV Capital) | morpho.org/base |
| `PENDLE_ROUTER_V4` | `0x888888888889758F76e7103c6CbF23ABbF58F946` | verify against Pendle Base docs at deploy time |
| `safeMultisig` | TBD — Sarthak deploys 2/3 Safe Day 0 | Gnosis Safe Base |
| `guardian` | TBD — separate hot EOA on separate device | Sarthak |

## Gas Estimates (Base, 2 gwei)

| Function | Estimated Gas | Notes |
|---|---|---|
| `deposit` | ~165k | USDC transferFrom + Morpho deposit + share mint + first-time depositor SSTORE |
| `redeem` | ~180k | Reverse |
| `totalAssets` (view) | ~12k | Single Morpho external read |
| `sweepYield` | ~95k | Morpho withdraw delta + USDC transfer |
| `runWeeklyCycle` (5 markets) | ~1.8M | 5× Pendle swap (~360k each) |
| `closeYT` | ~280k | 1× Pendle swap + state transition |
| `settle` (post-maturity) | ~140k | redeemPyToToken + share-index update |
| `claim` (user payout) | ~75k | Index-checkpoint diff + transfer |
| `emergencyExit` (≤25 positions) | ~6M | Bounded loop, high slippage |

## Integration Points (External Dependencies)

| Protocol | Role | Trust Assumption |
|---|---|---|
| Morpho USDC Vault (curated) | Holds principal, provides yield | Curator (Steakhouse/Gauntlet) does not misallocate |
| Pendle Router V4 | YT entry/exit | Audited, mature, Base deployment verified |
| USDC token | Asset | Centre.io paused-mode failures handled via SafeTransferLib |
| (none — no oracle dependencies) | | **Major security advantage** |

## EIP Compliance

| EIP | Use |
|---|---|
| ERC-20 | dCURATOR shares |
| ERC-2612 | Permit on shares |
| ERC-4626 | Strict, asset = USDC, totalAssets() = Morpho convertToAssets |
| EIP-1153 | Transient reentrancy guards |
| EIP-1822 | UUPS for periphery |
| EIP-1967 | Standard proxy slots |
| EIP-7201 | Namespaced storage on UUPS contracts |

## Tooling Pin

```
solc                       0.8.26 (Cancun, optimizer 1M runs, --via-ir)
foundry                    forge 0.2.x latest stable
@openzeppelin/contracts            5.1.0
@openzeppelin/contracts-upgradeable 5.1.0
solady                             0.0.281
@pendle/core-v2                    pinned commit (current Base deployment)
morpho-blue + metamorpho           pinned commits
forge-std                          1.9.4
```
