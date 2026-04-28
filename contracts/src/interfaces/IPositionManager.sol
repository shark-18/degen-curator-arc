// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface IPositionManager {
    enum PositionState {
        NONE,
        OPEN,
        CLOSED_NORMAL, // closed at maturity or T-7d trigger
        CLOSED_EARLY, // 5x trigger
        DELISTED // Pendle market delisted/sanctioned
    }

    struct Position {
        address market;
        uint64 openedAt;
        PositionState state;
        uint128 ytAmount;
        uint128 usdcCost;
        uint128 settledUsdc;
        uint64 maturityTs;
        uint64 entryBlock; // for position-attribution (xSUSHI mitigation)
    }

    event PositionOpened(
        uint256 indexed positionId,
        address indexed market,
        uint128 ytAmount,
        uint128 usdcCost,
        uint64 maturityTs,
        uint64 entryBlock
    );
    event PositionClosed(uint256 indexed positionId, PositionState state, uint256 usdcReceived);
    event MarkedDelisted(uint256 indexed positionId);
    event EmergencyMode(bool on);

    function openPosition(
        address market,
        uint128 ytAmount,
        uint128 usdcCost,
        uint64 maturityTs
    ) external returns (uint256 positionId);

    function closePosition(uint256 positionId, uint256 usdcReceived, PositionState finalState) external;
    function markDelisted(uint256 positionId) external;

    function getPosition(uint256 id) external view returns (Position memory);
    function activeIds() external view returns (uint256[] memory);
    function activeCount() external view returns (uint256);

    function setEmergency(bool on) external;
    function emergencyMode() external view returns (bool);
}
