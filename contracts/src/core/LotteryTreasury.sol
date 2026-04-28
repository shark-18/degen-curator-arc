// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IWiring} from "../interfaces/IWiring.sol";
import {ILotteryTreasury} from "../interfaces/ILotteryTreasury.sol";
import {ICurator} from "../interfaces/ICurator.sol";
import {IPrincipalVault} from "../interfaces/IPrincipalVault.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";

/// @title LotteryTreasury — yield-only convex lottery pool
/// @notice Holds USDC swept from PrincipalVault yield. Funds Pendle YT
///         purchases via StrategyExecutor (allowance-scoped). Receives YT
///         settlement proceeds and distributes pro-rata to dCURATOR holders
///         via a sushibar-style global share index.
/// @dev    IMMUTABLE.
///
///         INVARIANT (I2): cumulativeStrategySpend ≤ cumulativeYieldSwept
///         INVARIANT (I4): globalShareIndex strictly non-decreasing
///
///         The share-index pattern (1e30 precision):
///           on settle(payout):
///             profit = max(0, payout - costBasis)
///             fee    = profit * feeBps / 10_000
///             net    = payout - fee
///             delta  = (net * 1e30) / dCURATOR.totalSupply()  (floor)
///             globalShareIndex += delta
///           on user balance change (mint/burn/transfer):
///             owed = balance * (globalShareIndex - userIndexCheckpoint) / 1e30
///             userClaimable += owed
///             userIndexCheckpoint = globalShareIndex
contract LotteryTreasury is ReentrancyGuardTransient, ILotteryTreasury {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /* --------------------------------- errors --------------------------------- */

    error NotYieldSweeper();
    error NotStrategyExecutor();
    error NotPositionManager();
    error NotPrincipalVault();
    error NothingToClaim();
    error AlreadySettled(uint256 positionId);

    /* -------------------------------- immutables ------------------------------ */

    IERC20 public immutable USDC;
    IWiring public immutable WIRING;

    /// @notice Sushibar index precision
    uint256 private constant INDEX_PRECISION = 1e30;

    /* --------------------------------- storage -------------------------------- */

    // Slot 0 (packed)
    uint128 public totalUnsettled; // USDC equivalent in flight in YT positions
    uint128 public totalSettled;   // cumulative settled winnings (gross)

    // Slot 1
    uint256 public globalShareIndex;

    // Cumulative tracking for I2 invariant
    uint256 public cumulativeYieldSwept;
    uint256 public cumulativeStrategySpend;

    // Per-user state
    mapping(address => uint256) public userIndexCheckpoint;
    mapping(address => uint256) public userClaimable;

    // Per-position settlement (idempotency)
    mapping(uint256 => bool) public positionSettled;
    mapping(uint256 => uint256) public positionCostBasis;

    /* ------------------------------- modifiers ------------------------------- */

    modifier onlyYieldSweeper() {
        if (msg.sender != WIRING.yieldSweeper()) revert NotYieldSweeper();
        _;
    }

    modifier onlyStrategyExecutor() {
        if (msg.sender != WIRING.strategyExecutor()) revert NotStrategyExecutor();
        _;
    }

    modifier onlyPositionManager() {
        if (msg.sender != WIRING.positionManager()) revert NotPositionManager();
        _;
    }

    modifier onlyPrincipalVault() {
        if (msg.sender != WIRING.principalVault()) revert NotPrincipalVault();
        _;
    }

    /* ------------------------------ constructor ------------------------------ */

    constructor(IERC20 _usdc, IWiring _wiring) {
        USDC = _usdc;
        WIRING = _wiring;
    }

    /* ------------------------------ yield ingress ----------------------------- */

    /// @notice Called by YieldSweeper after USDC has been transferred in.
    function creditYield(uint256 amount) external onlyYieldSweeper {
        cumulativeYieldSwept += amount;
        emit YieldCredited(amount, cumulativeYieldSwept);
    }

    /* ----------------------------- strategy hooks ---------------------------- */

    /// @notice Called by StrategyExecutor after a YT purchase. Records cost
    ///         basis and increments unsettled tally.
    /// @dev    Checked: cumulative spend ≤ cumulative yield swept (I2).
    function notifyPurchase(uint256 positionId, uint256 usdcSpent) external onlyStrategyExecutor {
        cumulativeStrategySpend += usdcSpent;
        // I2 invariant check (defense-in-depth; primary enforcement is by
        // StrategyExecutor not over-spending vs. our balance, but we double
        // check here):
        require(cumulativeStrategySpend <= cumulativeYieldSwept, "I2 violated");

        positionCostBasis[positionId] = usdcSpent;
        totalUnsettled += uint128(usdcSpent);
        emit PurchaseNotified(positionId, usdcSpent);
    }

    /// @notice Called by PositionManager after a YT close. Updates global index
    ///         pro-rata to dCURATOR totalSupply at this moment.
    function settle(uint256 positionId, uint256 usdcReceived) external onlyPositionManager nonReentrant {
        if (positionSettled[positionId]) revert AlreadySettled(positionId);
        positionSettled[positionId] = true;

        uint256 cost = positionCostBasis[positionId];

        // Decrement the unsettled tally by the original cost basis (not the
        // received amount — even on losses).
        totalUnsettled = uint128(uint256(totalUnsettled) - cost);
        totalSettled += uint128(usdcReceived);

        // Curator fee on profit only
        uint256 fee;
        if (usdcReceived > cost) {
            uint256 profit;
            unchecked {
                profit = usdcReceived - cost;
            }
            uint16 feeBps = ICurator(WIRING.curator()).feeBps();
            fee = (profit * feeBps) / 10_000;
            if (fee > 0) {
                USDC.safeTransfer(ICurator(WIRING.curator()).feeRecipient(), fee);
            }
        }

        uint256 net = usdcReceived - fee;

        // Index update: floor div, dust stays in treasury for next settlement
        uint256 totalShares = IERC20(WIRING.principalVault()).totalSupply();
        if (totalShares > 0 && net > 0) {
            uint256 delta = (net * INDEX_PRECISION) / totalShares;
            globalShareIndex += delta;
        }

        emit Settled(positionId, usdcReceived, fee, globalShareIndex);
    }

    /* ----------------------------- accrual / claim ---------------------------- */

    /// @notice Called by PrincipalVault on every dCURATOR balance change.
    ///         Snapshots user's claimable USDC at the current global index.
    function accrueOnBalanceChange(address user) external onlyPrincipalVault {
        _accrue(user);
    }

    function _accrue(address user) internal {
        uint256 currentIdx = globalShareIndex;
        uint256 lastIdx = userIndexCheckpoint[user];
        if (currentIdx == lastIdx) return;

        uint256 balance = IERC20(WIRING.principalVault()).balanceOf(user);
        if (balance > 0) {
            uint256 owed;
            unchecked {
                owed = (balance * (currentIdx - lastIdx)) / INDEX_PRECISION;
            }
            userClaimable[user] += owed;
            emit UserAccrued(user, owed, currentIdx);
        }
        userIndexCheckpoint[user] = currentIdx;
    }

    function claim(address user) external nonReentrant returns (uint256 amount) {
        _accrue(user);
        amount = userClaimable[user];
        if (amount == 0) revert NothingToClaim();
        userClaimable[user] = 0;
        USDC.safeTransfer(user, amount);
        emit Claimed(user, amount);
    }

    function claimableOf(address user) external view returns (uint256) {
        uint256 currentIdx = globalShareIndex;
        uint256 lastIdx = userIndexCheckpoint[user];
        uint256 balance = IERC20(WIRING.principalVault()).balanceOf(user);
        uint256 pending;
        if (currentIdx > lastIdx && balance > 0) {
            pending = (balance * (currentIdx - lastIdx)) / INDEX_PRECISION;
        }
        return userClaimable[user] + pending;
    }

    function totalAssetsAtRisk() external view returns (uint256) {
        return totalUnsettled;
    }

    /* ------------------------------- approvals ------------------------------- */

    /// @notice One-shot exact approval to StrategyExecutor for a single swap.
    /// @dev    Called by StrategyExecutor immediately before the Pendle swap;
    ///         the executor revokes (forceApprove(0)) immediately after.
    function approveStrategyExecutor(uint256 amount) external onlyStrategyExecutor {
        // SafeERC20.forceApprove handles USDC's non-zero-to-non-zero quirk
        IERC20(USDC).forceApprove(msg.sender, amount);
    }
}
