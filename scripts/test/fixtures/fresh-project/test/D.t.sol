// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {C} from "../src/C.sol";

/// A test-shaped contract, long enough (over 1024 bytes) that its hash takes the multi-block path.
contract DTest {
    function test_bump_01() external {
        C x = new C();
        x.bump();
        require(x.c() == 1, "bump");
    }
    function test_bump_02() external {
        C x = new C();
        x.bump();
        require(x.c() == 1, "bump");
    }
    function test_bump_03() external {
        C x = new C();
        x.bump();
        require(x.c() == 1, "bump");
    }
    function test_bump_04() external {
        C x = new C();
        x.bump();
        require(x.c() == 1, "bump");
    }
    function test_bump_05() external {
        C x = new C();
        x.bump();
        require(x.c() == 1, "bump");
    }
    function test_bump_06() external {
        C x = new C();
        x.bump();
        require(x.c() == 1, "bump");
    }
    function test_bump_07() external {
        C x = new C();
        x.bump();
        require(x.c() == 1, "bump");
    }
    function test_bump_08() external {
        C x = new C();
        x.bump();
        require(x.c() == 1, "bump");
    }
    function test_bump_09() external {
        C x = new C();
        x.bump();
        require(x.c() == 1, "bump");
    }
    function test_bump_10() external {
        C x = new C();
        x.bump();
        require(x.c() == 1, "bump");
    }
    function test_bump_11() external {
        C x = new C();
        x.bump();
        require(x.c() == 1, "bump");
    }
    function test_bump_12() external {
        C x = new C();
        x.bump();
        require(x.c() == 1, "bump");
    }
    function test_bump_13() external {
        C x = new C();
        x.bump();
        require(x.c() == 1, "bump");
    }
    function test_bump_14() external {
        C x = new C();
        x.bump();
        require(x.c() == 1, "bump");
    }
}
