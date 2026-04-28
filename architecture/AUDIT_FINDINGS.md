# Audit Findings — dCURATOR Pashov-Style Review

**Reviewers:** 4 parallel Pashov-framework agents covering 8 vectors (Vector Scan, Math Precision, Access Control, Economic Security, Execution Trace, Invariant Analysis, Periphery, First Principles).
**Date:** 2026-04-29 (Day 0 deliverable)
**Status:** **5 Critical bugs found that block testnet deploy.** Cardinal principal-isolation invariant is structurally sound; the bugs are in the **lottery economics** and **upgrade safety** layers.

## Severity counts

| Severity | Count | Block Deploy? |
|---|---|---|
| Critical | 5 | YES — fix all before any deploy |
| High | 5 | YES — fix before testnet |
| Medium | 8 | Fix before mainnet |
| Low / Informational | 7 | Fix before $1M cap raise |

---

# CRITICAL — must fix before any deploy

### C-1 — EIP-7201 storage slots are wrong in all 4 UUPS contracts

**Location:**
- `periphery/Wiring.sol:35-36`
- `periphery/Curator.sol:37-38`
- `periphery/StrategyExecutor.sol:55-56`
- `periphery/YieldSweeper.sol:29-30`

**Description:** The hardcoded `bytes32 constant SLOT` in each periphery contract was authored as illustrative bit-patterns and **does not match the EIP-7201 formula** `keccak256(abi.encode(uint256(keccak256(typeId)) - 1)) & ~bytes32(0xff)`. Two of them end in suspiciously round bytes (`d200`, `8e00`) — clearly hand-rolled.

| Contract | Hardcoded (wrong) | Canonical (correct) |
|---|---|---|
| Wiring | `0x9f3aa6c8…b81700` | `0x7404cd9655913f01b956677aa7bc7844f80514a7131b4fb3aea0308e1971f600` |
| Curator | `0xc4d8e2f5…1d200` | `0xfbc4302dcd9159449ee3a52fb8c45e89f5f690bf39087c249ca9f861c3119800` |
| StrategyExecutor | `0xa1b1d6f7…6c8e00` | `0xb7db1080576884bd91eb2cffb2a77b3c2a30d56a6820ab4b6321c96494eb5e00` |
| YieldSweeper | `0x4ee2cd23…85ee00` | `0x193d56f977557616239c7d9df9908a19015f37b43de560760ebdd8b99e9e0500` |

**Impact:**
1. Storage layout audit-trail is broken; auditors using the formula see mismatch.
2. Practical collision risk with adjacent storage / OZ inherited storage isn't bounded by EIP-7201's safety guarantee.
3. **Upgrade-safety regression:** if a future maintainer fixes the slot formula in v2, the v2 implementation reads a different slot than v1 wrote → **complete loss of state on upgrade**, including `coresLocked`, whitelist, basket, timelock timestamps.

**Fix:** Recompute every slot. Add a CI test that asserts each constant equals the formula output. Use `cast index erc7201 "<typeId>"` for verification.

**Test:** `test_eip7201_slots_match_canonical_formula` — for each contract, assert hardcoded == derived.

---

### C-2 — PricePerShare yield extraction sandwich (the dominant economic bug)

**Location:** `core/PrincipalVault.sol:125-127` (`totalAssets`), `core/PrincipalVault.sol:150-167` (`_deposit`), `core/PrincipalVault.sol:170-198` (`_withdraw`).

**Description:** `totalAssets()` returns `MORPHO.convertToAssets(MORPHO.balanceOf(this))`, which monotonically rises between weekly sweeps as Morpho earns yield. Because OZ ERC-4626 mints shares at `assets.mulDiv(totalSupply + 10^offset, totalAssets + 1, Floor)`, a fresh depositor mints shares at the **inflated** pricePerShare and is proportionally entitled to the unswept yield that existed BEFORE they deposited.

**Worked example:**
- 1,000 honest depositors holding $1M, Morpho earned $1,000 yield since last sweep.
- Attacker deposits $100K just before sweep: `totalAssets() = $1.001M`, attacker gets ~9.08% of dCURATOR.
- Sweep happens: yield = $1,000 routed to LotteryTreasury.
- Attacker now owns 9.08% of all future treasury settlements while contributing zero work.
- Same-block: attacker withdraws principal back. Cost: gas only. Profit: ~9.08% of every subsequent payout that includes this yield.

**Impact:** Honest depositors' lottery returns are diluted on every sweep. With $1M cap and $2K/week yield, JIT MEV extracts ~$10-25K/year of expected payout from honest holders. **The "no-loss" promise on principal still holds, but the "honest holders get 49% APR upside" promise is broken.**

**Fix (recommended, simplest):** Override `_convertToShares` and `_convertToAssets` to use `principalHWM` instead of `totalAssets()`. Because principalHWM tracks user-deposited principal, `pricePerShare` stays at exactly 1 USDC per share (modulo virtual offset). Yield then enters ONLY through the lottery flow.

```solidity
function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
    return assets.mulDiv(totalSupply() + 10**_decimalsOffset(), principalHWM + 1, rounding);
}
function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
    return shares.mulDiv(principalHWM + 1, totalSupply() + 10**_decimalsOffset(), rounding);
}
```

**Alternative fix:** Auto-trigger `sweepYield()` at the start of every `_deposit` and `_withdraw`. Forces yield separation at every entry/exit.

**Test:** `test_yieldSandwich_revertOrYieldsZero` — fuzz attacker deposits various amounts before/after sweeps, assert net P&L ≤ 0.

---

### C-3 — Curator can drain LotteryTreasury instantly via `rewireStrategy` (no timelock)

**Location:** `periphery/Curator.sol:154-157` calling `Wiring.setStrategyExecutor` at `periphery/Wiring.sol:75-78`.

**Description:** Architecture spec mandates "48-hour timelock on whitelist additions and parameter changes" and rates Curator's blast radius as "drain ~1 cycle's yield (~$2K) into hostile market AFTER timelock — 48h window for guardian veto." But `rewireStrategy` calls `Wiring.setStrategyExecutor` directly with no propose/commit cycle. The code comment claims "Timelocked at the Wiring layer via DEFAULT_ADMIN_ROLE separation" — **this is false**. `setStrategyExecutor` is gated by `CURATOR_ROLE`, not `DEFAULT_ADMIN_ROLE`, and there is no timelock anywhere.

**Impact:** A compromised 2/3 Curator multisig drains the entire LotteryTreasury in 2 txs:
```
tx1: curator.rewireStrategy(maliciousExecutor)              // instant
tx2: maliciousExecutor.drain()                               // self-approves treasury, transferFrom
```
Up to 100% of cumulative swept yield (potentially $100K+ at full vault utilization).

**Fix:**
1. Add `proposeRewireStrategy(address)` / `commitRewireStrategy(address)` pair in Curator with 48h timelock, mirroring the whitelist pattern.
2. Make `Wiring.setStrategyExecutor` gated on `DEFAULT_ADMIN_ROLE` (admin multisig 3/5).
3. Wrap Curator behind a real `TimelockController` (which the architecture says it should inherit but doesn't — see C-4).

**Test:** `test_rewireStrategy_revertsBeforeTimelock`, `test_curatorCannotDrainTreasuryViaInstantRewire`.

---

### C-4 — Curator is NOT a `TimelockController` despite architecture claim

**Location:** `periphery/Curator.sol:16` (inheritance) vs `architecture/architecture.md:42`.

**Description:** Architecture says Curator inherits `TimelockControllerUpgradeable`. Implementation only inherits `Initializable, UUPSUpgradeable, AccessControlUpgradeable`. The 48-hour timelock is implemented manually only for `commitWhitelistMarket`. **All other privileged actions execute instantly:**
- `setFee` (can bump fee from 10% → 20% mid-cycle to inflate compromised curator's cut)
- `setFeeRecipient` (redirect all profits)
- `setWeeklyBasket` (acceptable per spec — within whitelist only)
- `unpauseAll` (instantly defeats guardian's pause)
- `rewireStrategy` (see C-3)

**Impact:** A 1-day-window-of-compromise on the 2/3 multisig becomes catastrophic instead of bounded.

**Fix:** Wrap Curator behind an OZ `TimelockController` proxy that holds `CURATOR_ROLE`. The multisig can only enqueue ops; the timelock executes after delay. This is the architecturally correct pattern.

**Test:** `test_setFee_revertsBeforeTimelock`, `test_setFeeRecipient_revertsBeforeTimelock`, `test_unpauseAll_revertsBeforeTimelock`.

---

### C-5 — Position-attribution claimed in spec but NOT implemented in code

**Location:** `core/LotteryTreasury.sol:175-194` (`_accrue`), `core/PositionManager.sol:60` (`entryBlock` is recorded but never consumed).

**Description:** Architecture explicitly promises (architecture.md:25, security-checklist.md:88): "Position-attribution: users only accrue from a YT settlement if their shares existed at that position's openPosition block (xSUSHI-style attack mitigation)." The code records `entryBlock` on `Position` (`PositionManager.sol:60`, `IPositionManager.sol:21`) — but `LotteryTreasury._accrue` **never reads it**. Pure sushibar, last-balance-wins.

**Attack:**
1. Attacker monitors mempool. Sees `closeYT(positionId, …)` queued with profitable `minUsdcOut`.
2. Front-runs with `deposit($X)` in same block, before `closeYT`.
3. Settlement updates `globalShareIndex`. Attacker's `userIndexCheckpoint` was set in `_update` BEFORE settlement.
4. Same block: attacker `redeem(shares)` → triggers accrue → `userClaimable += proRataShare`.
5. Attacker `claim()` → free USDC.

With flash-loan-able USDC, attacker can extract up to ~33% of every profitable settlement.

**Worked example:** Position cost $1K, settles at $50K (50× hit). Attacker flash-loans $1M, deposits, calls closeYT, withdraws, claims, repays. Profit: ~$15K per settlement.

**Impact:** Defeats the marketed differentiator vs PoolTogether ("position-attribution"). All high-payoff settlements get JIT-extracted. Long-term holders see ~0 lottery returns. Product becomes a slow-bleed Morpho wrapper.

**Fix (preferred):** Snapshot `totalSupply` at `openPosition` as `Position.snapshotTotalSupply`. At settlement, distribute payout using that snapshot as the divisor and an attribution mapping `userPositionAttributable[positionId][user] = userBalanceAtEntry / snapshotTotalSupply`. Users with zero balance at entry get zero from this position.

**Cheaper fix:** N-block deposit lock — newly deposited shares cannot accrue from settlements until N blocks (>1 day) after deposit. Breaks JIT economics.

**Test:** `test_jitFlashloanCannotExtractSettlement`, `test_entryBlock_actuallyAffectsAccrual`.

---

# HIGH — must fix before testnet

### H-1 — Periphery contracts missing `_disableInitializers()` — implementation init front-run

**Location:** `Wiring.sol`, `Curator.sol`, `StrategyExecutor.sol`, `YieldSweeper.sol` — none have a constructor.

**Description:** UUPS implementations must call `_disableInitializers()` in their constructor. Otherwise, an attacker can call `initialize()` on the implementation contract directly post-deploy, become its admin, and call `upgradeToAndCall` to brick or reroute it.

**Critical escalation:** if the attacker reroutes Wiring's view functions (`yieldSweeper()`, `lotteryTreasury()`) to attacker-controlled addresses, they can drain every cycle's yield via `PrincipalVault.sweepYield()` (which gates on `WIRING.yieldSweeper()`).

**Fix:**
```solidity
/// @custom:oz-upgrades-unsafe-allow constructor
constructor() {
    _disableInitializers();
}
```
Add to every UUPS contract.

**Test:** `test_uups_impl_cannot_be_initialized_directly` — attempt to call `initialize` on each impl, expect `InvalidInitialization` revert.

---

### H-2 — `LotteryTreasury.claim(address user)` allows force-claim — tax/grief vector

**Location:** `core/LotteryTreasury.sol:196-203`.

**Description:** `claim` accepts an arbitrary `user` argument. Anyone can repeatedly trigger small claims for a victim. In some jurisdictions, USDC receipt is a taxable event at the moment of receipt — attacker can fragment a victim's basis or push them into a higher reporting bracket within a tax year.

**Fix:** Restrict to `msg.sender == user`, or add `claimFor(address user)` with explicit per-user opt-in via `approvedClaimer[user][caller] = true`.

**Test:** `test_claim_revertsForUnauthorizedCaller`.

---

### H-3 — `closeYT` is permissionless with no slippage floor — griefing & MEV

**Location:** `periphery/StrategyExecutor.sol:122-130`.

**Description:** The skeleton lets anyone call `closeYT(id, minUsdcOut=0)` to force-close a YT position at near-zero proceeds. Even with non-zero minOut, MEV bots can sandwich Pendle's AMM. Loss is socialized across all dCURATOR holders via the share index.

**Fix:**
1. Restrict to `KEEPER_ROLE` for the normal path.
2. Allow public-with-bounty only AFTER `position.maturityTs - 7 days`.
3. Enforce `minUsdcOut >= TWAP × (1 - slippageBps)` using Pendle's TWAP oracle.

**Test:** `test_closeYT_permissionless_revertsBeforeMaturity`, `test_closeYT_keeper_minOutEnforced`.

---

### H-4 — Pause has no auto-expiry (spec violation)

**Location:** `core/PrincipalVault.sol:59-61, 89-92, 256-264` and `architecture/security-checklist.md:67`.

**Description:** Spec mandates 7-day auto-expiry. Implementation has only a bool `paused`. Compromised guardian can pause indefinitely until Curator multisig responds.

**Fix:** Add `pauseExpiresAt`, auto-clear in `whenNotPaused` modifier. Optional `extendPause()` callable by guardian.

**Test:** `test_pause_autoExpiresAfter7Days`.

---

### H-5 — `Wiring.setCurator` doesn't revoke old curator's `CURATOR_ROLE`

**Location:** `periphery/Wiring.sol:85-89`.

**Description:** Code grants `CURATOR_ROLE` to the new address but never revokes it from the old one. Old (compromised) address retains full curator powers indefinitely. Combined with C-3 (no timelock on rewire), the leaked key drains treasury immediately after rotation.

**Fix:**
```solidity
function setCurator(address a) external onlyRole(DEFAULT_ADMIN_ROLE) {
    address old = _s().curator;
    if (old != address(0)) _revokeRole(CURATOR_ROLE, old);
    _grantRole(CURATOR_ROLE, a);
    _s().curator = a;
    emit WiringUpdated("curator", old, a);
}
```

**Test:** `test_setCurator_revokesOldCuratorRole`.

---

# MEDIUM — fix before mainnet

### M-1 — `markDelisted` has no on-chain effect

`core/PositionManager.sol:89-95` only emits an event; doesn't change `position.state`, doesn't add a `delisted` flag. Off-chain keepers must subscribe to events; `emergencyExit` has no actual prioritization. **Fix:** add `mapping(uint256 => bool) delisted` and have `emergencyExit` iterate delisted-first.

### M-2 — Wiring UUPS upgrade can re-point "immutable" cores

`periphery/Wiring.sol:53-72` + `_authorizeUpgrade`. Even though `setAll` is one-shot via `coresLocked`, a Wiring **upgrade** can deploy a new impl that ignores the lock or exposes new setters. Admin (3/5 multisig) can re-point `principalVault()` to a malicious clone, draining LotteryTreasury via spoofed `balanceOf`. **Fix:** make core slots truly immutable via `address public immutable principalVault` set in Wiring impl constructor (constructor immutables survive UUPS upgrade because they live in bytecode, not storage).

### M-3 — Infinite USDC approval to Morpho violates "no infinite approvals"

`core/PrincipalVault.sol:118` does `_usdc.forceApprove(address(_morpho), type(uint256).max)`. Security-checklist line 24 forbids this; design veto #4 reiterates. Morpho MetaMorpho vaults are themselves curated and could route to a malicious adapter. **Fix:** exact-amount approval per-deposit (`forceApprove(MORPHO, assets)` then `forceApprove(MORPHO, 0)`).

### M-4 — `notifyPurchase` lacks reentrancy guard + can be poisoned by malicious executor

`core/LotteryTreasury.sol:120-130`. If attacker controls StrategyExecutor (via C-3 rewire path), they can call `notifyPurchase(0, cumulativeYieldSwept)` to set `cumulativeStrategySpend == cumulativeYieldSwept`. After rewiring back, all future legitimate purchases revert with `I2 violated`. **Permanent DoS** of the lottery side because LotteryTreasury is immutable. **Fix:** add `nonReentrant` + tie spend-tracking to actual transferFrom amounts.

### M-5 — Double `accrueOnBalanceChange` on every deposit/withdraw

`core/PrincipalVault.sol:156` and `201-208`. The explicit accrue calls in `_deposit` / `_withdraw` are subsumed by the `_update` hook — they're dead code. ~3K wasted gas per call × 2 = 6K per state change. **Fix:** remove the explicit calls.

### M-6 — Sybil-transfer bypasses `minDeposit` cap

`core/PrincipalVault.sol:201-225`. `minDeposit` (100 USDC) is only enforced on `_deposit`, not on transfers through `_update`. Attacker deposits 100 USDC once, transfers 1 wei dCURATOR each to 999 fresh sybils → depositorCount = 1000 → DoS for legitimate users. **Cost: ~$1.** **Fix:** in `_update`, when crediting a NEW depositor, require value ≥ minDeposit (or count only ≥minDeposit holders toward cap).

### M-7 — `notifyPurchase` cost-basis can be overwritten if positionId reused

`core/LotteryTreasury.sol:120-130`. Defense-in-depth: revert if `positionCostBasis[positionId] != 0`.

### M-8 — Veto race: curator can re-propose to wipe pending guardian veto

`periphery/Curator.sol:68-93`. Both `propose` and `veto` are visible in mempool. Malicious curator can race guardian veto by re-proposing immediately. **Fix:** per-proposal nonce; veto must reference the specific nonce.

---

# LOW / INFORMATIONAL

| # | Issue | Location | Fix |
|---|---|---|---|
| L-1 | Direct USDC donations to PrincipalVault are unrecoverable | `PrincipalVault.sol:125-127` | Add `recoverDonatedUSDC` callable by Guardian, route to LotteryTreasury |
| L-2 | Admin can transiently self-grant guardian via `Wiring.setGuardian` | `Wiring.sol:91-94` | Document, or split admin/guardian-setter roles |
| L-3 | `proposeWhitelistMarket` parameter `bool ok` is ignored | `Curator.sol:68-73` | Either implement remove-with-timelock or drop the parameter |
| L-4 | No `emergencyRemoveFromWhitelist` for committed markets | `Curator.sol` | Add guardian-callable removal |
| I-1 | `IWiring` interface missing `setAll` | `interfaces/IWiring.sol` | Add to interface |
| I-2 | dCURATOR transfer 2-3× more expensive than ERC-20 (cross-contract accruals) | `PrincipalVault._update` | Document |
| I-3 | `settle` doesn't require position registered via notify (overcharges fees if cost=0) | `LotteryTreasury.sol:134-169` | `require(positionCostBasis[id] > 0)` |

---

# Verified safe (no findings)

- ✅ **Zero on-chain oracles.** Confirmed by grep — no price reads, no Chainlink/Pyth/TWAP feeds. Cannot be Mango'd, Cream'd, BonqDAO'd.
- ✅ **First-depositor inflation attack neutralized.** OZ ERC4626 with `_decimalsOffset() = 6` + totalAssets reads from Morpho (not direct USDC balance) means donation attack can't inflate share price.
- ✅ **Direct USDC donation doesn't inflate totalAssets.** `totalAssets()` reads `MORPHO.convertToAssets(MORPHO.balanceOf(this))`, not `USDC.balanceOf(this)`. Donated USDC is stuck (UX issue, not security).
- ✅ **Standard reentrancy.** `nonReentrant` (transient) on every state-changing fn. Morpho deposit/withdraw use standard ERC-4626 (no callbacks). Pendle V4 router has no caller callbacks. USDC has no ERC-777 hooks.
- ✅ **CARDINAL INVARIANT I1 (principal isolation) is structurally sound.** PrincipalVault has no admin extraction path. `sweepYield` math (`ta - hwm`, revert on underflow) is bounded by HWM. `StrategyExecutor` has zero compile-time references to PrincipalVault. The bugs above affect lottery economics and upgrade safety, NOT principal custody.
- ✅ **Guardian compromise economics bounded.** Guardian can pause (DoS only) and emergencyExit (slippage loss bounded by 25 positions × ~3% = ~$30K worst case on $1M cap).

---

# Fix Priority Order

**Block testnet (must fix first):**
1. **C-1** Recompute EIP-7201 slots + add CI assertion
2. **C-5** Implement position-attribution (or remove the spec claim)
3. **C-2** Override `_convertToShares`/`_convertToAssets` to use `principalHWM`
4. **C-3 + C-4** Wrap Curator in `TimelockController`, gate `setStrategyExecutor` on admin
5. **H-1** Add `_disableInitializers()` constructors

**Block mainnet:**
6. **H-2** Restrict `claim(user)` to `msg.sender == user`
7. **H-3** Gate `closeYT` to keeper + TWAP slippage floor
8. **H-4** Pause auto-expiry
9. **H-5** Revoke old curator on rotation
10. **M-1 through M-8** Per their fixes

**Block $1M cap raise:**
11. **L-1 through I-3** Per their fixes
12. Cantina micro-audit ($3-5K) on the patched contracts

---

# Open Questions for the Builder

1. **Position-attribution implementation choice (C-5):** snapshot-totalSupply-at-entry vs N-block deposit-lock vs full TWAB? The first preserves UX, the second is cheapest, the third matches PoolTogether's reference.
2. **TimelockController integration (C-4):** wrap Curator in the OZ stock TimelockController, or implement propose/commit pairs in Curator itself? OZ stock is more battle-tested.
3. **Exact-amount Morpho approvals (M-3):** acceptable 3K extra gas per deposit? Probably yes on Base.
4. **Re-run backtest under "exit at AMM mark" assumption** (Research finding from Day 0) — orthogonal to these audit findings but still required before user-facing return claims.

The audit doesn't change the day-by-day plan in `mvp-scope.md` — it ADDS work to Day 4-5 (apply fixes, re-test). Realistic timeline shifts from Day 7 testnet to **Day 9-10 testnet, Day 16-18 mainnet beta @ $250K cap.**
