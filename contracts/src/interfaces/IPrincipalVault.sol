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
    function morphoBalanceInAssets() external view returns (uint256);
    function paused() external view returns (bool);
    function pauseExpiresAt() external view returns (uint64);
    function MAX_PAUSE_DURATION() external view returns (uint64);

    /// @notice Sweeps yield (morphoBalance - principalHWM) to LotteryTreasury.
    function sweepYield() external returns (uint256 yieldUsdc);

    function pause() external;
    function renewPause() external;
    function unpause() external;
}
