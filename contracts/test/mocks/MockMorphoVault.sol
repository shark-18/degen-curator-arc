// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {MockUSDC} from "./MockUSDC.sol";

/// @title MockMorphoVault — minimal ERC-4626 mock with simulateable yield
contract MockMorphoVault is ERC4626 {
    constructor(address _usdc)
        ERC4626(IERC20(_usdc))
        ERC20("Mock Morpho USDC", "mmUSDC")
    {}

    /// @notice Simulate Morpho earning yield by minting USDC to ourselves.
    ///         The recipient parameter doesn't matter — the yield accrues to
    ///         the vault's USDC balance, raising pricePerShare for all holders.
    function simulateYield(uint256 amount, address /*recipient*/) external {
        if (amount == 0) return;
        MockUSDC(asset()).mint(address(this), amount);
    }
}
