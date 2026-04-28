// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IPrincipalVault is IERC4626 {
    event Deposited(
        address indexed user,
        uint256 amount,
        uint256 shares,
        uint256 totalDepositors,
        uint256 totalAssets
    );
    event Withdrawn(address indexed user, uint256 amount, uint256 shares);
    event YieldSwept(uint256 amount, uint256 newPrincipalHWM);
    event Paused(address indexed guardian, uint256 timestamp);
    event Unpaused(address indexed curator, uint256 timestamp);

    function depositCap() external view returns (uint128);
    function depositorCap() external view returns (uint32);
    function depositorCount() external view returns (uint32);
    function minDeposit() external view returns (uint128);
    function principalHighWater() external view returns (uint256);
    function paused() external view returns (bool);

    /// @notice Sweeps yield (totalAssets() - principalHWM) to LotteryTreasury.
    ///         Callable ONLY by the address registered at Wiring.yieldSweeper().
    ///         Cannot reduce principalHWM under any input.
    function sweepYield() external returns (uint256 yieldUsdc);

    function pause() external;
    function unpause() external;
}
