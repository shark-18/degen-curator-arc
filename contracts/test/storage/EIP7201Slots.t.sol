// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @title EIP7201SlotsTest — verify all UUPS storage slots are canonical
/// @notice This is the C-1 regression test. Hardcoded constants in Wiring,
///         Curator, StrategyExecutor, YieldSweeper MUST match the EIP-7201
///         derivation: keccak256(abi.encode(uint256(keccak256(typeId)) - 1)) & ~bytes32(0xff).
///
/// Run: forge test --match-contract EIP7201Slots -vvv
contract EIP7201SlotsTest is Test {
    function _eip7201Slot(string memory typeId) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(typeId))) - 1)) & ~bytes32(uint256(0xff));
    }

    function test_wiring_slotIsCanonical() public pure {
        bytes32 expected = _eip7201Slot("dcurator.storage.v1.Wiring");
        bytes32 hardcoded = 0x7404cd9655913f01b956677aa7bc7844f80514a7131b4fb3aea0308e1971f600;
        assertEq(hardcoded, expected, "Wiring slot mismatch");
    }

    function test_curator_slotIsCanonical() public pure {
        bytes32 expected = _eip7201Slot("dcurator.storage.v1.Curator");
        bytes32 hardcoded = 0xfbc4302dcd9159449ee3a52fb8c45e89f5f690bf39087c249ca9f861c3119800;
        assertEq(hardcoded, expected, "Curator slot mismatch");
    }

    function test_strategyExecutor_slotIsCanonical() public pure {
        bytes32 expected = _eip7201Slot("dcurator.storage.v1.StrategyExecutor");
        bytes32 hardcoded = 0xb7db1080576884bd91eb2cffb2a77b3c2a30d56a6820ab4b6321c96494eb5e00;
        assertEq(hardcoded, expected, "StrategyExecutor slot mismatch");
    }

    function test_yieldSweeper_slotIsCanonical() public pure {
        bytes32 expected = _eip7201Slot("dcurator.storage.v1.YieldSweeper");
        bytes32 hardcoded = 0x193d56f977557616239c7d9df9908a19015f37b43de560760ebdd8b99e9e0500;
        assertEq(hardcoded, expected, "YieldSweeper slot mismatch");
    }
}
