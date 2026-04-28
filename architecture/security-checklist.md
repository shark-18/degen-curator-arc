# Security Checklist — dCURATOR Pre-Deploy

**Format:** Every item is a blocking gate. PR cannot merge to `main` and contracts cannot deploy until every Must-Have is checked.

## CARDINAL INVARIANTS (must hold under all fuzz inputs)

- [ ] **I1 — Principal Conservation:** `PrincipalVault.totalAssets() ≥ Σ user_deposits − Σ user_withdrawals` always
  - Foundry invariant test: `invariant_principalNeverExtracted` passes 50K runs × 256 calls
- [ ] **I2 — Treasury Bound:** `cumulative_strategy_spend ≤ cumulative_yield_swept`
  - Foundry invariant test: `invariant_treasurySpendBoundedByYield`
- [ ] **I3 — Long-Only:** every position is YT, never PT/LP/debt
  - Compile-time: whitelist function only accepts addresses where `IPMarket.isExpired()` is callable
- [ ] **I4 — Share Index Monotonicity:** `globalShareIndex` strictly non-decreasing
- [ ] **I5 — Supply Conservation:** `totalSupply == Σ balanceOf(user)`

## MUST-HAVE (BLOCKING for any deploy)

### Architecture
- [ ] `PrincipalVault` is `immutable` (no proxy, no upgrade path) — non-negotiable
- [ ] `LotteryTreasury` is `immutable`
- [ ] `PositionManager` is `immutable`
- [ ] `StrategyExecutor` has **zero** compile-time references to `PrincipalVault` (verifiable by `grep`)
- [ ] `PrincipalVault.sweepYield()` callable ONLY by `Wiring.yieldSweeper()` (modifier check)
- [ ] All approvals are exact-amount; no `type(uint256).max` anywhere in the system

### ERC-4626 Hardening
- [ ] Use OZ 5.1.0 `ERC4626` with `_decimalsOffset() = 6` (virtual shares against inflation attack)
- [ ] OR initial dead-share mint to `address(0)` in constructor (alternative)
- [ ] Round in protocol favor on every conversion (`OZ.Math.Rounding.Floor` for user, `Ceil` for protocol)

### Reentrancy
- [ ] `nonReentrant` (transient storage based — EIP-1153) on every state-changing external function
- [ ] CEI pattern enforced — state changes before external calls
- [ ] Read-only reentrancy: `pricePerShare` view computed off `totalAssets()` which only reads `morphoVault.convertToAssets`

### Token Safety
- [ ] Solady `SafeTransferLib` for all USDC transfers (handles paused-mode failures)
- [ ] No `tx.origin` anywhere
- [ ] Custom errors only (no require-strings)
- [ ] `solc 0.8.26` — built-in overflow checks; no `unchecked` blocks except provably safe loop counters

### Pendle Integration
- [ ] One position per tx (atomic; no batching with try/catch in normal cycle path)
- [ ] `ApproxParams` derived off-chain with **≥10% buffer** (`guessMin = quote × 0.9`, `guessMax = quote × 1.1`)
- [ ] `minYtOut` derived from off-chain quote with **≤1% slippage tolerance**
- [ ] `deadline ≤ 5 minutes` from block timestamp
- [ ] `LimitOrderData` passed empty (no off-chain order routing in v1)
- [ ] StrategyExecutor approval: `forceApprove(router, amt)` before swap, `forceApprove(router, 0)` immediately after
- [ ] **Per-position entry cap: ≤ 2% of Pendle market TVL at entry** (Security agent veto from 5%)
- [ ] **Per-cycle deployment cap: ≤ 25% of treasury into any single market**
- [ ] **Per-position max: ≤ 20% of treasury**
- [ ] Pendle V4 router address verified against canonical Base deployment at deploy time

### Caps
- [ ] Deposit cap: `if (totalAssets() + assets > 1_000_000e6) revert CapExceeded()`
- [ ] Depositor cap: O(1) counter incremented on first-mint-to-zero, decremented on burn-to-zero, capped at 1000
- [ ] **Minimum deposit: $100 USDC** to prevent sybil cap-griefing (1000 sybils × $100 = $100K opportunity cost > grief value)
- [ ] Cap check happens AFTER share calculation (in `_deposit` hook)

### Access Control
- [ ] 2/3 multisig (Gnosis Safe on Base) for Curator role
- [ ] 3/5 multisig for Admin role (UUPS upgrade authority)
- [ ] Guardian role on a separate hot key on a separate device
- [ ] **48-hour timelock** on whitelist additions and parameter changes
- [ ] **No timelock** on basket selection (within already-whitelisted markets) — operational requirement
- [ ] **No timelock** on `pause()` — guardian can pause immediately
- [ ] Pause auto-expires after 7 days; admin must renew or unpause
- [ ] Two-step ownership transfer (`Ownable2Step`-equivalent on AccessControl roles)
- [ ] Guardian can VETO pending whitelist additions during the 48h timelock window

### Bounded Operations
- [ ] `emergencyExit(maxToProcess)` with `maxToProcess ≤ 25` (verified against Base 30M gas block limit)
- [ ] Emergency exit uses `try/catch` per market (one bad market doesn't block others)
- [ ] No unbounded loops anywhere else
- [ ] `activeIds` returns from `EnumerableSet` (capped at ~50 max active positions)

### UUPS Safety
- [ ] EIP-7201 namespaced storage on every UUPS contract (StrategyExecutor, Curator, YieldSweeper, Wiring)
- [ ] `__gap[50]` array on every namespaced struct
- [ ] `_authorizeUpgrade` requires Admin role + timelock
- [ ] Upgrade proposals visible via on-chain view function

### Settlement & Lottery Math
- [ ] Sushibar share-index pattern with **1e30 precision**
- [ ] Index update floor-divides; dust stays in treasury
- [ ] User claim floor-divides
- [ ] Settlement is idempotent (`position.settled` flag prevents double-settle)
- [ ] **Position-attribution**: users only accrue from a YT settlement if their shares existed at that position's `openPosition` block (xSUSHI-style attack mitigation)
- [ ] Curator fee taken at settlement, on profit only (loss → no fee), before share-index update

### Static Analysis
- [ ] Slither: 0 high/medium findings
- [ ] 4naly3er: gas optimization findings reviewed (not all actioned, but reviewed)
- [ ] Mythril: 0 high findings
- [ ] Aderyn (optional): 0 high findings

### Testing
- [ ] All P0 invariant tests passing (50K runs)
- [ ] All P1 fork tests passing on Base fork
- [ ] All P2 access control tests passing
- [ ] All P3 edge case tests passing
- [ ] Gas snapshot captured and within targets

## SHOULD-HAVE (pre-mainnet, not blocking testnet)

- [ ] Cantina micro-audit on `StrategyExecutor` + `LotteryTreasury` complete (3-5 days, ~$5K)
- [ ] Spearbit office-hours review pass (free, 30 min)
- [ ] Internal pair review by another DeFi engineer (Innflux/Opyn ecosystem)
- [ ] Pull-based settlement bounty (1bp, max $50) — incentive for prompt settlement
- [ ] Off-chain monitoring: alert if `swept` per cycle deviates >20% from expected APY band
- [ ] Storage-layout regression tests using `forge inspect storage`
- [ ] `LARGE_LOSS` event emitted when emergency exit slippage >5%
- [ ] Migration `migrateMorphoVault(newVault)` timelocked admin function (in case curator vault degrades)
- [ ] Frontend / dashboard with cap counters
- [ ] Deploy scripts (`script/Deploy.s.sol`) for both Sepolia and mainnet
- [ ] Tenderly fork debugging session for one full cycle
- [ ] Operations runbook documented

## NICE-TO-HAVE (hardening / Phase 2)

- [ ] Halmos symbolic invariant testing on principal conservation
- [ ] Certora formal verification on the cardinal invariant
- [ ] Immunefi bug bounty live ($25K cap, scaled to TVL)
- [ ] Solady `ERC4626` consideration if gas optimization warrants
- [ ] Automated keeper bot (Gelato or Chainlink Automation)
- [ ] SBT round receipts (`CycleNFT` ERC-721)
- [ ] Merkle attribution for retroactive cycle rewards
- [ ] Code4rena Lite contest post-mainnet ($5-10K)

## DESIGN VETOES (rejected, do not implement)

1. ❌ ANY path that approves StrategyExecutor on PrincipalVault tokens or Morpho vault shares
2. ❌ PrincipalVault as a UUPS proxy (cardinal sin: holds funds + upgradeable = no)
3. ❌ Curator basket selection without timelock for **new** markets (existing whitelist OK real-time)
4. ❌ Persistent infinite approvals (`type(uint256).max`) anywhere
5. ❌ Single-tx batch deployment across multiple Pendle markets with try/catch fallthrough (atomic only)
6. ❌ Guardian pause without expiry
7. ❌ PT (debt-side) or LP positions in v1 — long-only spec
8. ❌ `block.timestamp` for any randomness
9. ❌ Reading Pendle pool spot price as oracle (only as `minYtOut` gate)
10. ❌ Single-key keeper (use 2/3 hot multisig OR Gelato keeper-network with kill switch)

## Recommended Audit Focus Areas (for Cantina micro-audit)

Spend the $5K audit budget on these contracts and these properties:

1. **`StrategyExecutor.sol` Pendle integration** — TokenInput struct, ApproxParams handling, slippage, deadline, stuck-token recovery, reentrancy
2. **`LotteryTreasury.sol` share-index math** — settlement, fee accrual, claim flow, position-attribution against xSUSHI front-run
3. **Principal isolation invariant** — formal grep that `StrategyExecutor` has zero references to `PrincipalVault`; that `sweepYield` math is correct under loss events
4. **First-depositor inflation mitigation** — concrete fuzz test verifying victim recovery ≥99.9%
5. **UUPS upgrade safety on StrategyExecutor + Curator** — storage layout, what state could a malicious upgrade reach, can it orphan in-flight positions?
6. **Pendle market delisting / sanctions / pre-maturity-illiquidity** — emergency exit completeness across Pendle states
7. **Cap enforcement edge cases** — sybil-cap-griefing minimum-deposit bypass, deposit-cap-after-fee-accrual
8. **Whitelist proposal interface conformance** — can curator add a contract that *looks like* `IPMarket` but isn't?

## Operational Security (post-deploy)

- [ ] Multisig signer keys on hardware wallets, separate locations
- [ ] Guardian key on a separate device from any signer key
- [ ] Curator basket selection done from an air-gapped or dedicated machine
- [ ] Off-chain monitoring service (e.g., OpenZeppelin Defender, Tenderly Alerts) on every Must-Have invariant
- [ ] Incident runbook documented (who calls who, in what order, when)
- [ ] Bug bounty live before TVL > $250K
- [ ] No production deploys on weekends or holidays without 2 engineers on-call
