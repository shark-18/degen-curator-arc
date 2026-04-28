// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IWiring} from "../interfaces/IWiring.sol";
import {IStrategyExecutor} from "../interfaces/IStrategyExecutor.sol";
import {IPendleRouterV4} from "../interfaces/IPendleRouterV4.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";
import {ILotteryTreasury} from "../interfaces/ILotteryTreasury.sol";
import {ICurator} from "../interfaces/ICurator.sol";

/// @title StrategyExecutor — Pendle Router V4 integration
/// @notice UUPS-upgradeable. Calls Pendle Router to enter/exit YT positions.
///         CRITICAL: this contract has zero compile-time references to
///         PrincipalVault. It cannot move principal even via re-entrancy.
///         All approvals are exact-amount + revoked post-swap.
///
///         IMPORTANT — DAY 3 BUILD: This is a SKELETON that documents the
///         intended call shape. Real implementation requires Pendle V4 SDK
///         integration on a Base fork (off-chain ApproxParams quote, real
///         market addresses). Do NOT deploy this skeleton to mainnet.
contract StrategyExecutor is
    IStrategyExecutor,
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    error NotGuardian();
    error MarketNotWhitelisted(address market);
    error EmergencyBatchTooLarge();
    error CycleNotReady();
    error MaxBasketSizeExceeded();

    /// @custom:storage-location erc7201:dcurator.storage.v1.StrategyExecutor
    struct SE {
        IWiring wiring;
        address pendleRouter;
        IERC20 usdc;
        uint16 slippageBps;
        uint16 maxBasketSize;
        uint64 cycleId;
        uint64 lastCycleTs;
        uint256[44] __gap;
    }

    bytes32 private constant SLOT =
        0xa1b1d6f74c9d5c8f3e2d4a8c5b7e9d3f1c2a4b6d8e0f2a4c6e8b0d2f4a6c8e00;

    function _s() private pure returns (SE storage s) {
        bytes32 slot = SLOT;
        assembly {
            s.slot := slot
        }
    }

    function initialize(
        IWiring _wiring,
        address _pendleRouter,
        IERC20 _usdc,
        address _admin,
        address _keeper,
        uint16 _slippageBps
    ) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _keeper);
        SE storage s = _s();
        s.wiring = _wiring;
        s.pendleRouter = _pendleRouter;
        s.usdc = _usdc;
        s.slippageBps = _slippageBps; // 300 = 3%
        s.maxBasketSize = 10;
    }

    /* ----------------------------- weekly cycle ------------------------------ */

    /// @notice Run weekly basket execution. Curator must have set basket
    ///         within whitelist; keeper triggers actual execution.
    ///
    /// IMPLEMENTATION NOTE (DAY 3): Build this against a Base fork. For each
    /// market in basket:
    ///   1. Compute per-position USDC budget: treasury_balance × allocation
    ///   2. Call LotteryTreasury.approveStrategyExecutor(amt) (one-shot)
    ///   3. Call IERC20(USDC).transferFrom(treasury, self, amt)
    ///   4. forceApprove(USDC, pendleRouter, amt)
    ///   5. Build TokenInput with tokenIn=USDC, tokenMintSy=USDC, swapData empty
    ///   6. Build ApproxParams from off-chain quote ±10%
    ///   7. minYtOut = quote × (1 - slippageBps/10000)
    ///   8. Call IPendleRouterV4(pendleRouter).swapExactTokenForYt(...)
    ///   9. forceApprove(USDC, pendleRouter, 0)
    ///  10. PositionManager.openPosition(market, ytReceived, usdcSpent, maturityTs)
    ///  11. LotteryTreasury.notifyPurchase(positionId, usdcSpent)
    function runWeeklyCycle() external onlyRole(KEEPER_ROLE) {
        SE storage s = _s();
        // Skeleton: real impl pulls basket from Curator, iterates, executes per-market.
        address[] memory basket = ICurator(s.wiring.curator()).getWeeklyBasket();
        if (basket.length == 0 || basket.length > s.maxBasketSize) revert MaxBasketSizeExceeded();
        uint64 cid = ++s.cycleId;
        s.lastCycleTs = uint64(block.timestamp);

        // Per-market execution loop (TO BE BUILT on Day 3 with Pendle V4 SDK)
        // for (uint256 i; i < basket.length; ++i) { _enterPosition(basket[i], ...); }

        emit RebalanceExecuted(cid, basket, new uint256[](basket.length), bytes(""));
    }

    /// @notice Close a YT position. Anyone may call (with bounty in v2).
    ///
    /// IMPLEMENTATION NOTE: Build the swapExactYtForToken or redeemPyToToken
    /// path on Day 3. Use TokenOutput with minTokenOut = minUsdcOut, deadline
    /// ≤ 5min, LimitOrderData empty.
    function closeYT(uint256 positionId, uint256 minUsdcOut) external {
        // Skeleton — real implementation:
        // 1. Read Position from PositionManager
        // 2. forceApprove(YT, pendleRouter, ytAmount)
        // 3. Call swapExactYtForToken with TokenOutput { tokenOut: USDC, minTokenOut: minUsdcOut, ... }
        // 4. Determine final state: CLOSED_EARLY if 5x trigger, CLOSED_NORMAL otherwise
        // 5. PositionManager.closePosition(id, usdcReceived, finalState)
        emit PositionExited(positionId, minUsdcOut);
    }

    /// @notice Guardian-only emergency exit, bounded loop.
    function emergencyExit(uint256 maxToProcess) external {
        SE storage s = _s();
        if (msg.sender != s.wiring.guardian()) revert NotGuardian();
        if (maxToProcess > 25) revert EmergencyBatchTooLarge();

        IPositionManager pm = IPositionManager(s.wiring.positionManager());
        uint256[] memory ids = pm.activeIds();
        uint256 n = ids.length < maxToProcess ? ids.length : maxToProcess;
        uint256 closed;
        for (uint256 i; i < n; ++i) {
            try this.closeYT(ids[i], 0) {
                ++closed;
            } catch {
                /* keep going */
            }
        }
        emit EmergencyExitTriggered(s.cycleId, msg.sender, closed);
    }

    function setSlippageBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(bps <= 1000, "slippage too high"); // 10% cap
        SE storage s = _s();
        emit SlippageBpsUpdated(s.slippageBps, bps);
        s.slippageBps = bps;
    }

    function slippageBps() external view returns (uint16) {
        return _s().slippageBps;
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
