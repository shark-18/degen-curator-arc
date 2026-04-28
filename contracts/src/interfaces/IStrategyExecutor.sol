// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface IStrategyExecutor {
    event RebalanceExecuted(
        uint256 indexed cycleId,
        address[] basket,
        uint256[] allocations,
        bytes edgeMetrics
    );
    event PositionEntered(uint256 indexed positionId, address indexed market, uint256 usdcSpent, uint256 ytReceived);
    event PositionExited(uint256 indexed positionId, uint256 usdcReceived);
    event EmergencyExitTriggered(uint256 cycleId, address indexed guardian, uint256 positionsClosed);
    event SlippageBpsUpdated(uint16 oldBps, uint16 newBps);

    function runWeeklyCycle() external;
    function closeYT(uint256 positionId, uint256 minUsdcOut) external;
    function emergencyExit(uint256 maxToProcess) external;
    function setSlippageBps(uint16 bps) external;
    function slippageBps() external view returns (uint16);
}
