// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {C} from "../src/C.sol";

/// A script-shaped contract: deploys a C and bumps it once, between 240 and 1024 bytes.
contract EScript {
    function run() external returns (C x) {
        x = new C();
        x.bump();
    }
}
