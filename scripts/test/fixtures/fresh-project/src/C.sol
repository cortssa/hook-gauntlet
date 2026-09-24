// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {B} from "./B.sol";

/// C holds a B and counts.
contract C is B {
    uint256 public c;

    function bump() external {
        c += 1;
        b = c * 2;
    }
}
