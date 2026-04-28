// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IWiring} from "../interfaces/IWiring.sol";

/// @title Wiring — single-source-of-truth address registry (audit-fixed v2)
/// @notice Cores read periphery addresses from here. Curator can swap periphery
///         contracts cleanly without touching cores.
/// @dev    Audit fixes:
///         C-1 — EIP-7201 storage slot recomputed against canonical formula.
///         H-1 — Constructor disables initializers on the implementation.
///         H-5 — setCurator revokes old role before granting new one.
///
///         OPERATIONAL NOTE (M-2): Wiring upgrade authority resides with
///         DEFAULT_ADMIN_ROLE (3/5 admin multisig + TimelockController in
///         deployment). Treat Wiring as operationally-immutable post-deploy;
///         a Wiring upgrade is an extreme operation requiring 2 multisigs +
///         1-week timelock + community announcement.
contract Wiring is IWiring, Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");

    error CoresAlreadyLocked();
    error ZeroAddress();

    /// @custom:storage-location erc7201:dcurator.storage.v1.Wiring
    struct WS {
        address principalVault;
        address lotteryTreasury;
        address positionManager;
        address strategyExecutor;
        address yieldSweeper;
        address curator;
        address guardian;
        address admin;
        bool coresLocked;
        uint256[40] __gap;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("dcurator.storage.v1.Wiring")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev C-1 fix: canonical EIP-7201 slot, verified against Python reference.
    bytes32 private constant SLOT =
        0x7404cd9655913f01b956677aa7bc7844f80514a7131b4fb3aea0308e1971f600;

    function _s() private pure returns (WS storage s) {
        bytes32 slot = SLOT;
        assembly {
            s.slot := slot
        }
    }

    /// @dev H-1 fix: prevent initialization of the implementation directly.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _admin) external initializer {
        if (_admin == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _s().admin = _admin;
    }

    /// @notice One-shot setter for ALL addresses; locks cores forever.
    function setAll(
        address _principalVault,
        address _lotteryTreasury,
        address _positionManager,
        address _strategyExecutor,
        address _yieldSweeper,
        address _curator,
        address _guardian
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        WS storage s = _s();
        if (s.coresLocked) revert CoresAlreadyLocked();
        if (
            _principalVault == address(0) || _lotteryTreasury == address(0)
                || _positionManager == address(0) || _strategyExecutor == address(0)
                || _yieldSweeper == address(0) || _curator == address(0)
                || _guardian == address(0)
        ) revert ZeroAddress();

        s.principalVault = _principalVault;
        s.lotteryTreasury = _lotteryTreasury;
        s.positionManager = _positionManager;
        s.strategyExecutor = _strategyExecutor;
        s.yieldSweeper = _yieldSweeper;
        s.curator = _curator;
        s.guardian = _guardian;
        s.coresLocked = true;
        _grantRole(CURATOR_ROLE, _curator);
    }

    /// @notice Replaceable periphery setters — admin role + timelock in deployment.
    /// @dev    C-3 fix: was CURATOR_ROLE (instant via 2/3 multisig), now
    ///         DEFAULT_ADMIN_ROLE (3/5 multisig + 48h TimelockController).
    function setStrategyExecutor(address a) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (a == address(0)) revert ZeroAddress();
        emit WiringUpdated("strategyExecutor", _s().strategyExecutor, a);
        _s().strategyExecutor = a;
    }

    function setYieldSweeper(address a) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (a == address(0)) revert ZeroAddress();
        emit WiringUpdated("yieldSweeper", _s().yieldSweeper, a);
        _s().yieldSweeper = a;
    }

    function setCurator(address a) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (a == address(0)) revert ZeroAddress();
        WS storage s = _s();
        address old = s.curator;
        // H-5 fix: revoke old curator's CURATOR_ROLE before granting new.
        if (old != address(0)) _revokeRole(CURATOR_ROLE, old);
        _grantRole(CURATOR_ROLE, a);
        s.curator = a;
        emit WiringUpdated("curator", old, a);
    }

    function setGuardian(address a) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (a == address(0)) revert ZeroAddress();
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
    function coresLocked() external view returns (bool) {
        return _s().coresLocked;
    }

    /* -------------------------------- upgrade gate --------------------------- */

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
