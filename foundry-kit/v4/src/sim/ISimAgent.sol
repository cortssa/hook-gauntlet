// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice What an agent sees when it is asked to act: the clock, and the markets it may trade.
/// Deliberately small. An agent that wants more (the book, other agents' positions) asks the scenario for it
/// explicitly, so that the dossier can list what each agent was allowed to know.
struct SimView {
    uint256 step; // the scenario's step counter (one step = one L2 block of the clock)
    uint256 l2Block; // the chain's own block number, as the sequencer counts it
    uint256 l1BlockEstimate; // what `block.number` returns on this chain (an L1 estimate on an Orbit-style L2)
    uint256 timestamp;
    uint160 sqrtPriceX96; // the price of the venue under test (venue 0)
    uint160 mainSqrtPriceX96; // the price of the main market (venue 1), if the scenario has one; else 0
}

/// @dev Which market an intent is for. 0 is always the venue under test (the hook's pool). 1 is the main market
/// when the scenario has one - the plain pool where the token "really" trades, pushed by the world's traders, and the
/// place a stale quote on venue 0 is stale AGAINST.
uint8 constant VENUE_UNDER_TEST = 0;
uint8 constant VENUE_MAIN = 1;

/// @dev What an intent does. A swap is quoted and has a slippage rule; a liquidity change is executed as given and
/// has neither (its "quote" is 0 and its `minOut` is 0). The ledger counts both as decided / executed / refused.
uint8 constant KIND_SWAP = 0;
uint8 constant KIND_ADD_LIQUIDITY = 1;
uint8 constant KIND_REMOVE_LIQUIDITY = 2;

/// @notice A trading intent: "swap `amountIn` of one side for the other on `venue`, and refuse less than `minOut`".
/// The scenario quotes it at the step it is decided and executes it `latency` steps later - that gap is the whole
/// point of the sandbox.
struct Intent {
    address agent;
    uint8 venue;
    uint8 kind; // KIND_SWAP, KIND_ADD_LIQUIDITY, KIND_REMOVE_LIQUIDITY
    bool zeroForOne; // swaps only
    uint256 amountIn; // swaps only
    /// @dev the UNIT of `amountIn`. false (the default) = `amountIn` is in the input currency, whichever way the swap
    /// goes. true = the agent sized this swap in currency1 (quote): a binding that supports it converts `amountIn` at
    /// its reference price when the input is currency0, and a binding that does not must refuse the intent loudly,
    /// never execute it as if it were false. The unit belongs to the intent because only the agent knows it: an
    /// arbitrageur's closing leg sells exactly what its opening leg bought - currency0, not quote - and a binding that
    /// guessed "every sell is quote-sized" converted that amount a second time (measured on a binding, 2026-09-22:
    /// every closing leg asked for ~10^12 times the wallet and was refused).
    ///
    /// NORMATIVE - what a binding does with `amountIn`, per case (currency1 is the quote):
    ///
    ///   amountInQuote | zeroForOne | input currency | amountIn is in | the binding
    ///   --------------+------------+----------------+----------------+-----------------------------------------------
    ///   false         | true       | currency0      | currency0      | uses it as is
    ///   false         | false      | currency1      | currency1      | uses it as is
    ///   true          | false      | currency1      | currency1      | uses it as is (quote-sized AND quote-input)
    ///   true          | true       | currency0      | currency1      | converts at its reference price, or REFUSES the
    ///                 |            |                |                | intent loudly - never uses it as is
    ///
    /// Only the last row differs, and it is the one a binding gets wrong in silence. `ExampleScenario` refuses it
    /// (`QuoteSizedIntentUnsupported`); `test/sim/BindingContract.t.sol` holds it to all four rows.
    bool amountInQuote; // swaps only
    int24 tickLower; // liquidity only
    int24 tickUpper; // liquidity only
    int256 liquidityDelta; // liquidity only: positive to add, negative to remove
    uint256 maxSlippageBps; // the agent's slippage rule: the scenario turns it into `minOut` from the quote (10000 = no rule)
    uint256 minOut; // filled in by the scenario: quotedOut less the tolerance; a fill below it is REFUSED, as a router would
    uint256 decidedAtStep;
    uint256 executeAtStep;
    uint256 quotedOut; // filled in by the scenario at decision time
    uint256 seq; // submission order, the FCFS tiebreak
}

/// @notice What came back.
struct Fill {
    bool executed; // false = reverted (price limit, minOut, liquidity gone)
    uint256 amountOut;
    /// @dev the input ACTUALLY taken. A venue that fills part of an order and refunds the rest (a book with a price bound, a
    /// v4 swap that hits its limit) takes less than the intent offered; the ledger counts this, never `Intent.amountIn`.
    /// A binding sets it on every executed fill; the engine refuses a swap fill that left it at zero. A swap that was SENT and
    /// took nothing (the book side emptied between the quote and the fill) is not an executed fill: `executed = false`,
    /// `revertSelector = FILLED_NOTHING`, and the ledger counts it in `refused`.
    uint256 amountInUsed;
    uint24 feeCharged; // read from the manager's Swap event
    uint256 gasUsed;
    bytes4 revertSelector; // when !executed; `REFUSED_AT_QUOTE` when the engine never sent it, `FILLED_NOTHING` when it took nothing
}

/// @dev The `Fill.revertSelector` of a swap the ENGINE did not send: its own quote at decision time was 0. A bot that
/// reads its quote does not pay gas to buy nothing, so the engine does not execute it, charges no gas, and settles it
/// at once with `executed == false` and this marker. The ledger counts it apart (`SimLedger.Books.refusedAtQuote`), never
/// as a `refused` - that column is for what was sent and came back empty. Swaps only: every other kind carries no quote.
/// Written after a binding's agents sent 841 swaps quoted 0 on a fork and all 841 came back empty, ~250 000 gas each
/// (2026-09-22): the ledger read them as a market that refused, when the agent had been told "nothing" and sent anyway.
bytes4 constant REFUSED_AT_QUOTE = bytes4(keccak256("RefusedAtQuote()"));

/// @notice An agent is a contract with a wallet. Three verbs, in this order, every step:
///   observe(view)  - look (the scenario passes what it may see)
///   decide()       - return an intent, or none
///   settle(fill)   - learn what happened to an earlier intent
/// The split is the collector / strategy / executor shape of off-chain bots, as an interface, so that a dossier
/// can say per agent what it observed, how it decided, and what it did about the result.
interface ISimAgent {
    function name() external view returns (string memory);
    /// @notice how many steps (L2 blocks) pass between this agent deciding and its intent reaching the sequencer
    function latency() external view returns (uint256);

    function observe(SimView calldata v) external;
    function decide() external returns (bool wants, Intent memory intent);
    function settle(Intent calldata intent, Fill calldata fill) external;
}

/// @notice The capability that only exists under BUNDLE ordering: seeing an intent that is about to execute and
/// placing your own immediately before and after it. That is what a block builder, or a searcher with a builder's
/// ear, can do on a chain with a public mempool or private bundles - and what NOBODY can do on a first-come-first-
/// served sequencer. An agent that implements this is a searcher. The engine asks it twice per victim intent:
///   wrap(victim)    before the victim executes: the intents to run in front of it (quoted now, latency zero)
///   unwind(victim, fill)  after the victim executed: the intents to run behind it - by then the searcher knows
///                   what its front-run bought, which is what a back-run sells
/// Both lists may be empty: abstaining is a decision, and the ledger counts it as one (nothing decided, nothing lost).
interface ISimSearcher {
    function wrap(Intent calldata victim, SimView calldata v) external returns (Intent[] memory before_);
    function unwind(Intent calldata victim, Fill calldata victimFill, SimView calldata v)
        external
        returns (Intent[] memory after_);
}

/// @dev The `Fill.revertSelector` of a swap that was SENT (its quote was not 0) and TOOK NOTHING: the side it was quoted
/// against emptied between the quote and the fill - another order took the book, a maker cancelled, a range was
/// withdrawn. That is a market outcome, not a binding error, and the binding reports it as such: `executed == false`,
/// this marker, `amountIn(Used)` and `amountOut` 0, and the gas it paid (it was sent). The ledger counts it in `refused`,
/// never in `refusedAtQuote` (that one was never sent). What a binding must NOT do is report `executed == true` with no
/// input taken: the engine reverts `SimEngine.FillWithoutInput`, because that is also what a binding that forgot
/// `amountInUsed` looks like. Written after both arms of a blind run (2026-09-23) aborted a whole simulation on a book
/// that legitimately filled nothing. `test/sim/FilledNothing.t.sol`.
bytes4 constant FILLED_NOTHING = bytes4(keccak256("FilledNothing()"));
