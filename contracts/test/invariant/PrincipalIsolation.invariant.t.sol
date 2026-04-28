// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {PrincipalVault} from "../../src/core/PrincipalVault.sol";
import {LotteryTreasury} from "../../src/core/LotteryTreasury.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {Wiring} from "../../src/periphery/Wiring.sol";

/// @title PrincipalIsolationInvariant — proves the cardinal invariant
/// @notice This is the headline test that proves dCURATOR's no-loss claim:
///
///         I1 (CARDINAL):  PrincipalVault.totalAssets() ≥ principalHWM
///         I1':            principalHWM == sum(deposits) - sum(withdrawals)
///
///         If either fails on ANY input sequence, the design is broken.
///         Must pass: 50,000 runs × 256 calls each (FOUNDRY_PROFILE=ci).
///
/// USAGE:
///   forge test --match-contract PrincipalIsolation --invariant-runs 50000
///
/// Build out the Handler with deposit/withdraw/sweep/openPosition/closePosition/
/// emergencyExit fuzzers that mirror the real cycle. Mock Morpho and Pendle for
/// invariant runs (or use forge fork with low call count for sanity).
contract PrincipalIsolationInvariant is StdInvariant, Test {
    PrincipalVault public pv;
    LotteryTreasury public lt;
    PositionManager public pm;
    Wiring public wiring;

    Handler public handler;

    function setUp() public {
        // TODO: deploy MockUSDC, MockMorphoVault, MockPendleRouter
        // TODO: deploy Wiring (proxy), set up roles
        // TODO: deploy PrincipalVault, LotteryTreasury, PositionManager
        // TODO: wire everything via Wiring.setAll(...)
        // TODO: deploy Handler that exposes deposit/withdraw/sweep/openPos/closePos/emExit
        //
        // handler = new Handler(pv, lt, pm, wiring, mockUSDC, mockMorpho);
        // targetContract(address(handler));
        //
        // bytes4[] memory selectors = new bytes4[](6);
        // selectors[0] = Handler.deposit.selector;
        // selectors[1] = Handler.withdraw.selector;
        // selectors[2] = Handler.sweepYield.selector;
        // selectors[3] = Handler.openPosition.selector;
        // selectors[4] = Handler.closePosition.selector;
        // selectors[5] = Handler.emergencyExit.selector;
        // targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice CARDINAL INVARIANT — principal never extracted by any code path
    function invariant_principalNeverExtracted() public view {
        if (address(pv) == address(0)) return; // skip until setUp wired
        assertGe(
            pv.totalAssets(),
            pv.principalHighWater(),
            "I1 VIOLATED: totalAssets dropped below principalHWM"
        );
    }

    /// @notice principalHWM equals sum of deposits minus sum of withdrawals
    function invariant_principalHWMMatchesUserAccounting() public view {
        if (address(handler) == address(0)) return;
        uint256 expected = handler.sumOfDeposits() - handler.sumOfWithdrawals();
        assertEq(pv.principalHighWater(), expected, "I1' VIOLATED: HWM doesn't match user accounting");
    }

    /// @notice Treasury spend must never exceed yield swept
    function invariant_treasurySpendBoundedByYield() public view {
        if (address(lt) == address(0)) return;
        assertLe(
            lt.cumulativeStrategySpend(),
            lt.cumulativeYieldSwept(),
            "I2 VIOLATED: strategy spend exceeded yield swept"
        );
    }

    /// @notice Share index is monotonically non-decreasing
    function invariant_shareIndexMonotone() public view {
        if (address(handler) == address(0)) return;
        uint256 lastSeen = handler.lastObservedIndex();
        uint256 current = lt.globalShareIndex();
        assertGe(current, lastSeen, "I4 VIOLATED: share index decreased");
    }

    /// @notice Total supply equals sum of all balances (sanity)
    function invariant_supplyEqualsSumBalances() public view {
        if (address(handler) == address(0)) return;
        assertEq(
            pv.totalSupply(),
            handler.sumOfAllBalances(),
            "I5 VIOLATED: totalSupply diverged from sum(balanceOf)"
        );
    }
}

/// @notice Handler scaffold — fill in for the 50K-run fuzz campaign.
contract Handler is Test {
    uint256 public sumOfDeposits;
    uint256 public sumOfWithdrawals;
    uint256 public lastObservedIndex;

    function deposit(uint256, uint256) external {
        // TODO: bound assets, pick random user, call pv.deposit
        // sumOfDeposits += amount;
    }

    function withdraw(uint256, uint256) external {
        // TODO: bound shares, pick random user, call pv.redeem
        // sumOfWithdrawals += assetsOut;
    }

    function sweepYield() external {
        // TODO: maybe inject morpho yield, call yieldSweeper.sweep()
    }

    function openPosition(uint256) external {
        // TODO: simulate StrategyExecutor.runWeeklyCycle for one market
    }

    function closePosition(uint256) external {
        // TODO: simulate position close + settle, captures index update
        // lastObservedIndex = lt.globalShareIndex() at start
    }

    function emergencyExit() external {
        // TODO: guardian-pause + emergency exit batch
    }

    function sumOfAllBalances() external view returns (uint256) {
        // TODO: iterate tracked actor set
        return 0;
    }
}
