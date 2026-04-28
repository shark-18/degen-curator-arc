// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface IWiring {
    event WiringUpdated(bytes32 indexed key, address indexed oldAddr, address indexed newAddr);

    function principalVault() external view returns (address);
    function lotteryTreasury() external view returns (address);
    function positionManager() external view returns (address);
    function strategyExecutor() external view returns (address);
    function curator() external view returns (address);
    function yieldSweeper() external view returns (address);
    function guardian() external view returns (address);
    function admin() external view returns (address);

    function setStrategyExecutor(address) external;
    function setYieldSweeper(address) external;
    function setCurator(address) external;
    function setGuardian(address) external;
}
