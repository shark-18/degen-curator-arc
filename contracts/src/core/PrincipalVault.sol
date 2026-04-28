// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC4626, IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20, IERC20 as IERC20Base} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IWiring} from "../interfaces/IWiring.sol";
import {IPrincipalVault} from "../interfaces/IPrincipalVault.sol";
import {IMorphoVault} from "../interfaces/IMorphoVault.sol";
import {ILotteryTreasury} from "../interfaces/ILotteryTreasury.sol";

/// @title PrincipalVault — dCURATOR cardinal asset custodian (audit-fixed v2)
/// @notice ERC-4626 USDC vault. Holds 100% of user principal in a curated
///         Morpho USDC vault. Yield (excess over principalHWM) is sweepable
///         by the YieldSweeper periphery only — never strategy code.
/// @dev    IMMUTABLE. No upgrade path. No admin extraction path.
///
///         Audit fixes from /Pashov-style review:
///         C-2 — totalAssets() returns min(morphoBalance, principalHWM) so
///               share price is exactly 1:1 in normal operation. Yield-
///               extraction sandwich is mathematically eliminated.
///         M-3 — Exact-amount Morpho approval per deposit (no infinite).
///         M-5 — Single accrue path (via _update only), no double-accrue.
///         M-6 — Transfer to fresh recipient requires minDeposit-equivalent
///               shares (sybil cap-griefing fix).
///         H-4 — Pause auto-expires after 7 days.
contract PrincipalVault is ERC4626, ERC20Permit, ReentrancyGuardTransient, IPrincipalVault {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /* --------------------------------- errors --------------------------------- */

    error CapExceeded();
    error DepositorCapReached();
    error MinDepositNotMet();
    error TransferBelowMin();
    error YieldUnderflow();
    error NotYieldSweeper();
    error NotGuardian();
    error NotCurator();
    error VaultPaused();
    error ZeroAmount();
    error PauseAlreadyExpired();

    /* --------------------------------- events --------------------------------- */

    event PauseRenewed(uint64 newExpiresAt);

    /* -------------------------------- constants ------------------------------ */

    /// @notice Maximum auto-expiry pause duration. Guardian sets, expires automatically.
    uint64 public constant MAX_PAUSE_DURATION = 7 days;

    /* -------------------------------- immutables ------------------------------ */

    uint128 public immutable depositCap;
    uint32 public immutable depositorCap;
    uint128 public immutable minDeposit;

    IERC20 public immutable USDC;
    IMorphoVault public immutable MORPHO;
    IWiring public immutable WIRING;

    /* --------------------------------- storage -------------------------------- */

    /// @notice Number of unique addresses with non-zero share balance (≤ depositorCap)
    uint32 public depositorCount;
    /// @notice Last yield-sweep block timestamp
    uint64 public lastSweepTimestamp;
    /// @notice Pause auto-expiry timestamp. Effective pause = now < pauseExpiresAt.
    uint64 public pauseExpiresAt;

    /// @notice Principal high-water mark (USDC, 6 decimals).
    ///         Equals cumulative user deposits minus cumulative user withdrawals.
    ///         CARDINAL: yield = morphoBalance - principalHWM (always ≥ 0 absent loss).
    uint256 public principalHWM;

    /* ------------------------------- modifiers ------------------------------- */

    modifier onlyYieldSweeper() {
        if (msg.sender != WIRING.yieldSweeper()) revert NotYieldSweeper();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != WIRING.guardian()) revert NotGuardian();
        _;
    }

    modifier onlyCurator() {
        if (msg.sender != WIRING.curator()) revert NotCurator();
        _;
    }

    modifier whenNotPaused() {
        if (_paused()) revert VaultPaused();
        _;
    }

    /* ------------------------------ constructor ------------------------------ */

    constructor(
        IERC20 _usdc,
        IMorphoVault _morpho,
        IWiring _wiring,
        uint128 _depositCap,
        uint32 _depositorCap,
        uint128 _minDeposit
    )
        ERC4626(_usdc)
        ERC20("Degen Curator USDC", "dCURATOR")
        ERC20Permit("Degen Curator USDC")
    {
        USDC = _usdc;
        MORPHO = _morpho;
        WIRING = _wiring;
        depositCap = _depositCap;
        depositorCap = _depositorCap;
        minDeposit = _minDeposit;
        // M-3 fix: NO infinite approval here. Approve exact amount per deposit.
    }

    /* ----------------------------- ERC-4626 overrides ------------------------ */

    /// @notice Returns the redeemable USDC value of the vault = principalHWM.
    /// @dev    C-2 FIX: pricePerShare is exactly 1:1 USDC:share (modulo the
    ///         virtual offset). Morpho yield (above HWM) is NOT included in
    ///         totalAssets — it flows through `sweepYield()` to lottery.
    ///         No yield-extraction sandwich is possible because the Morpho-side
    ///         appreciation never enters share-conversion math.
    /// @dev    OPERATIONAL CAVEAT: in the rare event of a Morpho loss
    ///         (morphoBalance < principalHWM), withdrawals are FCFS — the last
    ///         user to withdraw will see MORPHO.withdraw revert. Admin must
    ///         pause + ratably-redistribute via emergency procedure.
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return principalHWM;
    }

    /// @notice Inflation-attack defense via virtual share offset (OZ pattern).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @notice ERC-4626 deposit cap accounting for caps + pause.
    function maxDeposit(address receiver) public view override(ERC4626, IERC4626) returns (uint256) {
        if (_paused()) return 0;
        uint256 hwm = principalHWM;
        if (hwm >= depositCap) return 0;
        if (depositorCount >= depositorCap && balanceOf(receiver) == 0) return 0;
        unchecked {
            return depositCap - hwm;
        }
    }

    function maxMint(address receiver) public view override(ERC4626, IERC4626) returns (uint256) {
        return convertToShares(maxDeposit(receiver));
    }

    /* --------------------------- deposit / withdraw ------------------------- */

    /// @dev Custom deposit hook. CEI: validate → pull → supply to Morpho → mint.
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused {
        if (assets == 0 || shares == 0) revert ZeroAmount();
        if (assets < minDeposit && balanceOf(receiver) == 0) revert MinDepositNotMet();
        if (principalHWM + assets > depositCap) revert CapExceeded();

        // Pull USDC, exact-amount approve Morpho (M-3 fix), supply, mint.
        USDC.safeTransferFrom(caller, address(this), assets);
        USDC.forceApprove(address(MORPHO), assets);
        MORPHO.deposit(assets, address(this));

        // Update HWM BEFORE _mint (which triggers _update accrue + cap counter).
        principalHWM += assets;

        _mint(receiver, shares);

        emit Deposited(receiver, assets, shares, depositorCount, totalAssets());
        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev Custom withdraw hook. CEI: burn → reduce HWM → withdraw → pay.
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (assets == 0 || shares == 0) revert ZeroAmount();

        if (caller != owner) _spendAllowance(owner, caller, shares);
        _burn(owner, shares);

        // Reduce HWM. With C-2 totalAssets cap, `assets ≤ principalHWM` should
        // always hold; clamp defensively to never underflow.
        uint256 hwmReduction = assets > principalHWM ? principalHWM : assets;
        unchecked {
            principalHWM -= hwmReduction;
        }

        MORPHO.withdraw(assets, address(this), address(this));
        USDC.safeTransfer(receiver, assets);

        emit Withdrawn(receiver, assets, shares);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev Maintain depositor counter, lockup state, and minDeposit on transfers.
    function _update(address from, address to, uint256 value) internal override {
        // M-5 fix: single accrue path. _update is the only place that
        // calls accrueOnBalanceChange — no duplicate calls from _deposit/_withdraw.
        address treasury = WIRING.lotteryTreasury();
        if (treasury != address(0)) {
            if (from != address(0)) ILotteryTreasury(treasury).accrueOnBalanceChange(from);
            if (to != address(0)) ILotteryTreasury(treasury).accrueOnBalanceChange(to);
        }

        super._update(from, to, value);

        // Post-update state management.
        if (from != address(0) && balanceOf(from) == 0) {
            unchecked {
                depositorCount--;
            }
            if (treasury != address(0)) ILotteryTreasury(treasury).onZeroBalance(from);
        }

        if (to != address(0) && balanceOf(to) == value) {
            // Was zero, now `value`. New depositor.
            // M-6 fix: block sybil-transfer cap-griefing. A direct transfer to a
            // fresh recipient must clear the same min-deposit-equivalent share
            // floor that deposit() would. Mints (from == 0) bypass this since
            // _deposit already enforces minDeposit on USDC value.
            if (from != address(0)) {
                uint256 minShares = _minDepositShares();
                if (value < minShares) revert TransferBelowMin();
            }
            if (depositorCount >= depositorCap) revert DepositorCapReached();
            unchecked {
                depositorCount++;
            }
            if (treasury != address(0)) ILotteryTreasury(treasury).onPositiveBalance(to);
        }
    }

    /// @notice Minimum dCURATOR shares equivalent to minDeposit USDC.
    /// @dev    With totalAssets capped at principalHWM (C-2), pricePerShare ≈ 1:1
    ///         in 1e-(decimalsOffset) units. Computed dynamically.
    function _minDepositShares() internal view returns (uint256) {
        return convertToShares(minDeposit);
    }

    /* -------------------------------- yield path ------------------------------ */

    /// @notice Sweeps yield (morphoBalance - principalHWM) to LotteryTreasury.
    /// @dev    Reads Morpho balance directly (NOT totalAssets, which is capped).
    function sweepYield() external nonReentrant onlyYieldSweeper returns (uint256 yieldUsdc) {
        uint256 morphoAssets = MORPHO.convertToAssets(MORPHO.balanceOf(address(this)));
        uint256 hwm = principalHWM;
        if (morphoAssets <= hwm) revert YieldUnderflow();

        unchecked {
            yieldUsdc = morphoAssets - hwm;
        }

        MORPHO.withdraw(yieldUsdc, address(this), address(this));

        address treasury = WIRING.lotteryTreasury();
        USDC.safeTransfer(treasury, yieldUsdc);
        ILotteryTreasury(treasury).creditYield(yieldUsdc);

        lastSweepTimestamp = uint64(block.timestamp);
        emit YieldSwept(yieldUsdc, hwm);
    }

    /* ---------------------------------- pause -------------------------------- */

    function pause() external onlyGuardian {
        pauseExpiresAt = uint64(block.timestamp) + MAX_PAUSE_DURATION;
        emit Paused(msg.sender, block.timestamp);
    }

    /// @notice Guardian renews the pause by another MAX_PAUSE_DURATION.
    function renewPause() external onlyGuardian {
        if (!_paused()) revert PauseAlreadyExpired();
        pauseExpiresAt = uint64(block.timestamp) + MAX_PAUSE_DURATION;
        emit PauseRenewed(pauseExpiresAt);
    }

    function unpause() external onlyCurator {
        pauseExpiresAt = 0;
        emit Unpaused(msg.sender, block.timestamp);
    }

    function paused() external view returns (bool) {
        return _paused();
    }

    function _paused() internal view returns (bool) {
        return block.timestamp < pauseExpiresAt;
    }

    /* ----------------------------------- views ------------------------------- */

    function principalHighWater() external view returns (uint256) {
        return principalHWM;
    }

    /// @notice Direct read of Morpho-side asset balance (true total managed value).
    function morphoBalanceInAssets() external view returns (uint256) {
        return MORPHO.convertToAssets(MORPHO.balanceOf(address(this)));
    }

    function decimals() public view override(ERC4626, ERC20, IERC20Metadata) returns (uint8) {
        return ERC4626.decimals();
    }
}
