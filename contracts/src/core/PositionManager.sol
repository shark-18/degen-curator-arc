// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IWiring} from "../interfaces/IWiring.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";
import {ILotteryTreasury} from "../interfaces/ILotteryTreasury.sol";

/// @title PositionManager — YT position registry & state machine
/// @notice IMMUTABLE. Tracks open YT positions for the lottery treasury.
///         Holds no funds; pure accounting + iteration.
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

        // Trigger settlement on lottery treasury (updates global index)
        ILotteryTreasury(WIRING.lotteryTreasury()).settle(positionId, usdcReceived);

        emit PositionClosed(positionId, finalState, usdcReceived);
    }

    function markDelisted(uint256 positionId) external onlyStrategyExecutor {
        Position storage p = positions[positionId];
        if (p.state != PositionState.OPEN) revert PositionNotFound(positionId);
        // Don't remove from active set — that happens on closePosition. This
        // just flags the market for emergencyExit prioritization.
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
}
