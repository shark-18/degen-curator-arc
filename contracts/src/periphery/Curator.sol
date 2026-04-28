// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IWiring} from "../interfaces/IWiring.sol";
import {ICurator} from "../interfaces/ICurator.sol";
import {IPrincipalVault} from "../interfaces/IPrincipalVault.sol";

/// @title Curator — whitelist + basket + fee management with timelock
/// @notice UUPS upgradeable. CURATOR_ROLE is a 2/3 Gnosis Safe.
///         Whitelist additions are timelocked 48h with guardian veto.
///         Basket selection (within whitelist) is real-time.
contract Curator is ICurator, Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    error TimelockNotElapsed(uint256 effectiveAt);
    error MarketNotProposed(address market);
    error VetoedAlready();

    /// @custom:storage-location erc7201:dcurator.storage.v1.Curator
    struct CS {
        IWiring wiring;
        uint256 timelockDelay; // 48h
        mapping(address => bool) whitelist;
        mapping(address => uint256) proposedAt; // 0 = not proposed
        mapping(address => bool) vetoed;
        address[] currentBasket;
        uint16 feeBps; // 1000 = 10%
        address feeRecipient;
        uint256[40] __gap;
    }

    bytes32 private constant SLOT =
        0xc4d8e2f5b6c7a8d9e0f1c2b3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d200;

    function _s() private pure returns (CS storage s) {
        bytes32 slot = SLOT;
        assembly {
            s.slot := slot
        }
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
        s.feeBps = 1000; // 10% on profits
        s.feeRecipient = _feeRecipient;
        _grantRole(DEFAULT_ADMIN_ROLE, _safeMultisig);
        _grantRole(CURATOR_ROLE, _safeMultisig);
        _grantRole(GUARDIAN_ROLE, _guardian);
    }

    /* ------------------------------- whitelist ------------------------------- */

    function proposeWhitelistMarket(address market, bool ok) external onlyRole(CURATOR_ROLE) {
        CS storage s = _s();
        s.proposedAt[market] = block.timestamp;
        s.vetoed[market] = false;
        emit WhitelistProposed(market, block.timestamp + s.timelockDelay);
    }

    function commitWhitelistMarket(address market) external onlyRole(CURATOR_ROLE) {
        CS storage s = _s();
        uint256 proposed = s.proposedAt[market];
        if (proposed == 0) revert MarketNotProposed(market);
        if (s.vetoed[market]) revert VetoedAlready();
        if (block.timestamp < proposed + s.timelockDelay) {
            revert TimelockNotElapsed(proposed + s.timelockDelay);
        }
        s.whitelist[market] = true;
        s.proposedAt[market] = 0;
        emit WhitelistCommitted(market, true);
    }

    function vetoWhitelistMarket(address market) external onlyRole(GUARDIAN_ROLE) {
        CS storage s = _s();
        s.vetoed[market] = true;
        s.proposedAt[market] = 0;
        emit WhitelistVetoed(market, msg.sender);
    }

    function isMarketWhitelisted(address market) external view returns (bool) {
        return _s().whitelist[market];
    }

    /* --------------------------------- basket -------------------------------- */

    function setWeeklyBasket(address[] calldata markets) external onlyRole(CURATOR_ROLE) {
        CS storage s = _s();
        // Validate all markets are whitelisted
        for (uint256 i; i < markets.length; ++i) {
            require(s.whitelist[markets[i]], "not whitelisted");
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

    /* ---------------------------------- fees --------------------------------- */

    function setFee(uint16 bps) external onlyRole(CURATOR_ROLE) {
        require(bps <= 2000, "fee too high"); // max 20%
        CS storage s = _s();
        emit FeeUpdated(s.feeBps, bps);
        s.feeBps = bps;
    }

    function setFeeRecipient(address r) external onlyRole(CURATOR_ROLE) {
        CS storage s = _s();
        emit FeeRecipientUpdated(s.feeRecipient, r);
        s.feeRecipient = r;
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

    /* ------------------------------ rewire path ------------------------------ */

    function rewireStrategy(address newExecutor) external onlyRole(CURATOR_ROLE) {
        // Timelocked at the Wiring layer via DEFAULT_ADMIN_ROLE separation
        _s().wiring.setStrategyExecutor(newExecutor);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
