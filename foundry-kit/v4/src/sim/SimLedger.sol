// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Intent, Fill, KIND_SWAP} from "./ISimAgent.sol";

/// @notice Per-agent books: what each one attempted, filled, was refused, paid in fees, and the gap between what it
/// was quoted and what it got. Written as one line per agent per scenario to the file named by `GAUNTLET_SIM`, in
/// the same spirit as `HandlerBase.writeCensus`: a scenario's numbers must be added up OUTSIDE the run, over
/// several runs, or they are one draw presented as a result.
///
/// Profit and loss are in ONE numeraire: the pool's quote currency (currency1 here). currency0 holdings are valued
/// at the scenario's reference price at the moment of the reading. That is a modelling choice, stated: when both
/// currencies move against the world, a P&L in either of them lies a little, and the dossier says which one was used.
contract SimLedger {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Books {
        uint256 decided;
        uint256 executed;
        uint256 refused;
        uint256 amountInTotal;
        uint256 amountOutTotal;
        uint256 quotedOutTotal;
        uint256 shortfallTotal; // sum over fills of max(quoted - executed, 0): the price of latency
        uint256 windfallTotal; // sum over fills of max(executed - quoted, 0)
        uint256 worstShortfall;
        uint256 gasTotal;
        int256 value0AtStart; // balances at the start, for the P&L reading
        int256 value1AtStart;
        /// @dev swaps the engine did not send because their own quote at decision time was 0 (`REFUSED_AT_QUOTE`): no
        /// gas, never in `refused`. decided = executed + refused + refusedAtQuote + whatever is still in flight.
        uint256 refusedAtQuote;
    }

    mapping(address => Books) public books;

    /// @notice the price of ONE unit of gas, in raw units of the quote currency (currency1), times 1e18. Fixed point
    /// because on most chains one unit of gas is worth far less than one raw unit of quote. With the native coin at 18
    /// decimals it is simply `gas price in wei x raw quote per native coin`: 1 gwei with the coin at 2000.000000 of a
    /// 6-decimal quote is 1e9 * 2e9 = 2e18, i.e. 2 raw quote per gas. Set by the SCENARIO, because only the scenario
    /// knows which chain and which day it models. 0 is a legitimate price (a mock chain), but it must be SAID:
    /// `SimEngine.run` refuses to start, and `pnlNetOfGas` and the dump line refuse to run, until `setGasPrice` was
    /// called, so that a scenario that never thought about gas cannot print a net P&L that silently equals the gross one.
    uint256 public gasPriceQuoteE18;
    bool public gasPriced;

    /// @notice `pnlNetOfGas` (or the dump line) was asked for before the scenario priced gas
    error GasUnpriced();

    /// @notice the books as a struct (the public getter returns a 13-tuple, which is stack-too-deep to unpack without via-IR)
    function get(address agent) external view returns (Books memory) {
        return books[agent];
    }
    address[] public agents;
    mapping(address => string) public nameOf;

    function register(address agent, string memory name, uint256 bal0, uint256 bal1) external {
        agents.push(agent);
        nameOf[agent] = name;
        books[agent].value0AtStart = int256(bal0);
        books[agent].value1AtStart = int256(bal1);
    }

    function noteDecided(Intent memory i) external {
        books[i.agent].decided += 1;
    }

    /// @notice a swap the engine did not send: quoted 0 at decision. Counted apart from `refused`, and no gas.
    function noteRefusedAtQuote(Intent memory i) external {
        books[i.agent].refusedAtQuote += 1;
    }

    function noteFill(Intent memory i, Fill memory f) external {
        Books storage b = books[i.agent];
        b.gasTotal += f.gasUsed;
        if (!f.executed) {
            b.refused += 1;
            return;
        }
        b.executed += 1;
        // The amount columns are about SWAPS. A binding is free to use the other kinds for whatever its system does -
        // a liquidity change, a book join, a whole ladder re-centred - and to report something in `amountOut` that is
        // not an amount at all. Adding those in silently corrupts `amountOutTotal`, and then `windfallTotal` too,
        // because a non-swap carries no quote. Found on a binding whose re-centre reported a COUNT of rungs, which
        // landed in the ledger as 912 units of windfall (2026-09-22).
        if (i.kind != KIND_SWAP) return;
        b.amountInTotal += f.amountInUsed; // what was taken, not what was offered (partial fills refund the rest)
        b.amountOutTotal += f.amountOut;
        b.quotedOutTotal += i.quotedOut;
        if (i.quotedOut > f.amountOut) {
            uint256 s = i.quotedOut - f.amountOut;
            b.shortfallTotal += s;
            if (s > b.worstShortfall) b.worstShortfall = s;
        } else {
            b.windfallTotal += f.amountOut - i.quotedOut;
        }
    }

    /// @notice set the price of gas in quote units (see `gasPriceQuoteE18`); 0 is allowed and means "gas is free here"
    function setGasPrice(uint256 quotePerGasE18) external {
        gasPriceQuoteE18 = quotePerGasE18;
        gasPriced = true;
    }

    /// @notice the agent's gas, every kind and every refusal included, in raw quote units. Rounded UP: a cost rounds
    /// against whoever pays it, so that a strictly positive gas bill at a strictly positive price is never read as 0.
    function gasCost(address agent) public view returns (uint256) {
        if (!gasPriced) revert GasUnpriced();
        uint256 wei_ = books[agent].gasTotal * gasPriceQuoteE18;
        return (wei_ + 1e18 - 1) / 1e18;
    }

    /// @notice `pnl` less what the agent's gas cost at the scenario's price. `pnl` itself is left gross on purpose: it is
    /// the number older readings were taken with, and a reader comparing the two sees exactly what gas took.
    /// Written because an active strategy that re-arranged its position every few steps read as the winner on gross
    /// P&L and as a loser net of its own gas (2026-09-22): the ledger counted the gas and never charged it.
    function pnlNetOfGas(address agent, uint256 bal0, uint256 bal1, uint256 priceX96) public view returns (int256) {
        return pnl(agent, bal0, bal1, priceX96) - int256(gasCost(agent));
    }

    /// @notice P&L of `agent` in the quote currency, valuing currency0 at `priceX96` (quote per custody, Q96).
    function pnl(address agent, uint256 bal0, uint256 bal1, uint256 priceX96) public view returns (int256) {
        Books storage b = books[agent];
        int256 now_ = int256(bal1) + int256(_value(bal0, priceX96));
        int256 then = b.value1AtStart + int256(_value(uint256(b.value0AtStart), priceX96));
        return now_ - then;
    }

    /// @dev amount * price / 2^96 without the product overflowing: a pool parked at the edge of its price range (a partial
    /// fill that hit MAX_SQRT_PRICE) reports a price near 2^224, and amount * price does not fit. Split the price into its
    /// integer and fractional Q96 parts; exact for amounts below 2^128.
    function _value(uint256 amount, uint256 priceX96) internal pure returns (uint256) {
        uint256 hi = priceX96 >> 96;
        uint256 lo = priceX96 & ((uint256(1) << 96) - 1);
        return amount * hi + ((amount * lo) >> 96);
    }

    /// @notice one line per agent: tab separated,
    /// `label  agent  decided  executed  refused  in  out  quoted  shortfall  worst  windfall  gas  pnl  gasCost  pnlNet  atQuote`
    /// where `pnl` is gross, `gasCost` is `gasCost(agent)` and `pnlNet` is `pnlNetOfGas`, both in raw quote units, and
    /// `atQuote` is `refusedAtQuote` (swaps never sent, quoted 0). It is LAST so that a reader of the older 15 columns
    /// still reads the same numbers in the same places; `refused` no longer includes it.
    /// Reverts `GasUnpriced` until the scenario called `setGasPrice` (0 included).
    function line(string memory label, address agent, uint256 bal0, uint256 bal1, uint256 priceX96)
        public
        view
        returns (string memory)
    {
        Books storage b = books[agent];
        string memory a = string.concat(
            label, "\t", nameOf[agent], "\t", vm.toString(b.decided), "\t", vm.toString(b.executed), "\t",
            vm.toString(b.refused), "\t", vm.toString(b.amountInTotal), "\t", vm.toString(b.amountOutTotal)
        );
        string memory c = string.concat(
            "\t", vm.toString(b.quotedOutTotal), "\t", vm.toString(b.shortfallTotal), "\t",
            vm.toString(b.worstShortfall), "\t", vm.toString(b.windfallTotal), "\t", vm.toString(b.gasTotal), "\t",
            vm.toString(pnl(agent, bal0, bal1, priceX96))
        );
        string memory d = string.concat(
            "\t", vm.toString(gasCost(agent)), "\t", vm.toString(pnlNetOfGas(agent, bal0, bal1, priceX96)), "\t",
            vm.toString(b.refusedAtQuote)
        );
        return string.concat(a, c, d);
    }

    /// @notice append the line for `agent` to the file named by `GAUNTLET_SIM`; silent when unset (the everyday
    /// battery writes no files). `scripts/sim-report.sh` adds the lines up over runs.
    function write(string memory label, address agent, uint256 bal0, uint256 bal1, uint256 priceX96) external {
        string memory path = vm.envOr("GAUNTLET_SIM", string(""));
        if (bytes(path).length == 0) return;
        vm.writeLine(path, line(label, agent, bal0, bal1, priceX96));
    }

    function agentCount() external view returns (uint256) {
        return agents.length;
    }
}
