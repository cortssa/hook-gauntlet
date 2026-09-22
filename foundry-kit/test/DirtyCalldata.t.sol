// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice The claim behind "handler actions take full words only" (`HandlerBase._bit`, `doctrine/FUZZ-ACTIONS.md`),
/// turned into a test because a reviewer contested it - which is what this kit says to do with a contested claim.
///
/// The claim: since ABI coder v2 (the default from Solidity 0.8.0), the DECODER of an external function VALIDATES
/// its arguments and REVERTS on a narrow type that arrives with dirty high bits. This is not the "variable cleanup"
/// the language applies to values it computes internally, which masks them silently; it is input validation at the
/// ABI boundary. A coverage-guided fuzzer mutates calldata bytes, so it produces exactly such words.
contract DirtyCalldataTarget {
    function takesBool(uint256 a, bool b) external pure returns (uint256) {
        return b ? a : 0;
    }

    function takesUint8(uint8 x) external pure returns (uint8) {
        return x;
    }

    function takesAddress(address who) external pure returns (address) {
        return who;
    }

    function takesWord(uint256 w) external pure returns (bool) {
        return w & 1 == 1;
    }
}

contract DirtyCalldataTest is Test {
    DirtyCalldataTarget internal t = new DirtyCalldataTarget();

    function _call(bytes4 sel, uint256 w0, uint256 w1, bool two) internal returns (bool ok, bytes memory ret) {
        bytes memory cd = two ? abi.encodePacked(sel, w0, w1) : abi.encodePacked(sel, w0);
        (ok, ret) = address(t).call(cd);
    }

    function test_a_clean_bool_is_accepted() public {
        (bool ok,) = _call(t.takesBool.selector, 7, 1, true);
        assertTrue(ok);
    }

    /// the exact word the fuzzer produced on the day this rule was written
    function test_a_dirty_bool_makes_the_decoder_revert_with_no_data() public {
        (bool ok, bytes memory ret) = _call(t.takesBool.selector, 1e17, 0x28560000, true);
        assertFalse(ok, "the decoder accepted a bool that is neither 0 nor 1");
        assertEq(ret.length, 0, "and it reverts with no data: nothing for a handler's try/catch to classify");
    }

    function test_a_dirty_uint8_makes_the_decoder_revert() public {
        (bool ok,) = _call(t.takesUint8.selector, 0x0100, 0, false);
        assertFalse(ok, "the decoder masked a uint8 instead of rejecting it");
    }

    function test_a_dirty_address_makes_the_decoder_revert() public {
        (bool ok,) = _call(t.takesAddress.selector, uint256(1) << 200, 0, false);
        assertFalse(ok, "the decoder masked an address instead of rejecting it");
    }

    /// and the fix: a full word cannot be malformed, whatever the fuzzer does to it
    function testFuzz_a_full_word_is_always_accepted(uint256 w) public {
        (bool ok,) = _call(t.takesWord.selector, w, 0, false);
        assertTrue(ok);
    }
}
