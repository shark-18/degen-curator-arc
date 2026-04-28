// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface ILotteryTreasury {
    event YieldCredited(uint256 amount, uint256 totalSwept);
    event PurchaseNotified(uint256 indexed positionId, uint256 usdcSpent);
    event Settled(
        uint256 indexed positionId,
        uint256 usdcReceived,
        uint256 fee,
        uint256 newGlobalShareIndex
    );
    event Claimed(address indexed user, uint256 amount);
    event UserAccrued(address indexed user, uint256 owed, uint256 newCheckpoint);
    event UserLockupStarted(address indexed user, uint64 startTimestamp);
    event UserLockupReset(address indexed user);

    function creditYield(uint256 amount) external;
    function notifyPurchase(uint256 positionId, uint256 usdcSpent) external;
    function settle(uint256 positionId, uint256 usdcReceived) external;

    function claim() external returns (uint256);
    function claimableOf(address user) external view returns (uint256);
    function totalAssetsAtRisk() external view returns (uint256);
    function globalShareIndex() external view returns (uint256);

    function cumulativeYieldSwept() external view returns (uint256);
    function cumulativeStrategySpend() external view returns (uint256);

    /// @notice Snapshots user's claimable lottery USDC at the current global index.
    function accrueOnBalanceChange(address user) external;

    /// @notice Called when user's balance leaves zero. Starts lockup clock.
    function onPositiveBalance(address user) external;

    /// @notice Called when user's balance hits zero. Resets lockup state.
    function onZeroBalance(address user) external;

    /// @notice First time user held shares (monotone-set on transition zero→positive).
    function userFirstHoldTimestamp(address user) external view returns (uint64);

    /// @notice Lockup duration after firstHold before lottery accruals start.
    function LOCKUP_DURATION() external view returns (uint64);
}
