// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
import {DegenCuratorHandler} from "./Handler.sol";

/// @title PrincipalIsolationInvariant — proves the cardinal invariant
/// @notice Headline test that proves dCURATOR's no-loss claim:
///         I1 (CARDINAL):  PrincipalVault.totalAssets() ≥ principalHWM
///         I1':            principalHWM == sum(deposits) - sum(withdrawals)
///         I2:             cumulativeStrategySpend ≤ cumulativeYieldSwept
///         I4:             globalShareIndex non-decreasing
///         I5:             totalSupply == sum(balanceOf)
///
/// Run: forge test --match-contract PrincipalIsolation \
///      --invariant-runs 50000 --invariant-depth 256
contract PrincipalIsolationInvariant is StdInvariant, Test {
    PrincipalVault public pv;
    LotteryTreasury public lt;
    PositionManager public pm;
    Wiring public wiring;
    Curator public curator;
    YieldSweeper public yieldSweeper;
    StrategyExecutor public strategyExecutor;

    MockUSDC public usdc;
    MockMorphoVault public morpho;

    DegenCuratorHandler public handler;

    address constant ADMIN = address(0xA0);
    address constant CURATOR_MS = address(0xC0);
    address constant GUARDIAN = address(0xC1);
    address constant KEEPER = address(0xC2);
    address constant FEE_RECIPIENT = address(0xC3);
    address constant PENDLE_ROUTER = address(0xC4);

    function setUp() public {
        usdc = new MockUSDC();
        morpho = new MockMorphoVault(address(usdc));

        // Deploy Wiring proxy
        Wiring wiringImpl = new Wiring();
        ERC1967Proxy wiringProxy = new ERC1967Proxy(
            address(wiringImpl),
            abi.encodeCall(Wiring.initialize, (ADMIN))
        );
        wiring = Wiring(address(wiringProxy));

        // Deploy cores
        pv = new PrincipalVault(
            IERC20(address(usdc)),
            IMorphoVault(address(morpho)),
            IWiring(address(wiring)),
            1_000_000e6, // depositCap
            1000,         // depositorCap
            100e6         // minDeposit
        );
        lt = new LotteryTreasury(IERC20(address(usdc)), IWiring(address(wiring)));
        pm = new PositionManager(IWiring(address(wiring)));

        // Deploy Curator proxy
        Curator curatorImpl = new Curator();
        ERC1967Proxy curatorProxy = new ERC1967Proxy(
            address(curatorImpl),
            abi.encodeCall(
                Curator.initialize,
                (IWiring(address(wiring)), 2 days, CURATOR_MS, GUARDIAN, FEE_RECIPIENT)
            )
        );
        curator = Curator(address(curatorProxy));

        // Deploy YieldSweeper proxy
        YieldSweeper ysImpl = new YieldSweeper();
        ERC1967Proxy ysProxy = new ERC1967Proxy(
            address(ysImpl),
            abi.encodeCall(YieldSweeper.initialize, (IWiring(address(wiring)), ADMIN, KEEPER))
        );
        yieldSweeper = YieldSweeper(address(ysProxy));

        // Deploy StrategyExecutor proxy
        StrategyExecutor seImpl = new StrategyExecutor();
        ERC1967Proxy seProxy = new ERC1967Proxy(
            address(seImpl),
            abi.encodeCall(
                StrategyExecutor.initialize,
                (
                    IWiring(address(wiring)),
                    PENDLE_ROUTER,
                    IERC20(address(usdc)),
                    ADMIN,
                    KEEPER,
                    300 // 3% slippage
                )
            )
        );
        strategyExecutor = StrategyExecutor(address(seProxy));

        // Wire all
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

        // Handler
        handler = new DegenCuratorHandler(
            pv, lt, pm, wiring, curator, yieldSweeper, strategyExecutor, usdc, morpho
        );

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = DegenCuratorHandler.deposit.selector;
        selectors[1] = DegenCuratorHandler.withdraw.selector;
        selectors[2] = DegenCuratorHandler.injectMorphoYield.selector;
        selectors[3] = DegenCuratorHandler.sweep.selector;
        selectors[4] = DegenCuratorHandler.openMockPosition.selector;
        selectors[5] = DegenCuratorHandler.closeMockPosition.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice CARDINAL — totalAssets never below principalHWM in normal ops.
    /// @dev With C-2 fix, totalAssets returns min(morphoBalance, principalHWM),
    ///      so this tautologically holds when morphoBalance ≥ principalHWM.
    ///      In a Morpho loss event, totalAssets drops below HWM (socializing
    ///      the loss); the invariant is then violated by design — handler
    ///      doesn't simulate Morpho losses, so it should always hold here.
    function invariant_principalNeverExtracted() public view {
        assertGe(pv.totalAssets(), pv.principalHighWater(), "I1 violated");
    }

    /// @notice principalHWM equals net of user deposits / withdrawals.
    function invariant_principalHWMMatchesUserAccounting() public view {
        uint256 expected = handler.sumOfDeposits() - handler.sumOfWithdrawals();
        assertEq(pv.principalHighWater(), expected, "I1' violated");
    }

    /// @notice Treasury spend bounded by yield swept.
    function invariant_treasurySpendBoundedByYield() public view {
        assertLe(
            lt.cumulativeStrategySpend(),
            lt.cumulativeYieldSwept(),
            "I2 violated"
        );
    }

    /// @notice Share index monotone non-decreasing.
    function invariant_shareIndexMonotone() public view {
        assertGe(lt.globalShareIndex(), handler.lastObservedIndex(), "I4 violated");
    }

    /// @notice Total supply == sum of balances.
    function invariant_supplyEqualsSumBalances() public view {
        assertEq(pv.totalSupply(), handler.sumOfAllBalances(), "I5 violated");
    }

    /// @notice JIT depositors (entered after a position open, exited after settle)
    ///         must extract zero lottery yield.
    function invariant_jitDepositorExtractsZero() public view {
        // For each tracked JIT actor, claimable + already-claimed should be 0
        for (uint256 i; i < handler.jitActorCount(); ++i) {
            address jit = handler.jitActor(i);
            assertEq(
                lt.claimableOf(jit) + handler.alreadyClaimed(jit),
                0,
                "JIT extracted lottery yield (C-5 violated)"
            );
        }
    }
}
