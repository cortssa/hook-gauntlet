// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice ERC-777 style callbacks. A token that calls you back turns every `transferFrom` into a
/// re-entrancy window, which is the single most under-tested property of "just an ERC-20".
interface IHostileTokenCallback {
    /// @notice called BEFORE the balances move, on the sender's behalf.
    function tokensToSend(address from, address to, uint256 amount) external;
    /// @notice called AFTER the balances move, on the recipient's behalf.
    function tokensReceived(address from, address to, uint256 amount) external;
}

/// @title HostileERC20
/// @notice A small ERC-20 for tests whose misbehaviour is switchable AT RUNTIME, per wallet and globally.
///
/// Why runtime switches instead of one mock per behaviour: real attacks are not "a bad token", they are a
/// token that behaves for the first half of a transaction and turns on you in the second half. A mock you
/// pick at construction time can never express that. Every switch here can be flipped in the middle of a
/// test, from inside a callback, or by a stateful-fuzz handler between two calls.
///
/// Accounting rules that make the mock usable as a referee:
///  * nothing is ever destroyed. Fees and extra burns are parked at `FEE_SINK`, so a test closes its books
///    by counting `FEE_SINK` and `RESERVE` as two more holders.
///  * bonuses and rebates are paid out of `RESERVE`, which the test funds with `fundReserve`. If the reserve
///    is short, the mock pays what it has instead of reverting, so a fuzz handler never trips on it.
///  * `trueBalanceOf` is the referee's view: it answers the truth with every switch ignored. NEVER let the
///    contract under test read it. Decide per invariant whether the referee must see the truth or must see
///    exactly what the contract sees, and write that decision down: an invariant that reads the truth while
///    the contract reads a lie will cry wolf on behaviour that is correct by design.
contract HostileERC20 {
    // ------------------------------------------------------------------ ERC-20 state
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) internal _bal;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice where fees and extra burns are parked (never burned, so totals stay closed).
    address public constant FEE_SINK = address(0x0FEE);
    /// @notice the pot that pays bonuses and rebates. Fund it with `fundReserve`.
    address public constant RESERVE = address(0xBA5E);

    /// @notice a gas-burning branch stops here so the call can still return.
    uint256 private constant FRAME_FLOOR = 5_000;

    error BalanceUnreadable(address wallet);
    error RecipientBlocked(address wallet);
    error TransfersPaused();
    error InsufficientBalance(address wallet);
    error InsufficientAllowance(address owner, address spender);
    error Unreachable();

    // ------------------------------------------------------------------ switch storage
    struct ReadSwitch {
        bool revertAlways;
        bool revertAfterMove;
        bool revertWhenRich;
        bool answerMax;
        uint256 gasBurnRounds;
        uint256 understateWhenRichDiv;
        uint256 overstateAfterMove;
        uint256 understateAfterMove;
    }

    struct MoveSwitch {
        bool trueNoMove;
        bool gasHog;
        bool blockIncoming;
        uint256 shortDeliverDiv;
        uint256 bonusIn;
        uint256 rebateOut;
        uint256 extraBurn;
    }

    struct CallerLie {
        address caller;
        uint256 value;
    }

    struct Callback {
        address target;
        uint256 firesLeft;
    }

    mapping(address => ReadSwitch) public readSwitch;
    mapping(address => MoveSwitch) public moveSwitch;
    mapping(address => CallerLie) public callerLie;
    mapping(address => Callback) public sendCallback;
    mapping(address => Callback) public receiveCallback;

    /// @notice true once the wallet has been the sender of a move. Arms the "after a move" switches.
    mapping(address => bool) public hasMoved;

    /// @notice per sender: `transfer` and `transferFrom` return `false`, revert nothing and change nothing.
    mapping(address => bool) public returnsFalse;

    /// @notice global: basis points taken out of every delivery and parked at FEE_SINK.
    uint256 public feeBps;
    /// @notice global: every move reverts.
    bool public paused;
    /// @notice global: `transfer` and `transferFrom` return NO data at all.
    bool public omitReturnValue;
    /// @notice the gas level that separates a "rich" frame from a capped one, for the gas-sensitive switches.
    uint256 public gasThreshold = 100_000;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    // ------------------------------------------------------------------ test plumbing
    /// @notice open mint. Count what you mint if you want a closed-book conservation invariant.
    function mint(address to, uint256 value) external {
        totalSupply += value;
        _bal[to] += value;
        emit Transfer(address(0), to, value);
    }

    /// @notice fills the pot that pays `bonusIn` and `rebateOut`, so those switches invent no tokens.
    function fundReserve(uint256 value) external {
        totalSupply += value;
        _bal[RESERVE] += value;
        emit Transfer(address(0), RESERVE, value);
    }

    /// @notice the referee's view: the truth, with every switch ignored. Never wire this into the contract
    /// under test.
    function trueBalanceOf(address a) external view returns (uint256) {
        return _bal[a];
    }

    function setGasThreshold(uint256 g) external {
        gasThreshold = g;
    }

    // ------------------------------------------------------------------ read-side switches
    /// @notice `balanceOf(w)` always reverts.
    /// Imitates: a token behind an upgradeable proxy that was paused or migrated, or a wallet on a blocklist
    /// whose reads are gated.
    /// A naive contract gets this wrong by treating `balanceOf` as infallible: one unreadable wallet bricks
    /// the whole loop and every other user in it. The fix is a capped, try/catch read with a written policy
    /// for "cannot read".
    function setBalanceRevert(address w, bool on) external {
        readSwitch[w].revertAlways = on;
    }

    /// @notice `balanceOf(w)` answers `type(uint256).max`.
    /// Imitates: tokens with an "infinite balance" mode, broken decimals wrappers, and every mock a careless
    /// integration is tested against.
    /// A naive contract gets this wrong by sizing a transfer from the balance: `max` overflows the next
    /// multiplication, or is accepted as real backing that does not exist.
    function setBalanceMax(address w, bool on) external {
        readSwitch[w].answerMax = on;
    }

    /// @notice `balanceOf(w)` burns `rounds` keccaks and then returns the truth.
    /// Imitates: rebasing and reflection tokens that recompute a share price on every read, and tokens that
    /// walk a fee list.
    /// A naive contract gets this wrong by reading balances inside an unbounded loop: the honest answer
    /// arrives, but the transaction runs out of gas and the user is denied service.
    /// @dev CANCELS `understateWhenRichDiv` and the understating half of the rich family: the burn runs
    /// first and leaves the frame poor, so the "rich" test below it is false. See `balanceOf`'s precedence
    /// list. Use two wallets if you want both.
    function setBalanceGasBurn(address w, uint256 rounds) external {
        readSwitch[w].gasBurnRounds = rounds;
    }

    /// @notice `balanceOf(w)` reverts when it is called with more than `gasThreshold` gas, and answers the
    /// truth under it.
    /// Imitates: nothing benign. This is the shape of a token written to defeat a defensive reader.
    /// A naive contract gets this wrong by assuming that a read which worked once, in a capped probe, will
    /// work again in the full frame where it settles. Probe and settle must read under the SAME cap.
    function setBalanceRevertWhenRich(address w, bool on) external {
        readSwitch[w].revertWhenRich = on;
    }

    /// @notice `balanceOf(w)` answers `balance / div` when called with more than `gasThreshold` gas, and the
    /// truth under it. `div <= 1` disables.
    /// Imitates: nothing benign, same family as `setBalanceRevertWhenRich`, but silent.
    /// A naive contract gets this wrong by never noticing: the capped probe and the uncapped settle disagree
    /// and the difference is quietly absorbed by whoever is not watching.
    function setBalanceUnderstateWhenRich(address w, uint256 div) external {
        readSwitch[w].understateWhenRichDiv = div;
    }

    /// @notice `balanceOf(w)` answers `value` only when `msg.sender == caller`, and the truth to everyone else.
    /// Set `caller` to the zero address to disable.
    /// Imitates: a token that special-cases a known integration address, which is cheap to write and
    /// invisible in a block explorer.
    /// A naive contract gets this wrong by trusting that its own read and an off-chain indexer's read are the
    /// same number. They are the SAME function called by two different addresses.
    function setBalanceLieToCaller(address w, address caller, uint256 value) external {
        callerLie[w] = CallerLie(caller, value);
    }

    /// @notice `balanceOf(w)` works until `w` has sent tokens once, and reverts from then on.
    /// Imitates: a token that arms a blocklist on first use, or a share token that deletes an account once it
    /// empties.
    /// A naive contract gets this wrong by reading a balance before an action and again after it, and
    /// treating the second read as a formality. The second read is where the attacker lives.
    function setBalanceRevertAfterMove(address w, bool on) external {
        readSwitch[w].revertAfterMove = on;
    }

    /// @notice once `w` has moved tokens, `balanceOf(w)` reads `balance + extra`, so the DROP looks smaller
    /// than it was. No tokens are invented, only the view lies.
    /// Imitates: a share-based token that rounds the holder's view in the holder's favour.
    /// A naive contract gets this wrong by computing "what was delivered" as `before - after` on the SENDER
    /// instead of on the recipient: it under-counts the delivery and hands out the difference.
    /// @dev WINS over `understateAfterMove` on the same wallet: a non-zero overstate returns before the
    /// understate is read. They are not summed. See `balanceOf`'s precedence list.
    function setViewOverstateAfterMove(address w, uint256 extra) external {
        readSwitch[w].overstateAfterMove = extra;
    }

    /// @notice once `w` has moved tokens, `balanceOf(w)` reads `balance - missing`, so the DROP looks bigger
    /// than it was.
    /// Imitates: a share-based token that rounds the holder's view against the holder, or a token that
    /// reserves an exit fee in the view before charging it.
    /// A naive contract gets this wrong by crediting the sender's apparent loss: it over-counts the delivery
    /// and becomes insolvent by the difference.
    /// @dev IGNORED whenever `overstateAfterMove` is non-zero on the same wallet. See `balanceOf`.
    function setViewUnderstateAfterMove(address w, uint256 missing) external {
        readSwitch[w].understateAfterMove = missing;
    }

    // ------------------------------------------------------------------ write-side switches
    /// @notice transfers FROM `w` return `false`: no revert, nothing moves, no allowance is spent, no event, no
    /// callback. Checked before every other switch, and it wins over the global ones: a paused token still says
    /// `false` instead of reverting, and `omitReturnValue` does not hide it (a real 32-byte `false` comes back).
    /// Imitates: the early ERC-20s that report failure by returning `false` instead of reverting - an insufficient
    /// balance or allowance answered with a boolean.
    /// A naive contract gets this wrong by calling `transfer` or `transferFrom` and not reading what it returned: it
    /// credits a deposit that never arrived. It is the only switch that reaches a caller's
    /// `if (!token.transfer(...)) revert` branch; with the others that branch is dead code, and a test suite could
    /// delete it and stay green.
    function setReturnsFalse(address w, bool on) external {
        returnsFalse[w] = on;
    }

    /// @notice transfers FROM `w` move nothing and return true.
    /// Imitates: the classic "returns true and does nothing" token, and any token whose transfer is a no-op
    /// for blocked or zero-fee accounts.
    /// A naive contract gets this wrong by believing the return value. The only thing a caller may believe is
    /// the change in its own balance, measured before and after.
    function setTrueNoMove(address w, bool on) external {
        moveSwitch[w].trueNoMove = on;
    }

    /// @notice transfers FROM `w` burn the whole gas frame they were given, move nothing, and return true.
    /// Imitates: a token designed to make a defensive caller fail rather than skip it.
    /// A naive contract gets this wrong by calling an unknown token with all its remaining gas: the token
    /// eats the frame and the caller dies after the point of no return. Cap the gas of every call into an
    /// unknown token, and decide what "it ate my frame" means before it happens.
    function setGasHogTransfer(address w, bool on) external {
        moveSwitch[w].gasHog = on;
    }

    /// @notice global fee in basis points, taken out of every delivery and parked at FEE_SINK. The sender
    /// loses exactly what it asked to send; the recipient receives less.
    /// Imitates: fee-on-transfer tokens, which are most of the long tail.
    /// A naive contract gets this wrong by crediting the recipient with the amount it ASKED to move. Credit
    /// the recipient's measured delta, or refuse fee-on-transfer tokens in writing.
    function setFeeBps(uint256 bps) external {
        require(bps <= 10_000, "HostileERC20: fee over 100 percent");
        feeBps = bps;
    }

    /// @notice transfers FROM `w` deliver `amount / div` and debit the sender only that much. `div <= 1`
    /// disables. The token simply moved less than it was asked to, and said nothing.
    /// Imitates: tokens with a transfer cap, a partial-fill mode, or a broken decimals conversion.
    /// A naive contract gets this wrong by assuming `transferFrom(x)` means x arrived. It also gets the
    /// ALLOWANCE wrong: the full `amount` is spent, the partial delivery is not refunded.
    function setShortDeliver(address w, uint256 div) external {
        moveSwitch[w].shortDeliverDiv = div;
    }

    /// @notice every transfer INTO `w` pays `extra` more to `w`, out of RESERVE.
    /// Imitates: reflection and rewards tokens that pay the recipient a share on receipt.
    /// A naive contract gets this wrong when it is itself the recipient: its measured delta is larger than
    /// what the sender lost, and any rule of the form "credit the delta" hands the difference to whoever
    /// happens to be at the till - including a caller who deposits ZERO and is credited the bonus. Note the
    /// tension, because it is real and it has no general answer: "credit the measured delta" is the right
    /// rule against the two tokens above and the wrong one here, and `src/examples/ToyVault.sol` names it as
    /// a decision with a payer rather than pretending its defence covers this case.
    function setBonusTo(address w, uint256 extra) external {
        moveSwitch[w].bonusIn = extra;
    }

    /// @notice every transfer FROM `w` gives `refund` back to `w`, out of RESERVE. The sender gave less than
    /// it looked like it gave.
    /// Imitates: reflection tokens that pay the sender its own share of the fee it just paid.
    /// A naive contract gets this wrong by pricing the trade off the sender's loss. Two different numbers,
    /// "what the sender lost" and "what the recipient gained", stop being the same number here, and every
    /// rule has to name which one it means.
    function setRebateFrom(address w, uint256 refund) external {
        moveSwitch[w].rebateOut = refund;
    }

    /// @notice every transfer FROM `w` takes `extra` MORE from `w` than it delivers, parked at FEE_SINK.
    /// Imitates: a token that charges an exit fee on top of the amount, or slashes on transfer.
    /// A naive contract gets this wrong by checking "does the sender still have enough for the next step"
    /// with arithmetic instead of a second read: the sender is poorer than the subtraction says.
    function setExtraBurnFrom(address w, uint256 extra) external {
        moveSwitch[w].extraBurn = extra;
    }

    /// @notice every transfer INTO `w` reverts.
    /// Imitates: a blocklist (the large centralised stablecoins all have one).
    /// A naive contract gets this wrong by pushing tokens to an address it does not control inside a path
    /// that must not fail: one blocked recipient denies service to everyone in the same call. Prefer pull
    /// over push, or isolate the failure.
    function setBlockIncoming(address w, bool on) external {
        moveSwitch[w].blockIncoming = on;
    }

    /// @notice global: every move reverts.
    /// Imitates: a pausable token, which is most tokens with an admin.
    /// A naive contract gets this wrong by having no answer for "the asset froze while I held a position".
    function setPaused(bool on) external {
        paused = on;
    }

    /// @notice global: `transfer` and `transferFrom` return NO data.
    /// Imitates: the pre-EIP-20-finalisation tokens that never returned a bool, of which the largest stablecoin
    /// by volume is one.
    /// A naive contract gets this wrong in BOTH directions: a raw `IERC20.transfer(...)` reverts on the empty
    /// return data, and a bare `call` that ignores the return data accepts a token that returned `false`.
    function setOmitReturnValue(bool on) external {
        omitReturnValue = on;
    }

    // ------------------------------------------------------------------ callback switches
    /// @notice before the balances move, the token calls `target.tokensToSend(from, to, amount)` on behalf of
    /// sender `w`, at most `fires` times. `fires = 0` disables.
    /// Imitates: ERC-777 and every ERC-20 with a transfer hook.
    /// A naive contract gets this wrong by treating `transferFrom` as an atomic, inert step. It is a call into
    /// attacker code, placed exactly between your "before" read and your "after" read.
    function setSendCallback(address w, address target, uint256 fires) external {
        sendCallback[w] = Callback(target, fires);
    }

    /// @notice after the balances move, the token calls `target.tokensReceived(from, to, amount)` on behalf of
    /// recipient `w`, at most `fires` times. `fires = 0` disables.
    /// Imitates: ERC-777 recipient hooks.
    /// A naive contract gets this wrong by doing its bookkeeping AFTER the transfer: the recipient hook runs
    /// first and observes a state that the contract still believes is private.
    function setReceiveCallback(address w, address target, uint256 fires) external {
        receiveCallback[w] = Callback(target, fires);
    }

    // ------------------------------------------------------------------ ERC-20 surface
    /// @notice THE PRECEDENCE OF THE READ SWITCHES, because several of them can be on at once and the order
    /// below decides which one wins. It is documented rather than made to compose, because a switchboard
    /// that silently combines two lies is harder to reason about than one that states its order - but two
    /// of these combinations CANCEL, and a test that turns both on and expects both is testing neither:
    ///
    ///  1. `revertAlways`, then `revertAfterMove`, then `revertWhenRich` - a revert ends the question;
    ///  2. `gasBurnRounds` - the burn happens HERE, before the "rich" tests below it read `gasleft()`.
    ///     **This is the cancellation.** `gasBurnRounds` with `understateWhenRichDiv` (or with
    ///     `revertWhenRich`) spends the caller's frame down past `gasThreshold`, so the rich test is false
    ///     and the lie never happens. Measured: 400 rounds costs about 80 000 gas, and a 150 000-gas frame
    ///     that was told 100 with the lie alone is told the truth, 1 000, with the burn on as well. The
    ///     `revertWhenRich` check above it is NOT affected - it runs before the burn;
    ///  3. `callerLie` - beats everything below it, including `answerMax`;
    ///  4. `answerMax`;
    ///  5. `understateWhenRichDiv`, if the frame is still rich after step 2;
    ///  6. after a move, `overstateAfterMove` **and then** `understateAfterMove`. **This is the second
    ///     cancellation**: a non-zero overstate returns before the understate is ever read, so setting both
    ///     silently applies only the overstate. They are not summed, and setting both is a test-writing
    ///     mistake rather than a hostile mode.
    ///
    /// If you want two of these at once, use two wallets. If you want them summed, change this function and
    /// its tests together - the switches exist to be understood, not to be stacked.
    function balanceOf(address a) public view virtual returns (uint256) {
        ReadSwitch storage r = readSwitch[a];
        if (r.revertAlways) revert BalanceUnreadable(a);
        if (r.revertAfterMove && hasMoved[a]) revert BalanceUnreadable(a);
        if (r.revertWhenRich && gasleft() > gasThreshold) revert BalanceUnreadable(a);
        if (r.gasBurnRounds > 0) _burnRounds(r.gasBurnRounds);

        CallerLie storage lie = callerLie[a];
        if (lie.caller != address(0) && msg.sender == lie.caller) return lie.value;
        if (r.answerMax) return type(uint256).max;

        uint256 b = _bal[a];
        if (r.understateWhenRichDiv > 1 && gasleft() > gasThreshold) return b / r.understateWhenRichDiv;
        if (hasMoved[a]) {
            if (r.overstateAfterMove > 0) return b + r.overstateAfterMove;
            uint256 missing = r.understateAfterMove;
            if (missing > 0) return b > missing ? b - missing : 0;
        }
        return b;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        if (returnsFalse[msg.sender]) return false;
        _move(msg.sender, to, value);
        _maybeOmitReturn();
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        if (returnsFalse[from]) return false;
        uint256 a = allowance[from][msg.sender];
        if (a < value) revert InsufficientAllowance(from, msg.sender);
        if (a != type(uint256).max) allowance[from][msg.sender] = a - value;
        _move(from, to, value);
        _maybeOmitReturn();
        return true;
    }

    // ------------------------------------------------------------------ the move itself
    function _move(address from, address to, uint256 value) internal virtual {
        if (paused) revert TransfersPaused();

        MoveSwitch storage mf = moveSwitch[from];
        if (mf.gasHog) {
            _burnFrame();
            return;
        }
        if (moveSwitch[to].blockIncoming) revert RecipientBlocked(to);
        if (mf.trueNoMove) return;

        _fire(sendCallback[from], from, to, value, true);

        uint256 debit = value;
        if (mf.shortDeliverDiv > 1) debit = value / mf.shortDeliverDiv;

        uint256 fee = feeBps > 0 ? debit * feeBps / 10_000 : 0;
        uint256 delivered = debit - fee;

        uint256 extra = mf.extraBurn;
        if (_bal[from] < debit + extra) revert InsufficientBalance(from);

        _bal[from] -= debit + extra;
        _bal[to] += delivered;
        emit Transfer(from, to, delivered);

        if (fee > 0) {
            _bal[FEE_SINK] += fee;
            emit Transfer(from, FEE_SINK, fee);
        }
        if (extra > 0) {
            _bal[FEE_SINK] += extra;
            emit Transfer(from, FEE_SINK, extra);
        }

        hasMoved[from] = true;

        uint256 bonus = moveSwitch[to].bonusIn;
        if (bonus > 0) _payFromReserve(to, bonus);
        uint256 rebate = mf.rebateOut;
        if (rebate > 0) _payFromReserve(from, rebate);

        _fire(receiveCallback[to], from, to, value, false);
    }

    /// @dev pays at most what the reserve holds, so a fuzz handler never trips on an empty pot.
    function _payFromReserve(address to, uint256 want) private returns (uint256 paid) {
        uint256 have = _bal[RESERVE];
        paid = want > have ? have : want;
        if (paid == 0) return 0;
        _bal[RESERVE] -= paid;
        _bal[to] += paid;
        emit Transfer(RESERVE, to, paid);
    }

    function _fire(Callback storage cb, address from, address to, uint256 value, bool sending) private {
        if (cb.target == address(0) || cb.firesLeft == 0) return;
        cb.firesLeft -= 1;
        if (sending) IHostileTokenCallback(cb.target).tokensToSend(from, to, value);
        else IHostileTokenCallback(cb.target).tokensReceived(from, to, value);
    }

    /// @dev A gas-burning loop only burns gas if the compiler cannot remove it, and a compiler removes any
    /// loop whose result nothing observes. Here the digest is observed by the conditional revert below, which
    /// is why that apparently pointless line is load bearing. Measured with solc 0.8.26, optimizer on:
    /// 400 rounds cost about 80 000 gas, so roughly 200 gas a round.
    function _burnRounds(uint256 rounds) private view {
        bytes32 h = bytes32(gasleft());
        for (uint256 i = 0; i < rounds; i++) h = keccak256(abi.encode(h, i));
        if (uint256(h) == 1) revert Unreachable();
    }

    /// @dev Eats everything down to FRAME_FLOOR, which is just enough to return.
    ///
    /// A warning for whoever writes the test. You cannot check that this worked by reading `gasleft()` before
    /// and after the call in the test contract: under Foundry that difference does not track what the callee
    /// spent. Measured here, a call given 199 776 gas left the callee with 4 838, and the test frame reported
    /// 8 236 gas consumed. Test the CONSEQUENCE instead: give a caller a frame, let it call the token, and
    /// check that the caller can no longer finish its own work.
    function _burnFrame() private view {
        bytes32 h;
        while (gasleft() > FRAME_FLOOR) h = keccak256(abi.encode(h, gasleft()));
        if (uint256(h) == 1) revert Unreachable();
    }

    /// @dev returns with empty return data, after the state change, when `omitReturnValue` is on.
    function _maybeOmitReturn() private view {
        if (!omitReturnValue) return;
        assembly {
            return(0, 0)
        }
    }
}
