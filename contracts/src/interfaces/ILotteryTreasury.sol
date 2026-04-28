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

    function creditYield(uint256 amount) external;
    function notifyPurchase(uint256 positionId, uint256 usdcSpent) external;
    function settle(uint256 positionId, uint256 usdcReceived) external;

    function claim(address user) external returns (uint256);
    function claimableOf(address user) external view returns (uint256);
    function totalAssetsAtRisk() external view returns (uint256);
    function globalShareIndex() external view returns (uint256);

    function cumulativeYieldSwept() external view returns (uint256);
    function cumulativeStrategySpend() external view returns (uint256);

    /// @notice Hook called by PrincipalVault on dCURATOR balance changes.
    ///         Snapshots user's claimable lottery USDC before the share change.
    function accrueOnBalanceChange(address user) external;
}
