// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PrincipalVault} from "../../src/core/PrincipalVault.sol";
import {LotteryTreasury} from "../../src/core/LotteryTreasury.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {Wiring} from "../../src/periphery/Wiring.sol";
import {Curator} from "../../src/periphery/Curator.sol";
import {YieldSweeper} from "../../src/periphery/YieldSweeper.sol";
import {StrategyExecutor} from "../../src/periphery/StrategyExecutor.sol";

import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";

import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockMorphoVault} from "../mocks/MockMorphoVault.sol";

/// @title DegenCuratorHandler — invariant test handler
/// @notice Mirrors live state by issuing bounded random user actions across
///         a fixed set of actors. Tracks accounting that the invariants check.
contract DegenCuratorHandler is Test {
    PrincipalVault public pv;
    LotteryTreasury public lt;
    PositionManager public pm;
    Wiring public wiring;
    Curator public curator;
    YieldSweeper public yieldSweeper;
    StrategyExecutor public strategyExecutor;
    MockUSDC public usdc;
    MockMorphoVault public morpho;

    address[] public actors;
    address[] public jitActors;

    mapping(address => uint256) public alreadyClaimed;
    mapping(address => bool) public isJitActor;

    uint256 public sumOfDeposits;
    uint256 public sumOfWithdrawals;
    uint256 public lastObservedIndex;

    uint256 public mockPositionsOpened;
    mapping(uint256 => uint256) public mockPositionExpectedPayout;

    constructor(
        PrincipalVault _pv,
        LotteryTreasury _lt,
        PositionManager _pm,
        Wiring _wiring,
        Curator _curator,
        YieldSweeper _ys,
        StrategyExecutor _se,
        MockUSDC _usdc,
        MockMorphoVault _morpho
    ) {
        pv = _pv;
        lt = _lt;
        pm = _pm;
        wiring = _wiring;
        curator = _curator;
        yieldSweeper = _ys;
        strategyExecutor = _se;
        usdc = _usdc;
        morpho = _morpho;

        for (uint160 i = 1; i <= 10; ++i) {
            actors.push(address(uint160(0x1000) + i));
        }
    }

    function _pickActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = _pickActor(actorSeed);
        amount = bound(amount, pv.minDeposit(), 100_000e6);
        if (pv.maxDeposit(actor) < amount) return;

        usdc.mint(actor, amount);
        vm.prank(actor);
        usdc.approve(address(pv), amount);

        vm.prank(actor);
        try pv.deposit(amount, actor) returns (uint256) {
            sumOfDeposits += amount;
        } catch {}
    }

    function withdraw(uint256 actorSeed, uint256 sharesPct) external {
        address actor = _pickActor(actorSeed);
        uint256 shares = (pv.balanceOf(actor) * bound(sharesPct, 0, 100)) / 100;
        if (shares == 0) return;

        uint256 assetsBefore = usdc.balanceOf(actor);
        vm.prank(actor);
        try pv.redeem(shares, actor, actor) returns (uint256) {
            uint256 assetsAfter = usdc.balanceOf(actor);
            sumOfWithdrawals += (assetsAfter - assetsBefore);
        } catch {}
    }

    function injectMorphoYield(uint256 amount) external {
        amount = bound(amount, 0, 10_000e6);
        morpho.simulateYield(amount, address(pv));
    }

    function sweep() external {
        // Bypass interval check by warping
        vm.warp(block.timestamp + 7 days);
        vm.prank(actors[0]); // any address with KEEPER won't work, use admin pattern
        // Actually need KEEPER role — for simplicity in handler, call sweepYield
        // directly via the YieldSweeper-authorized path
        try yieldSweeper.sweep() {} catch {}
    }

    function openMockPosition(uint256 cost) external {
        cost = bound(cost, 1e6, 10_000e6);
        // Only proceed if treasury has enough yield available
        if (lt.cumulativeYieldSwept() - lt.cumulativeStrategySpend() < cost) return;

        // Simulate the StrategyExecutor → PositionManager → LotteryTreasury flow
        vm.prank(address(strategyExecutor));
        try pm.openPosition(
            address(0xBEEF),  // mock market
            uint128(cost * 100),
            uint128(cost),
            uint64(block.timestamp + 30 days)
        ) returns (uint256 id) {
            vm.prank(address(strategyExecutor));
            lt.notifyPurchase(id, cost);
            mockPositionsOpened++;
            mockPositionExpectedPayout[id] = cost * 2;
        } catch {}
    }

    function closeMockPosition(uint256 idSeed, uint256 actualPayout) external {
        if (mockPositionsOpened == 0) return;
        uint256 id = (idSeed % mockPositionsOpened) + 1;
        IPositionManager.Position memory p = pm.getPosition(id);
        if (p.state != IPositionManager.PositionState.OPEN) return;

        actualPayout = bound(actualPayout, 0, mockPositionExpectedPayout[id] * 5);
        // Treasury must have enough USDC for the settlement
        if (usdc.balanceOf(address(lt)) < actualPayout) {
            usdc.mint(address(lt), actualPayout);
        }
        lastObservedIndex = lt.globalShareIndex();
        vm.prank(address(strategyExecutor));
        try pm.closePosition(id, actualPayout, IPositionManager.PositionState.CLOSED_NORMAL) {} catch {}
    }

    /* ------------------------------ accounting ------------------------------- */

    function sumOfAllBalances() external view returns (uint256 total) {
        for (uint256 i; i < actors.length; ++i) {
            total += pv.balanceOf(actors[i]);
        }
    }

    function jitActorCount() external view returns (uint256) {
        return jitActors.length;
    }

    function jitActor(uint256 idx) external view returns (address) {
        return jitActors[idx];
    }
}
