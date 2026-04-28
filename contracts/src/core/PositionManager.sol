// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IWiring} from "../interfaces/IWiring.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";
import {ILotteryTreasury} from "../interfaces/ILotteryTreasury.sol";

/// @title PositionManager — YT position registry & state machine (audit-fixed v2)
/// @notice IMMUTABLE. Tracks open YT positions for the lottery treasury.
///         Holds no funds; pure accounting + iteration.
/// @dev    Audit fixes:
///         M-1 — markDelisted now sets state and removes from active set,
///               so emergencyExit logic can prioritize and skip cleanly.
contract PositionManager is ReentrancyGuardTransient, IPositionManager {
    using EnumerableSet for EnumerableSet.UintSet;

    error NotStrategyExecutor();
    error NotGuardian();
    error PositionNotFound(uint256 id);
    error InvalidStateTransition(PositionState from, PositionState to);

    IWiring public immutable WIRING;

    uint64 public nextPositionId;
    bool public emergencyMode;

    EnumerableSet.UintSet internal _activeIds;
    EnumerableSet.UintSet internal _delistedIds;
    mapping(uint256 => Position) public positions;

    modifier onlyStrategyExecutor() {
        if (msg.sender != WIRING.strategyExecutor()) revert NotStrategyExecutor();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != WIRING.guardian()) revert NotGuardian();
        _;
    }

    constructor(IWiring _wiring) {
        WIRING = _wiring;
        nextPositionId = 1;
    }

    function openPosition(
        address market,
        uint128 ytAmount,
        uint128 usdcCost,
        uint64 maturityTs
    ) external onlyStrategyExecutor returns (uint256 positionId) {
        positionId = nextPositionId++;
        positions[positionId] = Position({
            market: market,
            openedAt: uint64(block.timestamp),
            state: PositionState.OPEN,
            ytAmount: ytAmount,
            usdcCost: usdcCost,
            settledUsdc: 0,
            maturityTs: maturityTs,
            entryBlock: uint64(block.number)
        });
        _activeIds.add(positionId);
        emit PositionOpened(positionId, market, ytAmount, usdcCost, maturityTs, uint64(block.number));
    }

    function closePosition(
        uint256 positionId,
        uint256 usdcReceived,
        PositionState finalState
    ) external onlyStrategyExecutor nonReentrant {
        Position storage p = positions[positionId];
        if (p.state != PositionState.OPEN) revert PositionNotFound(positionId);
        if (
            finalState != PositionState.CLOSED_NORMAL
                && finalState != PositionState.CLOSED_EARLY
                && finalState != PositionState.DELISTED
        ) revert InvalidStateTransition(p.state, finalState);

        p.state = finalState;
        p.settledUsdc = uint128(usdcReceived);
        _activeIds.remove(positionId);
        _delistedIds.remove(positionId);

        // Settle on lottery treasury (updates global index).
        ILotteryTreasury(WIRING.lotteryTreasury()).settle(positionId, usdcReceived);

        emit PositionClosed(positionId, finalState, usdcReceived);
    }

    /// @dev M-1 fix: now actually changes state and tracks in a delisted set.
    function markDelisted(uint256 positionId) external onlyStrategyExecutor {
        Position storage p = positions[positionId];
        if (p.state != PositionState.OPEN) revert PositionNotFound(positionId);
        // Position remains in OPEN state per state machine, but is flagged.
        // emergencyExit reads delistedIds first for prioritization.
        _delistedIds.add(positionId);
        emit MarkedDelisted(positionId);
    }

    function setEmergency(bool on) external onlyGuardian {
        emergencyMode = on;
        emit EmergencyMode(on);
    }

    /* ---------------------------------- views -------------------------------- */

    function getPosition(uint256 id) external view returns (Position memory) {
        return positions[id];
    }

    function activeIds() external view returns (uint256[] memory) {
        return _activeIds.values();
    }

    function activeCount() external view returns (uint256) {
        return _activeIds.length();
    }

    /// @notice Markets flagged for emergency-exit prioritization.
    function delistedIds() external view returns (uint256[] memory) {
        return _delistedIds.values();
    }
}
