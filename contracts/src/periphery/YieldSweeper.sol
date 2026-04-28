// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IWiring} from "../interfaces/IWiring.sol";
import {IYieldSweeper} from "../interfaces/IYieldSweeper.sol";
import {IPrincipalVault} from "../interfaces/IPrincipalVault.sol";

/// @title YieldSweeper — pulls Morpho yield into LotteryTreasury (audit-fixed v2)
/// @dev    Audit fixes:
///         C-1 — EIP-7201 slot recomputed canonically.
///         H-1 — Constructor disables initializers on implementation.
contract YieldSweeper is IYieldSweeper, Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    error IntervalNotElapsed();

    /// @custom:storage-location erc7201:dcurator.storage.v1.YieldSweeper
    struct YS {
        IWiring wiring;
        uint64 minIntervalSec;
        uint64 lastSweepTs;
        uint256[48] __gap;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("dcurator.storage.v1.YieldSweeper")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SLOT =
        0x193d56f977557616239c7d9df9908a19015f37b43de560760ebdd8b99e9e0500;

    function _s() private pure returns (YS storage s) {
        bytes32 slot = SLOT;
        assembly {
            s.slot := slot
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IWiring _wiring, address _admin, address _keeper) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _keeper);
        _s().wiring = _wiring;
        _s().minIntervalSec = 6 days;
    }

    function sweep() external onlyRole(KEEPER_ROLE) returns (uint256 yieldUsdc) {
        YS storage s = _s();
        if (block.timestamp < s.lastSweepTs + s.minIntervalSec) revert IntervalNotElapsed();
        s.lastSweepTs = uint64(block.timestamp);
        yieldUsdc = IPrincipalVault(s.wiring.principalVault()).sweepYield();
        emit Swept(yieldUsdc, block.timestamp);
    }

    function pendingYield() external view returns (uint256) {
        IPrincipalVault pv = IPrincipalVault(_s().wiring.principalVault());
        uint256 morphoBalance = pv.morphoBalanceInAssets();
        uint256 hwm = pv.principalHighWater();
        return morphoBalance > hwm ? morphoBalance - hwm : 0;
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
