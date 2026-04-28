// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IWiring} from "../interfaces/IWiring.sol";

/// @title Wiring — single-source-of-truth address registry
/// @notice Cores read periphery addresses from here. Curator can swap periphery
///         contracts cleanly without touching cores. UUPS-upgradeable but only
///         the registry mappings ever change — cardinal cores' addresses are set
///         once at deploy time and never re-pointed.
contract Wiring is IWiring, Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");

    /// @custom:storage-location erc7201:dcurator.storage.v1.Wiring
    struct WiringStorage {
        // Set once (cores)
        address principalVault;
        address lotteryTreasury;
        address positionManager;
        // Replaceable via curator + timelock
        address strategyExecutor;
        address yieldSweeper;
        address curator;
        address guardian;
        address admin;
        bool coresLocked;
        uint256[40] __gap;
    }

    // keccak256(abi.encode(uint256(keccak256("dcurator.storage.v1.Wiring")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WIRING_STORAGE_SLOT =
        0x9f3aa6c89f0e7e72c9b03cf0d63c91c7df2a64d3c11e3a9e1f0f1dd1c4b81700;

    function _s() private pure returns (WiringStorage storage s) {
        bytes32 slot = WIRING_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    function initialize(address _admin) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _s().admin = _admin;
    }

    /// @notice Sets the immutable core addresses + initial periphery. One-shot.
    function setAll(
        address _principalVault,
        address _lotteryTreasury,
        address _positionManager,
        address _strategyExecutor,
        address _yieldSweeper,
        address _curator,
        address _guardian
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        WiringStorage storage s = _s();
        require(!s.coresLocked, "cores locked");
        s.principalVault = _principalVault;
        s.lotteryTreasury = _lotteryTreasury;
        s.positionManager = _positionManager;
        s.strategyExecutor = _strategyExecutor;
        s.yieldSweeper = _yieldSweeper;
        s.curator = _curator;
        s.guardian = _guardian;
        s.coresLocked = true;
    }

    /// @notice Replaceable periphery setters — curator role only.
    function setStrategyExecutor(address a) external onlyRole(CURATOR_ROLE) {
        emit WiringUpdated("strategyExecutor", _s().strategyExecutor, a);
        _s().strategyExecutor = a;
    }

    function setYieldSweeper(address a) external onlyRole(CURATOR_ROLE) {
        emit WiringUpdated("yieldSweeper", _s().yieldSweeper, a);
        _s().yieldSweeper = a;
    }

    function setCurator(address a) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit WiringUpdated("curator", _s().curator, a);
        _s().curator = a;
        _grantRole(CURATOR_ROLE, a);
    }

    function setGuardian(address a) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit WiringUpdated("guardian", _s().guardian, a);
        _s().guardian = a;
    }

    /* ----------------------------------- views ------------------------------- */

    function principalVault() external view returns (address) {
        return _s().principalVault;
    }
    function lotteryTreasury() external view returns (address) {
        return _s().lotteryTreasury;
    }
    function positionManager() external view returns (address) {
        return _s().positionManager;
    }
    function strategyExecutor() external view returns (address) {
        return _s().strategyExecutor;
    }
    function yieldSweeper() external view returns (address) {
        return _s().yieldSweeper;
    }
    function curator() external view returns (address) {
        return _s().curator;
    }
    function guardian() external view returns (address) {
        return _s().guardian;
    }
    function admin() external view returns (address) {
        return _s().admin;
    }

    /* -------------------------------- upgrade gate --------------------------- */

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
