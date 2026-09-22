// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ToyVault
/// @notice A deliberately tiny contract that exists ONLY to show the harness working. It is not a hook, it is
/// not a product, and it has no planted bugs.
///
/// What it does: wallets hand it tokens by allowance and get a credit; the credit can be withdrawn.
///
/// THE THREAT MODEL, written down BEFORE the fuzz.
/// This is the part of the example that matters. A harness is only as good as the list of things the contract
/// claims to survive, and that list has to exist before the first red run, or it will be written afterwards to
/// match whatever the run happened to do.
///
/// In scope, the vault must survive:
///  1. a `transferFrom` that returns nothing at all, or returns true and moves nothing;
///  2. a token that delivers less than asked, or takes a fee out of the delivery;
///  3. a token that pays the vault a bonus on receipt;
///  4. a token that is paused, or that blocks the vault as a recipient;
///  5. a token whose `balanceOf` reverts or costs a great deal of gas;
///  6. a token that calls back into arbitrary code in the middle of the transfer, in both directions;
///  7. a token that takes more from the vault than it delivers when the vault pays out;
///  8. THE SAME THREE TOKENS ON THE WAY OUT. A `transfer` out of the vault that returns true and moves
///     nothing, or moves half, is the mirror image of case 1 and 2, and the first version of this file
///     defended only the inbound half: `withdraw` bounded the outflow from ABOVE and said nothing about it
///     being too small, so the caller's credit was cleared while the tokens stayed in the vault - owed to
///     nobody, claimable by nobody. Found by an independent audit, not by the fuzz campaign and not by the
///     mutation pass: no operator mutation invents a branch that is missing, and the handler only pointed
///     those switches at the ACTORS, never at the vault itself. The lesson is the general one: write the
///     threat model for both directions of every call, and then check that some action can actually reach
///     each direction.
///
/// Out of scope, declared and not defended:
///  9. a token that lies about the VAULT'S OWN balance. Every line of accounting below is a measured delta of
///     the vault's own balance; a token free to choose that number can make the vault report anything. There
///     is no code fix, only a decision about which tokens are allowed in.
/// 10. a token that does cases 7 and 8 AT THE SAME TIME, in amounts that cancel: it delivers a sixth of the
///     payout and charges the vault the other five sixths as a sender-side burn. The vault's balance falls by
///     exactly `amount`, the check below is satisfied, the credit is cleared - and the caller holds a sixth.
///     The second version of this file claimed the exact check defended case 8. It does not, and cannot: a
///     contract that measures only ITS OWN balance can bound its own loss, in both directions, and can say
///     nothing at all about what arrived at the other end. Guaranteeing delivery means measuring the
///     recipient - a different wallet, with its own lies - or an admission rule for tokens. Found by this
///     kit's own fuzz campaign, once in some four hundred campaigns, during a second review.
///     `test_outOfScope_short_delivery_hidden_by_a_sender_side_burn` pins the behaviour down so that nobody
///     has to rediscover it.
///
/// The three defences, one per line of the model:
///  * measured delta, never the requested amount, is what gets credited (1, 2, 3);
///  * a re-entrancy guard, because the token gets to run attacker code between the two reads (6);
///  * an EXACT outflow check: leaving must cost the vault exactly `amount`, no more and no less. That bounds
///    the VAULT'S loss (7) and refuses every short delivery that shows up in the vault's own balance (8) -
///    which is every one except the combination in line 10. It is a bound on the vault, not proof of delivery.
/// Cases 4 and 5 need no defence: the call fails, and failing is the correct answer.
///
/// A consequence of the exact check, stated so that nobody reads it as a bug: a token that pays the SENDER a
/// rebate makes a payout cost the vault less than the amount, and the vault now REFUSES it. That is the
/// price of the defence. The vault measures its own balance and nothing else; from where it stands, "the
/// token gave me some of it back" and "the token never delivered it" are the same observation, and one of
/// the two loses the caller's money. Refusing both is the only answer available to a contract that cannot
/// tell them apart. A vault that wanted to accept rebates would have to measure the RECIPIENT's balance -
/// which is a different wallet, with its own lies - and that is a different threat model, not a stricter one.
///
/// And one thing that is a DECISION, not a defence: a token that pays the vault a bonus on receipt (case 3)
/// has its bonus credited to whoever made the deposit that triggered it, including a `deposit(0)` from a
/// wallet that never owned a token. What is being handed out is the TOKEN'S reserve, not another user's
/// balance - the vault stays solvent and no depositor can be drained - but it is still somebody's money, and
/// it goes to whoever is at the till. "Credit the measured delta" is the right rule for cases 1 and 2 and it
/// is this giveaway for case 3; a product would have to choose, name the choice, and say who pays.
contract ToyVault {
    address public immutable token;

    /// @notice what each wallet may withdraw, in the token's own units.
    mapping(address => uint256) public credit;
    /// @notice the sum of every credit. The vault is solvent when its balance is at least this.
    uint256 public totalCredit;

    uint256 private _lock;

    error Reentrancy();
    error NothingDelivered();
    error InsufficientCredit();
    error TransferFailed();
    /// @notice leaving the vault cost it something other than the amount the caller asked for: more (a token
    /// that charges the vault to send) or less (a token that delivered short, or nothing at all). Either way
    /// the payout is refused and the caller keeps its credit.
    error PaidOtherThanAsked(uint256 asked, uint256 spent);

    event Deposited(address indexed who, uint256 asked, uint256 credited);
    event Withdrawn(address indexed who, uint256 amount);

    constructor(address token_) {
        token = token_;
    }

    modifier nonReentrant() {
        if (_lock == 1) revert Reentrancy();
        _lock = 1;
        _;
        _lock = 0;
    }

    /// @notice pull `amount` from the caller and credit whatever actually arrived.
    function deposit(uint256 amount) external nonReentrant returns (uint256 credited) {
        uint256 pre = _selfBalance();
        _call(abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), amount));
        uint256 post = _selfBalance();

        if (post <= pre) revert NothingDelivered();
        credited = post - pre;

        credit[msg.sender] += credited;
        totalCredit += credited;
        emit Deposited(msg.sender, amount, credited);
    }

    /// @notice pay `amount` back to the caller, and refuse unless leaving cost the vault exactly that.
    function withdraw(uint256 amount) external nonReentrant {
        uint256 have = credit[msg.sender];
        if (have < amount) revert InsufficientCredit();

        credit[msg.sender] = have - amount;
        totalCredit -= amount;

        uint256 pre = _selfBalance();
        _call(abi.encodeWithSignature("transfer(address,uint256)", msg.sender, amount));
        uint256 post = _selfBalance();

        uint256 spent = pre > post ? pre - post : 0;
        // BOTH directions. `spent > amount` alone is the bug an audit found here: it bounded the leak and
        // left the caller's credit cleared against a delivery that never happened.
        if (spent != amount) revert PaidOtherThanAsked(amount, spent);
        emit Withdrawn(msg.sender, amount);
    }

    function _selfBalance() private view returns (uint256) {
        (bool ok, bytes memory data) =
            token.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
        if (!ok || data.length < 32) revert TransferFailed();
        return abi.decode(data, (uint256));
    }

    /// @dev accepts a token that returns nothing (there are large ones), rejects one that returns false.
    function _call(bytes memory payload) private {
        (bool ok, bytes memory data) = token.call(payload);
        if (!ok) revert TransferFailed();
        if (data.length != 0 && !abi.decode(data, (bool))) revert TransferFailed();
    }
}
