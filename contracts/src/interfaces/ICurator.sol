// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface ICurator {
    event WhitelistProposed(address indexed market, uint256 effectiveAt);
    event WhitelistCommitted(address indexed market, bool included);
    event WhitelistVetoed(address indexed market, address indexed guardian);
    event BasketUpdated(address[] markets);
    event FeeUpdated(uint16 oldBps, uint16 newBps);
    event FeeRecipientUpdated(address indexed oldR, address indexed newR);
    event PausedAll(address indexed guardian, uint256 timestamp);

    function proposeWhitelistMarket(address market) external;
    function commitWhitelistMarket(address market) external;
    function vetoWhitelistMarket(address market) external; // guardian only
    function emergencyRemoveFromWhitelist(address market) external; // guardian only

    function setWeeklyBasket(address[] calldata markets) external;
    function getWeeklyBasket() external view returns (address[] memory);

    function isMarketWhitelisted(address market) external view returns (bool);

    /// @notice Fee changes are timelocked: propose, wait, commit.
    function proposeFee(uint16 bps) external;
    function commitFee() external;
    function proposeFeeRecipient(address r) external;
    function commitFeeRecipient() external;

    function feeBps() external view returns (uint16);
    function feeRecipient() external view returns (address);

    function pauseAll() external;
    function unpauseAll() external;
}
