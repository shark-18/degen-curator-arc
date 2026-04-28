// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC4626, IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20, ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IWiring} from "../interfaces/IWiring.sol";
import {IPrincipalVault} from "../interfaces/IPrincipalVault.sol";
import {IMorphoVault} from "../interfaces/IMorphoVault.sol";
import {ILotteryTreasury} from "../interfaces/ILotteryTreasury.sol";

/// @title PrincipalVault — dCURATOR cardinal asset custodian
/// @notice ERC-4626 USDC vault. Holds 100% of user principal in a curated
///         Morpho USDC vault. Yield (excess over principalHWM) is sweepable
///         by the YieldSweeper periphery only — never strategy code.
/// @dev    IMMUTABLE. No upgrade path. No admin extraction path.
///
///         CARDINAL INVARIANT (I1):
///             totalAssets() >= principalHWM
///             principalHWM >= sum(user_deposits) - sum(user_withdrawals)
///
///         Defense layers:
///         1. StrategyExecutor has zero compile-time references to this contract.
///         2. sweepYield() can only be called by Wiring.yieldSweeper().
///         3. sweepYield() math: y = totalAssets - principalHWM (revert on underflow).
///         4. principalHWM only changes inside _deposit/_withdraw hooks.
///         5. ERC-4626 inflation defense: virtual offset = 6.
contract PrincipalVault is ERC4626, ERC20Permit, ReentrancyGuardTransient, IPrincipalVault {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /* --------------------------------- errors --------------------------------- */

    error CapExceeded();
    error DepositorCapReached();
    error MinDepositNotMet();
    error YieldUnderflow();
    error NotYieldSweeper();
    error NotGuardian();
    error NotCurator();
    error VaultPaused();
    error ZeroAmount();

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
    /// @notice Last yield-sweep timestamp
    uint64 public lastSweepTimestamp;
    /// @notice Pause flag (deposit blocked; withdraw always allowed)
    bool public paused;

    /// @notice Principal high-water mark (USDC, 6 decimals).
    ///         Equals cumulative user deposits minus cumulative user withdrawals.
    ///         Yield = totalAssets() - principalHWM (always ≥ 0 absent Morpho loss event).
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
        if (paused) revert VaultPaused();
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

        // Pre-approve Morpho once for the principal flow. Bounded by our own
        // deposit cap; Morpho is a known immutable address. This is the only
        // approval this contract grants.
        _usdc.forceApprove(address(_morpho), type(uint256).max);
    }

    /* ----------------------------- ERC-4626 overrides ------------------------ */

    /// @notice Returns USDC equivalent value of the Morpho vault shares we hold.
    /// @dev    Used by ERC-4626 conversions; reflects Morpho yield in pricePerShare.
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return MORPHO.convertToAssets(MORPHO.balanceOf(address(this)));
    }

    /// @notice Inflation-attack defense via virtual share offset (OZ pattern).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @notice ERC-4626 cap: respects depositCap AND depositorCap AND pause.
    function maxDeposit(address receiver) public view override(ERC4626, IERC4626) returns (uint256) {
        if (paused) return 0;
        uint256 ta = totalAssets();
        if (ta >= depositCap) return 0;
        if (depositorCount >= depositorCap && balanceOf(receiver) == 0) return 0;
        return depositCap - ta;
    }

    function maxMint(address receiver) public view override(ERC4626, IERC4626) returns (uint256) {
        return convertToShares(maxDeposit(receiver));
    }

    /* --------------------------- deposit / withdraw ------------------------- */

    /// @dev Hook: validate caps + min deposit, accrue lottery, supply to Morpho, update HWM.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (assets == 0 || shares == 0) revert ZeroAmount();
        if (assets < minDeposit && balanceOf(receiver) == 0) revert MinDepositNotMet();
        if (totalAssets() + assets > depositCap) revert CapExceeded();

        // Accrue lottery on receiver BEFORE balance change (snapshot pattern)
        ILotteryTreasury(WIRING.lotteryTreasury()).accrueOnBalanceChange(receiver);

        // Pull USDC, supply to Morpho, mint shares
        USDC.safeTransferFrom(caller, address(this), assets);
        MORPHO.deposit(assets, address(this));
        _mint(receiver, shares);

        // Update HWM (principal grew by `assets`)
        principalHWM += assets;

        emit Deposited(receiver, assets, shares, depositorCount, totalAssets());
    }

    /// @dev Hook: accrue lottery, redeem from Morpho, update HWM, transfer to receiver.
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (assets == 0 || shares == 0) revert ZeroAmount();

        // Accrue lottery on owner BEFORE balance change
        ILotteryTreasury(WIRING.lotteryTreasury()).accrueOnBalanceChange(owner);

        // Burn shares first (CEI)
        if (caller != owner) _spendAllowance(owner, caller, shares);
        _burn(owner, shares);

        // Reduce HWM (principal portion exited)
        // Round in protocol favor: HWM reduction ≤ assets actually withdrawn.
        uint256 hwmReduction = assets > principalHWM ? principalHWM : assets;
        unchecked {
            principalHWM -= hwmReduction;
        }

        // Pull from Morpho, send to user
        MORPHO.withdraw(assets, address(this), address(this));
        USDC.safeTransfer(receiver, assets);

        emit Withdrawn(receiver, assets, shares);
    }

    /// @dev Maintain depositor counter on every balance transition through zero.
    function _update(address from, address to, uint256 value) internal override {
        // Snapshot lottery accrual on both sides BEFORE balance change.
        // (Skipped during mint/burn of zero amounts and address(0) sides.)
        address treasury = WIRING.lotteryTreasury();
        if (treasury != address(0)) {
            if (from != address(0)) ILotteryTreasury(treasury).accrueOnBalanceChange(from);
            if (to != address(0)) ILotteryTreasury(treasury).accrueOnBalanceChange(to);
        }

        super._update(from, to, value);

        // Maintain depositor count (O(1)) — only after balance has updated.
        if (from != address(0) && balanceOf(from) == 0) {
            unchecked {
                depositorCount--;
            }
        }
        if (to != address(0) && balanceOf(to) == value) {
            // means previous balance was 0 → newly counted
            if (depositorCount >= depositorCap) revert DepositorCapReached();
            unchecked {
                depositorCount++;
            }
        }
    }

    /* -------------------------------- yield path ------------------------------ */

    /// @notice Sweeps yield (totalAssets - principalHWM) to LotteryTreasury.
    /// @dev    Reverts if no yield, if HWM would be reduced, or if caller != yieldSweeper.
    /// @dev    The cardinal invariant lives here: principalHWM is monotone except
    ///         on user withdraw. No path in this function reduces it.
    function sweepYield() external nonReentrant onlyYieldSweeper returns (uint256 yieldUsdc) {
        uint256 ta = totalAssets();
        uint256 hwm = principalHWM;
        if (ta <= hwm) revert YieldUnderflow();

        unchecked {
            yieldUsdc = ta - hwm;
        }

        // Withdraw exactly the yield amount from Morpho. Principal stays.
        MORPHO.withdraw(yieldUsdc, address(this), address(this));

        // Forward to LotteryTreasury (and ONLY there).
        address treasury = WIRING.lotteryTreasury();
        USDC.safeTransfer(treasury, yieldUsdc);
        ILotteryTreasury(treasury).creditYield(yieldUsdc);

        lastSweepTimestamp = uint64(block.timestamp);
        emit YieldSwept(yieldUsdc, hwm);
    }

    /* ---------------------------------- pause -------------------------------- */

    function pause() external onlyGuardian {
        paused = true;
        emit Paused(msg.sender, block.timestamp);
    }

    function unpause() external onlyCurator {
        paused = false;
        emit Unpaused(msg.sender, block.timestamp);
    }

    /* ----------------------------------- views ------------------------------- */

    function principalHighWater() external view returns (uint256) {
        return principalHWM;
    }

    function decimals() public view override(ERC4626, ERC20) returns (uint8) {
        return ERC4626.decimals();
    }
}
