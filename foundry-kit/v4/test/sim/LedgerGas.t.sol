// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SimLedger} from "../../src/sim/SimLedger.sol";
import {Intent, Fill, KIND_SWAP} from "../../src/sim/ISimAgent.sol";

/// @notice Gas is a cost, and a ledger that counts it without charging it ranks strategies by their gross P&L. An
/// active strategy that moves its position every few steps pays for every move; a passive one pays for none. Read
/// gross, the active one looked like the winner; net of its own gas it lost in most runs (2026-09-22, on a binding).
/// This talks to the ledger directly: the number under test is arithmetic, and no scenario should be able to hide it.
contract LedgerGas is Test {
    SimLedger ledger;
    address constant AGENT = address(0x6A5);
    uint256 constant Q96 = 1 << 96;

    function setUp() public {
        ledger = new SimLedger();
        ledger.register(AGENT, "agent", 10, 1_000);
        Intent memory it;
        it.agent = AGENT;
        it.kind = KIND_SWAP;
        Fill memory f;
        f.executed = false; // a refusal: it costs gas all the same
        f.gasUsed = 3_000_000;
        ledger.noteFill(it, f);
    }

    function test_gas_at_a_positive_price_is_charged_against_the_pnl() public {
        // 2 raw quote per unit of gas: 3e6 gas cost 6e6 raw quote
        ledger.setGasPrice(2e18);
        int256 gross = ledger.pnl(AGENT, 10, 1_500, Q96);
        int256 net = ledger.pnlNetOfGas(AGENT, 10, 1_500, Q96);
        assertEq(gross, 500);
        assertLt(net, gross, "gas was counted and not charged");
        assertEq(net, 500 - 6_000_000, "the charge is not gasTotal x price");
        assertEq(ledger.gasCost(AGENT), 6_000_000);
    }

    function test_a_fractional_price_is_never_rounded_to_free() public {
        // 1e-9 raw quote per gas: 3e6 gas cost 0.003 raw, which rounds UP to 1 - a cost rounds against its payer
        ledger.setGasPrice(1e9);
        assertEq(ledger.gasCost(AGENT), 1);
        assertLt(ledger.pnlNetOfGas(AGENT, 10, 1_500, Q96), ledger.pnl(AGENT, 10, 1_500, Q96));
    }

    function test_at_price_zero_net_equals_gross() public {
        ledger.setGasPrice(0);
        assertEq(ledger.gasCost(AGENT), 0);
        assertEq(ledger.pnlNetOfGas(AGENT, 10, 1_500, Q96), ledger.pnl(AGENT, 10, 1_500, Q96));
    }

    function test_an_unpriced_ledger_refuses_to_print_a_net_pnl() public {
        vm.expectRevert(SimLedger.GasUnpriced.selector);
        ledger.pnlNetOfGas(AGENT, 10, 1_500, Q96);
        vm.expectRevert(SimLedger.GasUnpriced.selector);
        ledger.line("x", AGENT, 10, 1_500, Q96);
    }

    function test_the_dump_line_carries_gas_cost_and_net_pnl() public {
        ledger.setGasPrice(2e18);
        string memory l = ledger.line("x", AGENT, 10, 1_500, Q96);
        // the last two columns: gasCost, pnlNet
        assertTrue(_endsWith(l, "\t500\t6000000\t-5999500"), "the dump line does not end with pnl, gasCost, pnlNet");
    }

    function _endsWith(string memory s, string memory suffix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(suffix);
        if (b.length > a.length) return false;
        for (uint256 i = 0; i < b.length; i++) {
            if (a[a.length - b.length + i] != b[i]) return false;
        }
        return true;
    }
}
