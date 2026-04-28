// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IWiring} from "../interfaces/IWiring.sol";
import {ICurator} from "../interfaces/ICurator.sol";
import {IPrincipalVault} from "../interfaces/IPrincipalVault.sol";

/// @title Curator — whitelist + basket + fee management (audit-fixed v2)
/// @notice UUPS upgradeable. CURATOR_ROLE is a 2/3 Gnosis Safe wrapped behind
///         a TimelockController (deployment topology). All privileged setters
///         have an inline propose/commit pair with 48h delay as defense-in-depth.
/// @dev    Audit fixes:
///         C-1 — EIP-7201 slot recomputed canonically.
///         H-1 — Constructor disables initializers on impl.
///         C-3 — rewireStrategy REMOVED. Wiring.setStrategyExecutor is now
///               admin-only (3/5 multisig + TimelockController), not curator.
///         C-4 — propose/commit pairs added for setFee, setFeeRecipient (48h).
///         M-8 — Per-proposal nonce in whitelist propose/veto so curator
///               cannot race the guardian's veto.
///         L-3 — proposeWhitelistMarket no longer takes the unused `bool ok`.
///         L-4 — emergencyRemoveFromWhitelist (guardian-only) for committed.
contract Curator is ICurator, Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    error TimelockNotElapsed(uint256 effectiveAt);
    error MarketNotProposed(address market);
    error VetoedAlready();
    error NotWhitelisted(address market);
    error InvalidFee();
    error NoPendingProposal();

    uint16 public constant MAX_FEE_BPS = 2000; // 20%

    /// @custom:storage-location erc7201:dcurator.storage.v1.Curator
    struct CS {
        IWiring wiring;
        uint256 timelockDelay;
        // Whitelist with per-market proposal nonce (M-8)
        mapping(address => bool) whitelist;
        mapping(address => uint256) proposedAt;
        mapping(address => uint64) proposalNonce;
        mapping(address => mapping(uint64 => bool)) vetoedNonce;
        // Basket
        address[] currentBasket;
        // Fee
        uint16 feeBps;
        address feeRecipient;
        // Pending parameter changes (C-4)
        uint256 pendingFeeBps;
        uint64 pendingFeeAt;
        address pendingFeeRecipient;
        uint64 pendingFeeRecipientAt;
        uint256[36] __gap;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("dcurator.storage.v1.Curator")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SLOT =
        0xfbc4302dcd9159449ee3a52fb8c45e89f5f690bf39087c249ca9f861c3119800;

    function _s() private pure returns (CS storage s) {
        bytes32 slot = SLOT;
        assembly {
            s.slot := slot
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IWiring _wiring,
        uint256 _timelockDelay,
        address _safeMultisig,
        address _guardian,
        address _feeRecipient
    ) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        CS storage s = _s();
        s.wiring = _wiring;
        s.timelockDelay = _timelockDelay;
        s.feeBps = 1000;
        s.feeRecipient = _feeRecipient;
        _grantRole(DEFAULT_ADMIN_ROLE, _safeMultisig);
        _grantRole(CURATOR_ROLE, _safeMultisig);
        _grantRole(GUARDIAN_ROLE, _guardian);
    }

    /* ------------------------------- whitelist ------------------------------- */

    function proposeWhitelistMarket(address market) external onlyRole(CURATOR_ROLE) {
        CS storage s = _s();
        s.proposedAt[market] = block.timestamp;
        s.proposalNonce[market]++; // M-8: increment per-proposal nonce
        emit WhitelistProposed(market, block.timestamp + s.timelockDelay);
    }

    function commitWhitelistMarket(address market) external onlyRole(CURATOR_ROLE) {
        CS storage s = _s();
        uint256 proposed = s.proposedAt[market];
        uint64 nonce = s.proposalNonce[market];
        if (proposed == 0) revert MarketNotProposed(market);
        if (s.vetoedNonce[market][nonce]) revert VetoedAlready();
        if (block.timestamp < proposed + s.timelockDelay) {
            revert TimelockNotElapsed(proposed + s.timelockDelay);
        }
        s.whitelist[market] = true;
        s.proposedAt[market] = 0;
        emit WhitelistCommitted(market, true);
    }

    /// @notice M-8: veto applies to the CURRENT proposal nonce only.
    ///         A subsequent re-propose increments the nonce, requiring fresh veto.
    function vetoWhitelistMarket(address market) external onlyRole(GUARDIAN_ROLE) {
        CS storage s = _s();
        uint64 nonce = s.proposalNonce[market];
        s.vetoedNonce[market][nonce] = true;
        s.proposedAt[market] = 0;
        emit WhitelistVetoed(market, msg.sender);
    }

    /// @notice L-4: guardian can emergency-remove a committed market.
    function emergencyRemoveFromWhitelist(address market) external onlyRole(GUARDIAN_ROLE) {
        CS storage s = _s();
        if (!s.whitelist[market]) revert NotWhitelisted(market);
        s.whitelist[market] = false;
        emit WhitelistCommitted(market, false);
    }

    function isMarketWhitelisted(address market) external view returns (bool) {
        return _s().whitelist[market];
    }

    /* --------------------------------- basket -------------------------------- */

    function setWeeklyBasket(address[] calldata markets) external onlyRole(CURATOR_ROLE) {
        CS storage s = _s();
        for (uint256 i; i < markets.length; ++i) {
            if (!s.whitelist[markets[i]]) revert NotWhitelisted(markets[i]);
        }
        delete s.currentBasket;
        for (uint256 i; i < markets.length; ++i) {
            s.currentBasket.push(markets[i]);
        }
        emit BasketUpdated(markets);
    }

    function getWeeklyBasket() external view returns (address[] memory) {
        return _s().currentBasket;
    }

    /* ------------------------- fee — propose/commit (C-4) -------------------- */

    function proposeFee(uint16 bps) external onlyRole(CURATOR_ROLE) {
        if (bps > MAX_FEE_BPS) revert InvalidFee();
        CS storage s = _s();
        s.pendingFeeBps = bps;
        s.pendingFeeAt = uint64(block.timestamp);
    }

    function commitFee() external onlyRole(CURATOR_ROLE) {
        CS storage s = _s();
        if (s.pendingFeeAt == 0) revert NoPendingProposal();
        if (block.timestamp < s.pendingFeeAt + s.timelockDelay) {
            revert TimelockNotElapsed(s.pendingFeeAt + s.timelockDelay);
        }
        emit FeeUpdated(s.feeBps, uint16(s.pendingFeeBps));
        s.feeBps = uint16(s.pendingFeeBps);
        s.pendingFeeAt = 0;
        s.pendingFeeBps = 0;
    }

    function setFee(uint16 /*bps*/) external pure {
        revert("use proposeFee+commitFee"); // legacy interface compat
    }

    function proposeFeeRecipient(address r) external onlyRole(CURATOR_ROLE) {
        CS storage s = _s();
        s.pendingFeeRecipient = r;
        s.pendingFeeRecipientAt = uint64(block.timestamp);
    }

    function commitFeeRecipient() external onlyRole(CURATOR_ROLE) {
        CS storage s = _s();
        if (s.pendingFeeRecipientAt == 0) revert NoPendingProposal();
        if (block.timestamp < s.pendingFeeRecipientAt + s.timelockDelay) {
            revert TimelockNotElapsed(s.pendingFeeRecipientAt + s.timelockDelay);
        }
        emit FeeRecipientUpdated(s.feeRecipient, s.pendingFeeRecipient);
        s.feeRecipient = s.pendingFeeRecipient;
        s.pendingFeeRecipientAt = 0;
        s.pendingFeeRecipient = address(0);
    }

    function setFeeRecipient(address /*r*/) external pure {
        revert("use proposeFeeRecipient+commitFeeRecipient");
    }

    function feeBps() external view returns (uint16) {
        return _s().feeBps;
    }

    function feeRecipient() external view returns (address) {
        return _s().feeRecipient;
    }

    /* --------------------------------- pause --------------------------------- */

    function pauseAll() external onlyRole(GUARDIAN_ROLE) {
        IPrincipalVault(_s().wiring.principalVault()).pause();
        emit PausedAll(msg.sender, block.timestamp);
    }

    function unpauseAll() external onlyRole(CURATOR_ROLE) {
        IPrincipalVault(_s().wiring.principalVault()).unpause();
    }

    /* ----------------------- rewire — REMOVED (C-3 fix) ---------------------- */

    /// @notice C-3 FIX: rewireStrategy was removed. Curator no longer can
    ///         change StrategyExecutor or YieldSweeper. Those are now
    ///         admin-only ops on Wiring (3/5 multisig + 48h TimelockController).
    function rewireStrategy(address /*newExecutor*/) external pure {
        revert("admin-only via Wiring.setStrategyExecutor + timelock");
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
