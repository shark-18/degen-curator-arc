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

/// @title StrategyExecutor — Pendle Router V4 integration (audit-fixed v2)
/// @notice UUPS-upgradeable. Calls Pendle Router to enter/exit YT positions.
/// @dev    CRITICAL: this contract has zero compile-time references to
///         PrincipalVault. It cannot move principal even via re-entrancy.
///         All approvals are exact-amount + revoked post-swap.
///
///         Audit fixes:
///         C-1 — EIP-7201 slot recomputed canonically.
///         H-1 — Constructor disables initializers on impl.
///         H-3 — closeYT gated to KEEPER_ROLE during normal operation;
///               public-with-bounty path only allowed within 7 days of maturity.
///
///         IMPORTANT: This is a SKELETON. Real implementation requires
///         Pendle V4 SDK integration on a Base fork (off-chain ApproxParams
///         quote, real market addresses). DO NOT deploy as-is.
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
    error PreMaturityKeeperOnly();
    error MinUsdcOutTooLow();
    error InvalidSlippageBps();

    /// @notice Window before maturity in which `closeYT` becomes public-with-bounty.
    uint64 public constant PUBLIC_CLOSE_WINDOW = 7 days;

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

    /// @dev keccak256(abi.encode(uint256(keccak256("dcurator.storage.v1.StrategyExecutor")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SLOT =
        0xb7db1080576884bd91eb2cffb2a77b3c2a30d56a6820ab4b6321c96494eb5e00;

    function _s() private pure returns (SE storage s) {
        bytes32 slot = SLOT;
        assembly {
            s.slot := slot
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IWiring _wiring,
        address _pendleRouter,
        IERC20 _usdc,
        address _admin,
        address _keeper,
        uint16 _slippageBps
    ) external initializer {
        if (_slippageBps > 1000) revert InvalidSlippageBps();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _keeper);
        SE storage s = _s();
        s.wiring = _wiring;
        s.pendleRouter = _pendleRouter;
        s.usdc = _usdc;
        s.slippageBps = _slippageBps;
        s.maxBasketSize = 10;
    }

    /* ----------------------------- weekly cycle ------------------------------ */

    function runWeeklyCycle() external onlyRole(KEEPER_ROLE) {
        SE storage s = _s();
        address[] memory basket = ICurator(s.wiring.curator()).getWeeklyBasket();
        if (basket.length == 0 || basket.length > s.maxBasketSize) {
            revert MaxBasketSizeExceeded();
        }
        uint64 cid = ++s.cycleId;
        s.lastCycleTs = uint64(block.timestamp);

        // DAY 3 BUILD TARGET — for each market in basket:
        //   1. Validate against curator whitelist (defense-in-depth)
        //   2. Compute per-position USDC budget (equal-weight or model-driven)
        //   3. ILotteryTreasury(treasury).approveStrategyExecutor(amt)
        //   4. usdc.safeTransferFrom(treasury, this, amt)
        //   5. usdc.forceApprove(pendleRouter, amt)
        //   6. Build TokenInput { tokenIn=USDC, tokenMintSy=USDC, swapData=empty }
        //   7. Build ApproxParams from off-chain quote ±10%
        //   8. minYtOut = quote × (1 - slippageBps/10000)
        //   9. IPendleRouterV4.swapExactTokenForYt(...)
        //  10. usdc.forceApprove(pendleRouter, 0)
        //  11. PositionManager.openPosition(market, ytReceived, usdcSpent, maturityTs)
        //  12. LotteryTreasury.notifyPurchase(positionId, usdcSpent)

        emit RebalanceExecuted(cid, basket, new uint256[](basket.length), bytes(""));
    }

    /// @notice Close a YT position.
    /// @dev    H-3 fix: pre-maturity calls require KEEPER_ROLE; only within
    ///         7 days of maturity may anyone call (public-with-bounty path).
    ///         Public callers must still pass a non-zero `minUsdcOut`.
    function closeYT(uint256 positionId, uint256 minUsdcOut) external {
        SE storage s = _s();
        IPositionManager pm = IPositionManager(s.wiring.positionManager());
        IPositionManager.Position memory p = pm.getPosition(positionId);

        bool isKeeper = hasRole(KEEPER_ROLE, msg.sender);
        bool isGuardian = (msg.sender == s.wiring.guardian());

        if (!isKeeper && !isGuardian) {
            // Public path: only within PUBLIC_CLOSE_WINDOW of maturity.
            if (block.timestamp + PUBLIC_CLOSE_WINDOW < p.maturityTs) {
                revert PreMaturityKeeperOnly();
            }
            // Public callers must pass non-zero min-out (no slippage griefing).
            if (minUsdcOut == 0) revert MinUsdcOutTooLow();
        }

        // DAY 3 BUILD TARGET:
        //   1. forceApprove(YT_token, pendleRouter, ytAmount)
        //   2. Build TokenOutput { tokenOut=USDC, minTokenOut=minUsdcOut, ... }
        //   3. swapExactYtForToken(...) → usdcReceived
        //   4. forceApprove(YT_token, pendleRouter, 0)
        //   5. Determine finalState: CLOSED_EARLY if 5x trigger, CLOSED_NORMAL otherwise
        //   6. PositionManager.closePosition(positionId, usdcReceived, finalState)

        emit PositionExited(positionId, minUsdcOut);
    }

    function emergencyExit(uint256 maxToProcess) external {
        SE storage s = _s();
        if (msg.sender != s.wiring.guardian()) revert NotGuardian();
        if (maxToProcess > 25) revert EmergencyBatchTooLarge();

        IPositionManager pm = IPositionManager(s.wiring.positionManager());
        // Prioritize delisted markets first.
        uint256[] memory delistedIds = pm.delistedIds();
        uint256[] memory ids = pm.activeIds();
        uint256 totalLen = delistedIds.length + ids.length;
        uint256 n = totalLen < maxToProcess ? totalLen : maxToProcess;
        uint256 closed;

        // Pass 1: delisted (highest priority).
        for (uint256 i; i < delistedIds.length && closed < n; ++i) {
            try this.closeYT(delistedIds[i], 0) {
                ++closed;
            } catch {
                /* keep going */
            }
        }
        // Pass 2: remaining active.
        for (uint256 i; i < ids.length && closed < n; ++i) {
            try this.closeYT(ids[i], 0) {
                ++closed;
            } catch {
                /* keep going */
            }
        }

        emit EmergencyExitTriggered(s.cycleId, msg.sender, closed);
    }

    function setSlippageBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 1000) revert InvalidSlippageBps();
        SE storage s = _s();
        emit SlippageBpsUpdated(s.slippageBps, bps);
        s.slippageBps = bps;
    }

    function slippageBps() external view returns (uint16) {
        return _s().slippageBps;
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
