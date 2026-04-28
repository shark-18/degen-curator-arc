# Testing Plan — dCURATOR

**Source:** synthesized from 4 Pashov-style audit agents covering 8 vectors. Each test maps to specific findings in `AUDIT_FINDINGS.md`.

**Foundry config:**
```toml
[profile.default.invariant]
runs = 256
depth = 256
fail_on_revert = false

[profile.ci.invariant]
runs = 50_000
depth = 256
shrink_run_limit = 5000
```

CI runs `FOUNDRY_PROFILE=ci forge test --invariant-runs 50000` on every PR.

---

## P0 — Invariant Tests (BLOCKING — must pass on every PR)

These prove the cardinal claims. Failure = no deploy.

### `invariant_principalNeverExtracted` (I1, cardinal)
```solidity
function invariant_principalNeverExtracted() public view {
    assertGe(pv.totalAssets(), pv.principalHighWater(), "I1 violated");
}
```
Handler: deposit/withdraw/sweep/openPosition/closePosition/emergencyExit fuzz. 50K runs × 256 calls.

### `invariant_principalHWMMatchesUserAccounting` (I1')
```solidity
function invariant_principalHWMMatchesUserAccounting() public view {
    uint256 expected = handler.sumOfDeposits() - handler.sumOfWithdrawals();
    assertEq(pv.principalHighWater(), expected, "I1' violated");
}
```
**Note:** currently fails because of C-2 (yield extraction sandwich leaks HWM). Must pass after C-2 fix.

### `invariant_treasurySpendBoundedByYield` (I2)
```solidity
function invariant_treasurySpendBoundedByYield() public view {
    assertLe(lt.cumulativeStrategySpend(), lt.cumulativeYieldSwept(), "I2 violated");
}
```

### `invariant_shareIndexMonotone` (I4)
```solidity
function invariant_shareIndexMonotone() public view {
    assertGe(lt.globalShareIndex(), handler.lastObservedIndex(), "I4 violated");
}
```

### `invariant_supplyEqualsSumBalances` (I5)
```solidity
function invariant_supplyEqualsSumBalances() public view {
    assertEq(pv.totalSupply(), handler.sumOfAllBalances(), "I5 violated");
}
```

### `invariant_lotteryYieldGoesToHonestHolders` (new — for C-2 + C-5)
After every cycle, every honest holder's share of swept yield + settlements equals their proportional contribution-time-weighted share. JIT depositors must extract zero.
```solidity
function invariant_jitDepositorExtractsZero() public view {
    for (uint256 i; i < handler.jitActorCount(); ++i) {
        address jit = handler.jitActor(i);
        // JIT actors entered after a position opened and exited before settlement
        assertEq(lt.claimableOf(jit) + handler.alreadyClaimed(jit), 0, "JIT extracted lottery yield");
    }
}
```

---

## P1 — Critical Bug Regression Tests (each maps to a finding)

### `test_eip7201_slots_match_canonical_formula` (C-1)
For each UUPS contract:
```solidity
function test_wiring_storageSlot_isCanonicalERC7201() public {
    bytes32 expected = keccak256(abi.encode(
        uint256(keccak256("dcurator.storage.v1.Wiring")) - 1
    )) & ~bytes32(uint256(0xff));
    assertEq(_extractWiringSlot(), expected);
}
// repeat for Curator, StrategyExecutor, YieldSweeper
```

### `test_yieldSandwich_revertOrYieldsZero` (C-2)
```solidity
function test_yieldSandwich(uint256 attackerDeposit, uint256 pendingYield) public {
    attackerDeposit = bound(attackerDeposit, 100e6, 1e12);
    pendingYield = bound(pendingYield, 1e6, 1e10);
    // setup: existing depositors + Morpho yield accrued
    _seedDeposits(900_000e6);
    _injectMorphoYield(pendingYield);

    uint256 attackerStartUSDC = USDC.balanceOf(attacker);
    vm.startPrank(attacker);
    pv.deposit(attackerDeposit, attacker);
    yieldSweeper.sweep();  // or natural sweep
    pv.redeem(pv.balanceOf(attacker), attacker, attacker);
    uint256 attackerEndUSDC = USDC.balanceOf(attacker);
    vm.stopPrank();

    assertLe(attackerEndUSDC, attackerStartUSDC, "attacker extracted yield");
}
```

### `test_jitFlashloanCannotExtractSettlement` (C-5)
```solidity
function test_jitFlashloanCannotExtractSettlement(uint256 settlementSize, uint256 flashAmount) public {
    flashAmount = bound(flashAmount, 1e6, 1e13);
    settlementSize = bound(settlementSize, 1e6, 1e12);
    _seedDeposits(900_000e6);
    uint256 positionId = _openPositionWithExpectedPayout(settlementSize);

    flashLender.flashLoan(USDC, flashAmount, abi.encodeCall(this._jitAttack, (positionId)));
    // _jitAttack: deposit → closeYT → withdraw → claim → repay
    assertLe(USDC.balanceOf(attacker), attackerStartUSDC, "JIT extracted settlement");
}
```

### `test_rewireStrategy_revertsBeforeTimelock` (C-3)
```solidity
function test_rewireStrategy_isTimelocked() public {
    address malicious = address(0xBAD);
    vm.prank(curatorMultisig);
    vm.expectRevert(TimelockNotElapsed.selector);
    curator.commitRewireStrategy(malicious);  // before timelock

    vm.prank(curatorMultisig);
    curator.proposeRewireStrategy(malicious);
    vm.warp(block.timestamp + 47 hours);
    vm.expectRevert(TimelockNotElapsed.selector);
    curator.commitRewireStrategy(malicious);

    vm.warp(block.timestamp + 2 hours);  // total 49h
    vm.prank(curatorMultisig);
    curator.commitRewireStrategy(malicious);  // now succeeds
    assertEq(wiring.strategyExecutor(), malicious);
}
```

### `test_curatorCannotDrainTreasuryViaInstantRewire` (C-3)
```solidity
function test_curatorCannotDrainViaInstantRewire() public {
    _seedYield(50_000e6);
    address malicious = address(new MaliciousExecutor());

    vm.prank(curatorMultisig);
    vm.expectRevert();  // post-fix: must require timelocked path
    wiring.setStrategyExecutor(malicious);
}
```

### `test_setFee_setFeeRecipient_unpause_revertBeforeTimelock` (C-4)
Three tests, one per privileged fn. Each asserts revert before timelock and success after.

### `test_uups_impl_cannot_be_initialized_directly` (H-1)
```solidity
function test_wiringImpl_cannotBeInitialized() public {
    Wiring impl = new Wiring();  // raw, not behind proxy
    vm.expectRevert(abi.encodeWithSelector(InvalidInitialization.selector));
    impl.initialize(attacker);
}
// repeat for Curator, StrategyExecutor, YieldSweeper
```

### `test_claim_revertsForUnauthorizedCaller` (H-2)
```solidity
function test_claim_onlyByOwner() public {
    _setupClaimable(victim, 1000e6);
    vm.expectRevert();
    vm.prank(attacker);
    lt.claim(victim);

    vm.prank(victim);
    lt.claim(victim);  // succeeds
}
```

### `test_closeYT_permissionless_revertsBeforeMaturity` (H-3)
```solidity
function test_closeYT_keeperOnly_beforeMaturity() public {
    uint256 id = _openPosition(maturityTs);
    vm.warp(maturityTs - 30 days);  // far before maturity

    vm.expectRevert();
    vm.prank(attacker);
    se.closeYT(id, 0);

    vm.prank(keeper);
    se.closeYT(id, _twapMinOut(id));  // succeeds
}
```

### `test_pause_autoExpiresAfter7Days` (H-4)
```solidity
function test_pauseAutoExpires() public {
    vm.prank(guardian);
    pv.pause();
    assertTrue(pv.paused());

    vm.warp(block.timestamp + 7 days + 1);
    pv.deposit(100e6, alice);  // succeeds because pause auto-expired
    assertFalse(pv.paused());
}
```

### `test_setCurator_revokesOldCuratorRole` (H-5)
```solidity
function test_setCurator_revokesOldRole() public {
    address oldCurator = wiring.curator();
    vm.prank(admin);
    wiring.setCurator(newCurator);

    assertFalse(wiring.hasRole(CURATOR_ROLE, oldCurator));
    assertTrue(wiring.hasRole(CURATOR_ROLE, newCurator));

    vm.expectRevert();
    vm.prank(oldCurator);
    wiring.setStrategyExecutor(maliciousAddr);
}
```

---

## P2 — Medium Bug Regression Tests

### `test_markDelisted_setsOnChainFlag` (M-1)
After fix: `markDelisted` sets `delisted[id] = true`; `emergencyExit` iterates delisted-first.

### `test_wiringUpgrade_cannotRePointCores` (M-2)
After fix: cores are `address public immutable` in Wiring impl. Upgrade to malicious impl that tries to expose `setPrincipalVault` → reverts or has no effect on the immutable.

### `test_morphoApproval_isExactAmount` (M-3)
After every deposit, `USDC.allowance(pv, MORPHO) == 0`.

### `test_notifyPurchase_cannotExceedYieldSwept_inBatch` (M-4)
StrategyExecutor batch where total spend > cumulative yield → no transferFrom succeeds (all-or-nothing).

### `test_doubleAccrue_isRemoved` (M-5)
Mock LotteryTreasury counts `accrueOnBalanceChange` calls; after deposit, counter == 1 (not 2).

### `test_sybilTransfer_doesNotBypassMinDeposit` (M-6)
Alice deposits 100 USDC; transfers 1 wei dCURATOR each to 999 sybils. Either transfers revert OR `depositorCount == 1`.

### `test_notifyPurchase_rejectsDuplicate` (M-7)
Calling `notifyPurchase` for an already-recorded positionId reverts.

### `test_curator_cannotRaceGuardianVeto` (M-8)
Curator proposes, guardian vetoes, curator re-proposes immediately → veto persists for the original proposal nonce.

---

## P3 — Integration Tests (Base mainnet fork)

| Test | Setup | Assertion |
|---|---|---|
| `test_fork_fullCycle` | Base fork, real Morpho USDC vault, real Pendle Router | Deposit → wait 7d → sweep → execute basket → close → settle → claim works end-to-end |
| `test_fork_capEnforcement` | 1000 unique addresses each deposit | 1001st reverts with `DepositorCapReached` |
| `test_fork_emergencyExit` | 5 positions open | Guardian pause + emExit closes all in <25 iterations |
| `test_fork_pendleRouterIntegration` | Real Pendle YT market on Base | Round-trip USDC → YT → USDC works |
| `test_fork_morphoYieldRecognized` | Deposit + warp 7d | `totalAssets() > principalHWM` confirmed |
| `test_fork_donationAttack` | Attacker first-deposits 1 wei + donates 1000 USDC | Victim deposits get >99.9% of fair shares |

---

## P4 — Access Control Tests (full matrix)

For every external function, test:
1. Authorized caller succeeds.
2. Unauthorized caller reverts with the right error.
3. Role-rotated caller has appropriate access.

| Function | Authorized | Unauthorized |
|---|---|---|
| `pv.deposit` | anyone | (no unauth case) |
| `pv.sweepYield` | yieldSweeper | reverts NotYieldSweeper |
| `pv.pause` | guardian | reverts NotGuardian |
| `pv.unpause` | curator | reverts NotCurator |
| `lt.creditYield` | yieldSweeper | reverts NotYieldSweeper |
| `lt.notifyPurchase` | strategyExecutor | reverts NotStrategyExecutor |
| `lt.settle` | positionManager | reverts NotPositionManager |
| `lt.claim` | self only (post-fix) | reverts (post-fix) |
| `lt.accrueOnBalanceChange` | principalVault | reverts NotPrincipalVault |
| `pm.openPosition` | strategyExecutor | reverts |
| `pm.setEmergency` | guardian | reverts |
| `se.runWeeklyCycle` | KEEPER_ROLE | reverts |
| `se.emergencyExit` | guardian | reverts |
| `se.setSlippageBps` | DEFAULT_ADMIN_ROLE | reverts |
| `cu.proposeWhitelistMarket` | CURATOR_ROLE | reverts |
| `cu.vetoWhitelistMarket` | GUARDIAN_ROLE | reverts |
| `cu.setFee` | CURATOR_ROLE + timelock | reverts before timelock |
| `wiring.setAll` | DEFAULT_ADMIN_ROLE, one-shot | second call reverts |
| `wiring._authorizeUpgrade` | DEFAULT_ADMIN_ROLE + timelock | reverts before timelock |

---

## P5 — Static Analysis & Tooling

Pre-commit + CI:
- [ ] `slither contracts/src --exclude-informational --filter-paths "lib|test"` — 0 high/medium findings
- [ ] `4naly3er` — gas optimization findings reviewed
- [ ] `mythril` — 0 high findings on critical contracts (PrincipalVault, LotteryTreasury)
- [ ] `forge inspect <Contract> storage-layout` snapshot in CI; fail on drift
- [ ] `forge inspect <Contract> bytecode --json | jq .runtimeBytecode | wc -c` < 24KB per contract

Optional Phase 2:
- [ ] Halmos symbolic verification on `invariant_principalNeverExtracted`
- [ ] Certora formal proof of cardinal invariant

---

## P6 — Foundry Handler Outline (the critical missing piece)

The current `PrincipalIsolation.invariant.t.sol` is a stub. A real handler needs to mirror live state:

```solidity
contract DegenCuratorHandler is Test {
    PrincipalVault pv;
    LotteryTreasury lt;
    PositionManager pm;
    StrategyExecutor se;
    MockMorphoVault morpho;
    MockPendleRouter pendle;
    address[] actors;

    // Tracking for invariants
    uint256 public sumOfDeposits;
    uint256 public sumOfWithdrawals;
    uint256 public lastObservedIndex;
    mapping(address => uint256) public alreadyClaimed;
    address[] public jitActors;  // entered between openPosition and settle

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = _pickActor(actorSeed);
        amount = bound(amount, 100e6, 100_000e6);
        if (pv.maxDeposit(actor) < amount) return;
        deal(USDC, actor, amount);
        vm.prank(actor); USDC.approve(pv, amount);
        vm.prank(actor);
        try pv.deposit(amount, actor) returns (uint256) {
            sumOfDeposits += amount;
        } catch {}
    }

    function withdraw(uint256 actorSeed, uint256 sharesPct) external {
        address actor = _pickActor(actorSeed);
        uint256 shares = pv.balanceOf(actor) * bound(sharesPct, 0, 100) / 100;
        if (shares == 0) return;
        vm.prank(actor);
        try pv.redeem(shares, actor, actor) returns (uint256 a) {
            sumOfWithdrawals += a;
        } catch {}
    }

    function sweepYield() external {
        try yieldSweeper.sweep() {} catch {}
    }

    function injectMorphoYield(uint256 amount) external {
        amount = bound(amount, 0, 1e10);
        morpho.simulateYield(amount);
    }

    function openPosition(uint256 amount, uint256 expectedPayout) external {
        // simulate StrategyExecutor.runWeeklyCycle for one market
        // expectedPayout will be honored at close
    }

    function closePosition(uint256 idSeed, uint256 actualPayout) external {
        // simulate close — could differ from expected payout
    }

    function emergencyExit() external {
        vm.prank(guardian); se.emergencyExit(25);
    }

    function _pickActor(uint256 seed) internal returns (address) {
        return actors[seed % actors.length];
    }
}
```

Run with: `forge test --match-contract PrincipalIsolation --invariant-runs 50000 --invariant-depth 256`.

---

## Status Summary

| Test bucket | Files needed | Tests | Priority |
|---|---|---|---|
| P0 invariants | `test/invariant/*.t.sol` | 6 invariants × 1 handler | DAY 5 |
| P1 critical regression | `test/critical/*.t.sol` | 11 tests (one per finding) | DAY 5 |
| P2 medium regression | `test/medium/*.t.sol` | 8 tests | DAY 6 |
| P3 fork integration | `test/fork/*.t.sol` | 6 tests | DAY 6 |
| P4 access control | `test/access/*.t.sol` | ~20 tests | DAY 5 |
| P5 static analysis | CI config | 0 tests, just tooling | DAY 5 |
| P6 handler | `test/invariant/Handler.sol` | 1 file, ~300 LOC | DAY 5 |

**Total target:** ~52 tests + 1 handler before testnet deploy.
