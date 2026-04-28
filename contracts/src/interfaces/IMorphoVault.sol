// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice Minimal interface for a Morpho MetaMorpho USDC vault.
///         MetaMorpho is itself an ERC-4626 over the underlying asset.
interface IMorphoVault is IERC4626 {
    function totalSupply() external view returns (uint256);
}
