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

/// @title LotteryTreasury — yield-only convex lottery pool (audit-fixed v2)
/// @notice Holds USDC swept from PrincipalVault yield. Funds Pendle YT
///         purchases via StrategyExecutor (allowance-scoped). Receives YT
///         settlement proceeds and distributes pro-rata to dCURATOR holders
///         via a sushibar-style global share index — with a deposit lockup
///         that defeats JIT flash-loan extraction.
/// @dev    IMMUTABLE.
///
///         Audit fixes:
///         C-5 — Deposit lockup (LOCKUP_DURATION = 1 day) before lottery
///               accrual starts. Defeats xSUSHI / flash-loan JIT settlement
///               extraction. v2 will replace with full position-attribution.
///         H-2 — claim() takes no argument; only msg.sender can withdraw their
///               own claimable balance. No more force-claim grief vector.
///         M-4 — nonReentrant on creditYield/notifyPurchase/approveStrategyExecutor.
///         M-7 — notifyPurchase rejects duplicate positionId.
///         I-3 — settle requires positionCostBasis > 0 (was registered).
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
    error DuplicatePositionId(uint256 positionId);
    error PositionNotRegistered(uint256 positionId);
    error InvariantBroken_I2();

    /* -------------------------------- constants ------------------------------- */

    uint256 private constant INDEX_PRECISION = 1e30;

    /// @notice Lockup before lottery accrual starts. Defeats flash-loan JIT.
    uint64 public constant LOCKUP_DURATION = 1 days;

    /* -------------------------------- immutables ------------------------------ */

    IERC20 public immutable USDC;
    IWiring public immutable WIRING;

    /* --------------------------------- storage -------------------------------- */

    uint128 public totalUnsettled;
    uint128 public totalSettled;

    uint256 public globalShareIndex;

    uint256 public cumulativeYieldSwept;
    uint256 public cumulativeStrategySpend;

    /// @notice Per-user index checkpoint (sushibar pattern).
    mapping(address => uint256) public userIndexCheckpoint;
    /// @notice Per-user pending USDC owed.
    mapping(address => uint256) public userClaimable;
    /// @notice C-5: monotone-set on first transition zero→positive balance.
    ///         Cleared on transition positive→zero. Lockup = now - thisTs.
    mapping(address => uint64) public userFirstHoldTimestamp;

    /// @notice Idempotency on settle.
    mapping(uint256 => bool) public positionSettled;
    /// @notice Cost basis recorded by notifyPurchase. M-7: must not overwrite.
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

    /// @dev Called by PrincipalVault.sweepYield() right after transferring
    ///      USDC into this contract. The PrincipalVault gate is itself
    ///      protected by onlyYieldSweeper, so this is end-to-end-trusted.
    function creditYield(uint256 amount) external nonReentrant onlyPrincipalVault {
        cumulativeYieldSwept += amount;
        emit YieldCredited(amount, cumulativeYieldSwept);
    }

    /* ----------------------------- strategy hooks ---------------------------- */

    function notifyPurchase(uint256 positionId, uint256 usdcSpent)
        external
        nonReentrant
        onlyStrategyExecutor
    {
        // M-7: prevent overwrite of existing cost basis.
        if (positionCostBasis[positionId] != 0) revert DuplicatePositionId(positionId);

        cumulativeStrategySpend += usdcSpent;
        if (cumulativeStrategySpend > cumulativeYieldSwept) revert InvariantBroken_I2();

        positionCostBasis[positionId] = usdcSpent;
        totalUnsettled += uint128(usdcSpent);
        emit PurchaseNotified(positionId, usdcSpent);
    }

    function settle(uint256 positionId, uint256 usdcReceived)
        external
        nonReentrant
        onlyPositionManager
    {
        if (positionSettled[positionId]) revert AlreadySettled(positionId);
        positionSettled[positionId] = true;

        uint256 cost = positionCostBasis[positionId];
        // I-3: must have been registered via notifyPurchase.
        if (cost == 0) revert PositionNotRegistered(positionId);

        totalUnsettled = uint128(uint256(totalUnsettled) - cost);
        totalSettled += uint128(usdcReceived);

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
        uint256 totalShares = IERC20(WIRING.principalVault()).totalSupply();
        if (totalShares > 0 && net > 0) {
            uint256 delta = (net * INDEX_PRECISION) / totalShares;
            globalShareIndex += delta;
        }
        // If totalShares == 0, the net stays in this contract's USDC balance,
        // available for next settlement's index update.

        emit Settled(positionId, usdcReceived, fee, globalShareIndex);
    }

    /* ----------------------------- accrual / claim ---------------------------- */

    function accrueOnBalanceChange(address user) external onlyPrincipalVault {
        _accrue(user);
    }

    function onPositiveBalance(address user) external onlyPrincipalVault {
        if (userFirstHoldTimestamp[user] == 0) {
            userFirstHoldTimestamp[user] = uint64(block.timestamp);
            // Sync checkpoint to current index so pre-lockup growth doesn't accrue.
            userIndexCheckpoint[user] = globalShareIndex;
            emit UserLockupStarted(user, uint64(block.timestamp));
        }
    }

    function onZeroBalance(address user) external onlyPrincipalVault {
        userFirstHoldTimestamp[user] = 0;
        userIndexCheckpoint[user] = globalShareIndex;
        emit UserLockupReset(user);
        // Note: any past-lockup userClaimable is preserved across the cycle.
    }

    function _accrue(address user) internal {
        uint64 firstHold = userFirstHoldTimestamp[user];

        // No firstHold yet (never held a positive balance, or post-zero).
        if (firstHold == 0) {
            userIndexCheckpoint[user] = globalShareIndex;
            return;
        }

        // Still in lockup window: skip accrual, sync checkpoint forward.
        if (block.timestamp < firstHold + LOCKUP_DURATION) {
            userIndexCheckpoint[user] = globalShareIndex;
            return;
        }

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

    /// @notice H-2 fix: msg.sender claims their own. No force-claim possible.
    function claim() external nonReentrant returns (uint256 amount) {
        _accrue(msg.sender);
        amount = userClaimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        userClaimable[msg.sender] = 0;
        USDC.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    function claimableOf(address user) external view returns (uint256) {
        uint64 firstHold = userFirstHoldTimestamp[user];
        if (firstHold == 0) return userClaimable[user];
        if (block.timestamp < firstHold + LOCKUP_DURATION) return userClaimable[user];

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
    function approveStrategyExecutor(uint256 amount) external nonReentrant onlyStrategyExecutor {
        IERC20(USDC).forceApprove(msg.sender, amount);
    }
}
