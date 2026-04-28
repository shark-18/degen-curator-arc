// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface IYieldSweeper {
    event Swept(uint256 amount, uint256 timestamp);

    function sweep() external returns (uint256 yieldUsdc);
    function pendingYield() external view returns (uint256);
}
