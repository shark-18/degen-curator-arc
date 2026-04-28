// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IWiring} from "../interfaces/IWiring.sol";
import {IYieldSweeper} from "../interfaces/IYieldSweeper.sol";
import {IPrincipalVault} from "../interfaces/IPrincipalVault.sol";
import {IMorphoVault} from "../interfaces/IMorphoVault.sol";

/// @title YieldSweeper — pulls Morpho yield into LotteryTreasury
/// @notice UUPS-upgradeable periphery. Has the ONLY authority to call
///         PrincipalVault.sweepYield(). Performs no math beyond delegating
///         to the vault — keeps the sensitive HWM logic inside the immutable
///         core contract.
contract YieldSweeper is IYieldSweeper, Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    /// @custom:storage-location erc7201:dcurator.storage.v1.YieldSweeper
    struct YS {
        IWiring wiring;
        uint64 minIntervalSec;
        uint64 lastSweepTs;
        uint256[48] __gap;
    }

    bytes32 private constant SLOT =
        0x4ee2cd23a0c34d5e4cca8f59afe1c50e3c0c4f9be2cb2cda6f0d34a47a85ee00;

    function _s() private pure returns (YS storage s) {
        bytes32 slot = SLOT;
        assembly {
            s.slot := slot
        }
    }

    function initialize(IWiring _wiring, address _admin, address _keeper) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _keeper);
        _s().wiring = _wiring;
        _s().minIntervalSec = 6 days; // weekly minus buffer
    }

    function sweep() external onlyRole(KEEPER_ROLE) returns (uint256 yieldUsdc) {
        YS storage s = _s();
        require(block.timestamp >= s.lastSweepTs + s.minIntervalSec, "interval");
        s.lastSweepTs = uint64(block.timestamp);
        yieldUsdc = IPrincipalVault(s.wiring.principalVault()).sweepYield();
        emit Swept(yieldUsdc, block.timestamp);
    }

    function pendingYield() external view returns (uint256) {
        IPrincipalVault pv = IPrincipalVault(_s().wiring.principalVault());
        uint256 ta = pv.totalAssets();
        uint256 hwm = pv.principalHighWater();
        return ta > hwm ? ta - hwm : 0;
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
