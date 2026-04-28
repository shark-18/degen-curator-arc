# MVP Scope (v1) — What Ships Day 7 Testnet, Day 14 Mainnet

## In MVP

### Contracts (final list, 7 contracts)

#### Core (immutable)
1. `PrincipalVault.sol` — ERC-4626 USDC vault wrapping Morpho USDC vault
2. `LotteryTreasury.sol` — Sushibar share-index payout pool
3. `PositionManager.sol` — YT position state machine

#### Periphery (UUPS, 48h timelock)
4. `StrategyExecutor.sol` — Pendle Router V4 calls
5. `Curator.sol` — multisig + timelocked whitelist & basket
6. `YieldSweeper.sol` — HWM-based yield computation
7. `Wiring.sol` — address registry

### Function Signatures

#### `PrincipalVault`
```solidity
function deposit(uint256 assets, address receiver) external returns (uint256 shares);
function mint(uint256 shares, address receiver) external returns (uint256 assets);
function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
function totalAssets() public view returns (uint256);
function asset() public view returns (address);  // = USDC
function maxDeposit(address) public view returns (uint256);  // respects $1M cap + 1000 depositor cap
function principalHighWater() external view returns (uint256);
function sweepYield() external returns (uint256);  // only callable by Wiring.yieldSweeper()
function pause() external;     // guardian only
function unpause() external;   // curator only
```

#### `LotteryTreasury`
```solidity
function creditYield(uint256 amount) external;            // YieldSweeper only
function notifyPurchase(uint256 positionId, uint256 usdcSpent) external;  // StrategyExecutor only
function settle(uint256 positionId, uint256 usdcReceived) external;       // PositionManager only
function claim(address user) external returns (uint256);
function claimableOf(address user) external view returns (uint256);
function totalAssetsAtRisk() external view returns (uint256);
function globalShareIndex() external view returns (uint256);
```

#### `PositionManager`
```solidity
struct Position {
    address market;
    uint64 openedAt;
    uint8 state;          // 0=NONE 1=OPEN 2=CLOSED_NORMAL 3=CLOSED_EARLY 4=DELISTED
    uint128 ytAmount;
    uint128 usdcCost;
    uint128 settledUsdc;
    uint64 maturityTs;
}
function openPosition(address market, uint128 ytAmount, uint128 usdcCost, uint64 maturityTs) external returns (uint256 id);
function closePosition(uint256 id, uint256 usdcReceived) external;
function markDelisted(uint256 id) external;
function activeIds() external view returns (uint256[] memory);
function getPosition(uint256 id) external view returns (Position memory);
function setEmergency(bool on) external;  // guardian only
```

#### `StrategyExecutor`
```solidity
function runWeeklyCycle() external;
function closeYT(uint256 positionId, uint256 minUsdcOut) external;
function emergencyExit(uint256 maxToProcess) external;  // bounded ≤25
function setSlippageBps(uint16 bps) external;          // curator only
```

#### `Curator`
```solidity
function whitelistMarket(address market, bool ok) external;  // timelocked
function setWeeklyBasket(address[] calldata markets) external;  // not timelocked (within whitelist)
function setFee(uint16 bps) external;  // timelocked, max 2000 (20%)
function setFeeRecipient(address r) external;  // timelocked
function pauseAll() external;  // guardian, immediate
function unpause() external;   // admin
function rewireStrategy(address newExecutor) external;  // timelocked
```

### Events (mandatory, indexer-friendly)
```solidity
event Deposited(address indexed user, uint256 amount, uint256 shares, uint256 totalDepositors, uint256 totalAssets);
event Withdrawn(address indexed user, uint256 amount, uint256 shares);
event YieldHarvested(uint256 indexed cycleId, uint256 amount, uint256 timestamp);
event TreasuryDeployed(uint256 indexed cycleId, uint256 amount, address[] markets);
event RebalanceExecuted(uint256 indexed cycleId, address[] basket, uint256[] allocations, bytes edgeMetrics);
event PositionOpened(uint256 indexed positionId, address indexed market, uint128 ytAmount, uint128 usdcCost, uint64 maturityTs);
event PositionSettled(uint256 indexed positionId, uint256 indexed cycleId, uint256 payout, int256 pnlBps);
event Claimed(address indexed user, uint256 amount);
event Paused(address indexed guardian, uint256 timestamp);
event Unpaused(address indexed admin, uint256 timestamp);
event EmergencyExit(uint256 indexed cycleId, address triggeredBy, string reason);
event WhitelistProposed(address indexed market, uint256 effectiveAt);
event WhitelistCommitted(address indexed market, bool included);
event WhitelistVetoed(address indexed market, address indexed guardian);
```

### Custom Errors (no require-strings)
```solidity
error CapExceeded();
error DepositorCapReached();
error MinDepositNotMet();          // $100 minimum to prevent sybil
error NotCurator();
error NotKeeper();
error NotGuardian();
error NotAdmin();
error Paused();
error NotPaused();
error NotInWhitelist(address market);
error TimelockNotElapsed(uint256 effectiveAt);
error PositionNotOpen(uint256 id);
error SlippageExceeded(uint256 expected, uint256 actual);
error EmergencyBatchTooLarge();    // > 25
error YieldUnderflow();             // tried to sweep below HWM
error PrincipalUntouchable();       // any path that would violate I1
```

### Constructor Parameters

#### `PrincipalVault`
- `IERC20 _usdc`
- `IMorphoVault _morpho`
- `IWiring _wiring`
- `uint128 _depositCap` (= 1_000_000e6)
- `uint32 _depositorCap` (= 1000)
- `uint128 _minDeposit` (= 100e6)

#### `LotteryTreasury`
- `IERC20 _usdc`
- `IWiring _wiring`

#### `PositionManager`
- `IWiring _wiring`

#### Periphery (UUPS init)
- `Curator.initialize(address safeMultisig, uint256 timelockDelay=2 days, address guardian, IWiring wiring)`
- `StrategyExecutor.initialize(address pendleRouter, IWiring wiring, uint16 slippageBps=300)`
- `YieldSweeper.initialize(IWiring wiring)`
- `Wiring.initialize(address admin)`

### OZ / Solady Modules to Import

```solidity
// PrincipalVault
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// LotteryTreasury, PositionManager
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

// Periphery (all UUPS)
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {TimelockControllerUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// Across all contracts
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
```

## Test Scenarios Required Before Deploy

### P0 — Invariant Tests (BLOCKING)

| Invariant | Foundry Handler | Pass Criteria |
|---|---|---|
| I1 Principal isolation | `PrincipalHandler` (deposit/withdraw/sweep/openPos/closePos/emExit fuzz) | 50K runs × 256 calls, zero violations |
| I2 Treasury bound | `TreasuryHandler` | sumStrategySpend ≤ sumYieldSwept always |
| I3 Long-only | `WhitelistHandler` | No PT/LP markets ever in whitelist |
| I4 Index monotonicity | `LotteryHandler` | globalShareIndex never decreases |
| I5 Supply conservation | `SupplyHandler` | totalSupply == sum(balances) always |

### P1 — Integration Tests (Base fork)

| Test | Steps | Expected |
|---|---|---|
| `test_fork_fullDepositCycle` | deposit 1000 USDC, warp 7d, sweep, execute basket of 3 markets, close 1 at 5x, settle | shares minted; treasury accrues; index increases |
| `test_fork_capEnforcement` | 1000 unique addresses each deposit $1000 | 1001st reverts; 1000 succeeds |
| `test_fork_emergencyExit` | open 5 positions, guardian pause + emExit | all positions closed; treasury restored; paused |
| `test_fork_pendleRouterIntegration` | open YT on real Pendle market on Base, redeem | round-trip USDC → YT → USDC works |
| `test_fork_morphoIntegration` | deposit + warp + verify Morpho yield | totalAssets() grew |
| `test_fork_donationAttack` | attacker first-deposits 1 wei, donates 1000 USDC, victim deposits | victim shares > 0, victim recovers ≥99.9% of deposit |

### P2 — Access Control Tests

| Function | Caller | Expected |
|---|---|---|
| `pv.deposit` | anyone | success within caps |
| `pv.sweepYield` | not Wiring.yieldSweeper() | revert NotKeeper |
| `cycle.runWeeklyCycle` | not curator/keeper | revert |
| `pause` | not guardian | revert NotGuardian |
| `whitelistMarket` | not curator | revert |
| `whitelistMarket` | curator immediate execute | revert TimelockNotElapsed |

### P3 — Edge Cases

- Zero-amount deposit/withdraw → revert
- Dust withdrawal (1 wei) → revert MinDepositNotMet on first deposit
- Pendle market delists mid-position → markDelisted path → emergencyExit
- Curator submits empty basket → revert
- Curator submits basket with non-whitelisted market → revert
- Reentrancy on Morpho callback → guarded
- Reentrancy on Pendle Router → guarded
- Front-running curator basket selection → minYtOut + 5min deadline mitigates

### P4 — Gas Targets (snapshot in CI)

```
deposit:           ≤ 200,000 gas
redeem:            ≤ 250,000 gas
sweepYield:        ≤ 100,000 gas
runWeeklyCycle(5): ≤ 2,000,000 gas
closeYT:           ≤ 300,000 gas
claim:             ≤ 100,000 gas
emergencyExit(20): ≤ 6,500,000 gas (under Base 30M block limit)
```

## Day-by-Day Build Plan (HARD COMMIT)

| Day | Output | Gate |
|---|---|---|
| **Day 0 (Sun)** | Pendle V4 router rehearsed on Base fork; multisig signers identified; Foundry project init | Pendle round-trip works on fork |
| **Day 1 (Mon)** | `Wiring`, `PrincipalVault` + ERC4626 inflation defense, basic deposit/withdraw fork test | Deposit $1000 → Morpho works |
| **Day 2 (Tue)** | `LotteryTreasury` + share-index, `PositionManager`, `YieldSweeper` + HWM | Yield-isolation invariant test passes |
| **Day 3 (Wed)** | `StrategyExecutor` + Pendle integration | **MAKE-OR-BREAK** — full Pendle round-trip on fork |
| **Day 4 (Thu)** | `Curator` + timelock, full E2E happy path test | Deposit → harvest → execute → close → claim |
| **Day 5 (Fri)** | All P0 invariants passing 10K runs; Slither + 4naly3er + Codex review; fix findings | 0 high/medium static-analysis findings |
| **Day 6 (Sat)** | Frontend (Next.js + Wagmi); deploy scripts; multisig live | Localhost UI talks to local fork |
| **Day 7 (Sun)** | Base Sepolia deploy, internal dogfooding ($50-200 each) | Live testnet, tweet-ready demo |

### Days 8-14 (mainnet path)
- Cantina micro-audit on `StrategyExecutor` + `LotteryTreasury` (~$5K, 3-5 days)
- Spearbit office hours (free 30min)
- Fix findings, re-test
- Mainnet deploy with **$250K starter cap** (NOT $1M)
- Public launch + Twitter campaign
- $1M cap unlocks after 48h clean operation

## Hard Cuts From Scope (DO NOT BUILD IN V1)

- ❌ Polymarket integration
- ❌ Options layer (Lyra/Premia/etc.)
- ❌ NFT/SBT round receipts
- ❌ Curator governance via token vote
- ❌ Multi-asset (USDT/DAI/ETH)
- ❌ Multi-chain
- ❌ Governance token
- ❌ Automated keeper bot (manual trigger fine for $1M cap)
- ❌ Per-user position selection
- ❌ Insurance fund
- ❌ Halmos / formal verification (Foundry invariants are sufficient for v1)

Each is Phase 2/3/4 in `expansion-plan.md`.
