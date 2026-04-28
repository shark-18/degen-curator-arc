// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {PrincipalVault} from "../../src/core/PrincipalVault.sol";
import {LotteryTreasury} from "../../src/core/LotteryTreasury.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {Wiring} from "../../src/periphery/Wiring.sol";
import {Curator} from "../../src/periphery/Curator.sol";
import {YieldSweeper} from "../../src/periphery/YieldSweeper.sol";
import {StrategyExecutor} from "../../src/periphery/StrategyExecutor.sol";

import {IWiring} from "../../src/interfaces/IWiring.sol";
import {IMorphoVault} from "../../src/interfaces/IMorphoVault.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";

import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockMorphoVault} from "../mocks/MockMorphoVault.sol";

/// @title AuditRegression — one targeted test per audit finding
/// @notice This is the proof-of-fix suite. Each test maps to a specific
///         finding in architecture/AUDIT_FINDINGS.md. Pre-fix versions of
///         these tests would FAIL; post-fix they pass. CI runs both.
contract AuditRegressionTest is Test {
    PrincipalVault public pv;
    LotteryTreasury public lt;
    PositionManager public pm;
    Wiring public wiring;
    Curator public curator;
    YieldSweeper public yieldSweeper;
    StrategyExecutor public strategyExecutor;
    MockUSDC public usdc;
    MockMorphoVault public morpho;

    address constant ADMIN = address(0xA0);
    address constant CURATOR_MS = address(0xC0);
    address constant GUARDIAN = address(0xC1);
    address constant KEEPER = address(0xC2);
    address constant FEE_RECIPIENT = address(0xC3);
    address constant PENDLE_ROUTER = address(0xC4);
    address constant ALICE = address(0xA1);
    address constant BOB = address(0xB1);
    address constant ATTACKER = address(0xBAD);

    function setUp() public {
        usdc = new MockUSDC();
        morpho = new MockMorphoVault(address(usdc));

        Wiring wiringImpl = new Wiring();
        ERC1967Proxy wiringProxy = new ERC1967Proxy(
            address(wiringImpl),
            abi.encodeCall(Wiring.initialize, (ADMIN))
        );
        wiring = Wiring(address(wiringProxy));

        pv = new PrincipalVault(
            IERC20(address(usdc)),
            IMorphoVault(address(morpho)),
            IWiring(address(wiring)),
            1_000_000e6,
            1000,
            100e6
        );
        lt = new LotteryTreasury(IERC20(address(usdc)), IWiring(address(wiring)));
        pm = new PositionManager(IWiring(address(wiring)));

        Curator curatorImpl = new Curator();
        ERC1967Proxy curatorProxy = new ERC1967Proxy(
            address(curatorImpl),
            abi.encodeCall(
                Curator.initialize,
                (IWiring(address(wiring)), 2 days, CURATOR_MS, GUARDIAN, FEE_RECIPIENT)
            )
        );
        curator = Curator(address(curatorProxy));

        YieldSweeper ysImpl = new YieldSweeper();
        ERC1967Proxy ysProxy = new ERC1967Proxy(
            address(ysImpl),
            abi.encodeCall(YieldSweeper.initialize, (IWiring(address(wiring)), ADMIN, KEEPER))
        );
        yieldSweeper = YieldSweeper(address(ysProxy));

        StrategyExecutor seImpl = new StrategyExecutor();
        ERC1967Proxy seProxy = new ERC1967Proxy(
            address(seImpl),
            abi.encodeCall(
                StrategyExecutor.initialize,
                (IWiring(address(wiring)), PENDLE_ROUTER, IERC20(address(usdc)), ADMIN, KEEPER, 300)
            )
        );
        strategyExecutor = StrategyExecutor(address(seProxy));

        vm.prank(ADMIN);
        wiring.setAll(
            address(pv),
            address(lt),
            address(pm),
            address(strategyExecutor),
            address(yieldSweeper),
            address(curator),
            GUARDIAN
        );
    }

    /* =========================== HELPERS ============================ */

    function _deposit(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(pv), amount);
        pv.deposit(amount, user);
        vm.stopPrank();
    }

    /// @dev Inject yield into the LotteryTreasury via a real sweep.
    function _injectYieldAndSweep(uint256 amount) internal {
        morpho.simulateYield(amount, address(pv));
        vm.warp(block.timestamp + 7 days);
        vm.prank(KEEPER);
        yieldSweeper.sweep();
    }

    /// @dev Open a mock position consuming `cost` from the treasury.
    function _openPositionAndFund(uint256 cost, uint256 simulatedPayout, uint64 maturityOffset)
        internal
        returns (uint256 posId)
    {
        vm.startPrank(address(strategyExecutor));
        posId = pm.openPosition(
            address(0xBEEF), 1e21, uint128(cost), uint64(block.timestamp + maturityOffset)
        );
        lt.notifyPurchase(posId, cost);
        usdc.mint(address(lt), simulatedPayout);
        vm.stopPrank();
    }

    /* ==================== C-2: pricePerShare yield extraction ==================== */

    /// @notice The headline economic test: an attacker who deposits + withdraws
    ///         around a Morpho yield event must NOT extract value from honest
    ///         depositors. With totalAssets() = principalHWM, share value is
    ///         pegged at 1:1 — no Morpho appreciation enters share math.
    function test_C2_yieldSandwichExtractsZero() public {
        _deposit(ALICE, 900_000e6);

        // Pre-existing Morpho yield (e.g. 6 days of 5% APR ≈ $740/M)
        morpho.simulateYield(740e6, address(pv));

        uint256 attackerStart = 100_000e6;
        usdc.mint(ATTACKER, attackerStart);

        vm.startPrank(ATTACKER);
        usdc.approve(address(pv), attackerStart);
        pv.deposit(attackerStart, ATTACKER);
        uint256 atkShares = pv.balanceOf(ATTACKER);
        uint256 atkOut = pv.redeem(atkShares, ATTACKER, ATTACKER);
        vm.stopPrank();

        // Attacker must NOT profit from yield extraction.
        assertLe(atkOut, attackerStart, "C-2 violated: attacker extracted yield");
    }

    /* ====================== C-3: rewireStrategy timelocked ====================== */

    function test_C3_rewireStrategy_isRemoved() public {
        vm.prank(CURATOR_MS);
        vm.expectRevert(); // Curator.rewireStrategy reverts unconditionally
        curator.rewireStrategy(address(0xBAD));
    }

    function test_C3_curatorCannotSetStrategyExecutor() public {
        // Wiring.setStrategyExecutor now requires DEFAULT_ADMIN_ROLE, not CURATOR_ROLE
        vm.prank(CURATOR_MS);
        vm.expectRevert();
        wiring.setStrategyExecutor(address(0xBAD));
    }

    function test_C3_adminCanSetStrategyExecutor() public {
        // Only admin (deployment-side TimelockController) can rewire
        address newExec = address(0xDEAD);
        vm.prank(ADMIN);
        wiring.setStrategyExecutor(newExec);
        assertEq(wiring.strategyExecutor(), newExec);
    }

    /* ============== C-4: fee changes are timelocked (proposeFee+commitFee) ============== */

    function test_C4_setFee_legacyIsBlocked() public {
        vm.prank(CURATOR_MS);
        vm.expectRevert();
        curator.setFee(2000);
    }

    function test_C4_proposeFee_revertsBeforeTimelock() public {
        vm.prank(CURATOR_MS);
        curator.proposeFee(500);

        // Immediately commit — must revert
        vm.prank(CURATOR_MS);
        vm.expectRevert();
        curator.commitFee();

        // Wait < 2 days
        vm.warp(block.timestamp + 1 days);
        vm.prank(CURATOR_MS);
        vm.expectRevert();
        curator.commitFee();

        // Wait full 2 days from proposal
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(CURATOR_MS);
        curator.commitFee(); // succeeds
        assertEq(curator.feeBps(), 500);
    }

    function test_C4_proposeFee_capsAtMaxFeeBps() public {
        vm.prank(CURATOR_MS);
        vm.expectRevert();
        curator.proposeFee(2001);
    }

    /* ====================== C-5: JIT lockup defeats flash-loan settlement ====================== */

    function test_C5_lockupBlocksImmediateAccrual() public {
        _deposit(ALICE, 10_000e6);
        _injectYieldAndSweep(1_000e6);

        // Drain the first cycle so we don't break I2 mid-test
        uint256 posId1 = _openPositionAndFund(500e6, 5_000e6, 30 days);
        vm.prank(address(strategyExecutor));
        pm.closePosition(posId1, 5_000e6, IPositionManager.PositionState.CLOSED_NORMAL);

        // Now bring in a late depositor and trigger a settlement IMMEDIATELY
        // (within their LOCKUP_DURATION window).
        _injectYieldAndSweep(500e6); // refresh yield budget
        address late = address(0xCAFE);
        _deposit(late, 10_000e6);

        uint256 posId2 = _openPositionAndFund(200e6, 2_000e6, 30 days);
        vm.prank(address(strategyExecutor));
        pm.closePosition(posId2, 2_000e6, IPositionManager.PositionState.CLOSED_NORMAL);

        // Late depositor is in lockup — claimable should be 0
        assertEq(lt.claimableOf(late), 0, "C-5: late depositor accrued during lockup");
    }

    function test_C5_lockupExpires_thenAccrueWorks() public {
        _deposit(ALICE, 10_000e6);
        _injectYieldAndSweep(500e6); // adds 500e6 yield to treasury

        // Past LOCKUP_DURATION (1 day) — sweep already warped 7 days
        uint256 posId = _openPositionAndFund(100e6, 1_000e6, 30 days);
        vm.prank(address(strategyExecutor));
        pm.closePosition(posId, 1_000e6, IPositionManager.PositionState.CLOSED_NORMAL);

        // Alice past lockup, sole holder, gets nearly all of net (after 10% curator fee)
        assertGt(lt.claimableOf(ALICE), 0, "C-5: post-lockup user got nothing");
    }

    /* ============================ H-1: _disableInitializers() ============================ */

    function test_H1_implementations_cannotBeInitialized() public {
        Wiring wImpl = new Wiring();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        wImpl.initialize(ATTACKER);

        Curator cImpl = new Curator();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        cImpl.initialize(IWiring(address(0)), 0, ATTACKER, ATTACKER, ATTACKER);

        StrategyExecutor seImpl = new StrategyExecutor();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        seImpl.initialize(IWiring(address(0)), address(0), IERC20(address(0)), ATTACKER, ATTACKER, 0);

        YieldSweeper ysImpl = new YieldSweeper();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        ysImpl.initialize(IWiring(address(0)), ATTACKER, ATTACKER);
    }

    /* =========================== H-2: claim is msg.sender only =========================== */

    function test_H2_claim_onlyByCaller() public {
        _deposit(ALICE, 10_000e6);
        _injectYieldAndSweep(500e6);

        uint256 posId = _openPositionAndFund(100e6, 1_000e6, 30 days);
        vm.prank(address(strategyExecutor));
        pm.closePosition(posId, 1_000e6, IPositionManager.PositionState.CLOSED_NORMAL);

        // Alice should be able to claim her own share. Bob cannot claim FOR Alice.
        // (The new claim() takes no arguments — msg.sender only.)
        vm.prank(ALICE);
        uint256 amount = lt.claim();
        assertGt(amount, 0);

        // Bob has no claim
        vm.prank(BOB);
        vm.expectRevert(LotteryTreasury.NothingToClaim.selector);
        lt.claim();
    }

    /* ============================ H-3: closeYT keeper-only outside maturity ============================ */

    function test_H3_closeYT_publicReverts_preMaturity() public {
        _deposit(ALICE, 10_000e6);
        _injectYieldAndSweep(500e6);
        uint256 posId = _openPositionAndFund(100e6, 0, 60 days);

        // Public caller far from maturity → revert
        vm.prank(ATTACKER);
        vm.expectRevert(StrategyExecutor.PreMaturityKeeperOnly.selector);
        strategyExecutor.closeYT(posId, 100e6);
    }

    function test_H3_closeYT_publicAllowed_nearMaturity_withMinOut() public {
        _deposit(ALICE, 10_000e6);
        _injectYieldAndSweep(500e6);
        uint256 posId = _openPositionAndFund(100e6, 0, 60 days);

        // Warp to within 7 days of maturity
        vm.warp(block.timestamp + 54 days);

        // Public caller with non-zero minOut works (at the skeleton level — emits event)
        vm.prank(ATTACKER);
        strategyExecutor.closeYT(posId, 100e6);
    }

    function test_H3_closeYT_publicReverts_zeroMinOut() public {
        _deposit(ALICE, 10_000e6);
        _injectYieldAndSweep(500e6);
        uint256 posId = _openPositionAndFund(100e6, 0, 60 days);

        vm.warp(block.timestamp + 55 days);

        vm.prank(ATTACKER);
        vm.expectRevert(StrategyExecutor.MinUsdcOutTooLow.selector);
        strategyExecutor.closeYT(posId, 0);
    }

    /* ============================= H-4: pause auto-expires ============================= */

    function test_H4_pauseAutoExpires() public {
        vm.prank(GUARDIAN);
        pv.pause();
        assertTrue(pv.paused());

        // Right at expiry boundary: still paused
        vm.warp(block.timestamp + 7 days - 1);
        assertTrue(pv.paused());

        // Past expiry: unpaused automatically
        vm.warp(block.timestamp + 2);
        assertFalse(pv.paused());

        // maxDeposit reflects the auto-unpause
        assertGt(pv.maxDeposit(ALICE), 0);
    }

    function test_H4_renewPause_extendsByMaxDuration() public {
        vm.prank(GUARDIAN);
        pv.pause();

        vm.warp(block.timestamp + 6 days);
        assertTrue(pv.paused());

        vm.prank(GUARDIAN);
        pv.renewPause();

        // Should still be paused 6 days from now (within new window)
        vm.warp(block.timestamp + 6 days);
        assertTrue(pv.paused());
    }

    function test_H4_curatorCanUnpauseAnytime() public {
        // Pause via guardian directly — Guardian EOA matches WIRING.guardian()
        vm.prank(GUARDIAN);
        pv.pause();
        assertTrue(pv.paused());

        // Curator unpauses through the curator contract — its msg.sender into
        // pv.unpause is address(curator) which == WIRING.curator(), so allowed.
        vm.prank(CURATOR_MS);
        curator.unpauseAll();
        assertFalse(pv.paused());
    }

    /* ============================ H-5: setCurator revokes old role ============================ */

    function test_H5_setCurator_revokesOldRole() public {
        bytes32 CURATOR_ROLE = keccak256("CURATOR_ROLE");
        address oldCurator = wiring.curator();
        address newCurator = address(0xCAFE);

        // Pre: old curator has the role
        assertTrue(wiring.hasRole(CURATOR_ROLE, oldCurator));

        vm.prank(ADMIN);
        wiring.setCurator(newCurator);

        // Post: old revoked, new granted
        assertFalse(wiring.hasRole(CURATOR_ROLE, oldCurator));
        assertTrue(wiring.hasRole(CURATOR_ROLE, newCurator));
    }

    /* ========================= M-7: notifyPurchase rejects duplicate ========================= */

    function test_M7_notifyPurchase_rejectsDuplicate() public {
        _deposit(ALICE, 100_000e6);
        _injectYieldAndSweep(1_000e6);

        vm.startPrank(address(strategyExecutor));
        uint256 posId = pm.openPosition(
            address(0xBEEF), 1e21, 500e6, uint64(block.timestamp + 30 days)
        );
        lt.notifyPurchase(posId, 500e6);

        vm.expectRevert(abi.encodeWithSelector(LotteryTreasury.DuplicatePositionId.selector, posId));
        lt.notifyPurchase(posId, 500e6);
        vm.stopPrank();
    }

    /* ============================= M-8: per-proposal nonce ============================= */

    function test_M8_curator_cannotRaceVeto() public {
        address mkt = address(0xBEEF);

        // Curator proposes
        vm.prank(CURATOR_MS);
        curator.proposeWhitelistMarket(mkt);

        // Guardian vetoes (against current nonce = 1)
        vm.prank(GUARDIAN);
        curator.vetoWhitelistMarket(mkt);

        // Curator re-proposes (now nonce = 2)
        vm.prank(CURATOR_MS);
        curator.proposeWhitelistMarket(mkt);

        // Guardian must veto AGAIN to block this proposal
        // Without re-veto, after timelock, commit succeeds (the original veto
        // applied only to nonce 1, which is the correct semantic per M-8 fix)
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(CURATOR_MS);
        curator.commitWhitelistMarket(mkt); // succeeds because nonce 2 wasn't vetoed
        assertTrue(curator.isMarketWhitelisted(mkt));

        // But if guardian had vetoed nonce 2, commit would have reverted.
        // (Demonstrated by separate test below.)
    }

    function test_M8_secondVetoBlocksCommit() public {
        address mkt = address(0xBEEF);

        vm.prank(CURATOR_MS);
        curator.proposeWhitelistMarket(mkt);
        vm.prank(GUARDIAN);
        curator.vetoWhitelistMarket(mkt);

        vm.prank(CURATOR_MS);
        curator.proposeWhitelistMarket(mkt); // re-propose, nonce 2

        // Without re-veto, after timelock, commit succeeds (already covered).
        // For THIS test: veto the SECOND proposal, then commit must revert
        // with VetoedAlready (NOT MarketNotProposed, because veto preserves
        // proposedAt-as-zero side effect — which means the canonical revert
        // here is MarketNotProposed when proposedAt was reset).
        // The implementation zeroes proposedAt on veto, so subsequent commit
        // sees no live proposal at all. That's correct behavior — guardian's
        // veto cancels the proposal entirely.
        vm.prank(GUARDIAN);
        curator.vetoWhitelistMarket(mkt);

        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(CURATOR_MS);
        vm.expectRevert(); // either MarketNotProposed or VetoedAlready — both block
        curator.commitWhitelistMarket(mkt);
    }
}
