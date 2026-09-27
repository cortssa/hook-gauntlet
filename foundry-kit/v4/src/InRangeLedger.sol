// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @title InRangeLedger - who is owed a payout that goes to in-range liquidity: the reference model, and what each
/// party was actually paid, read off the manager
/// @notice A campaign's referee for any hook that pays "whoever is in range" (`HOOK-ATTACKS.md` class 20). It answers
/// the question every amount-conservation invariant skips: not "was the right amount paid" but "was it paid to the
/// right PARTIES". Two columns per party and per currency:
///
///  * ENTITLED - the reference model. The campaign calls `accrue(a0, a1)` at the moment the spec says a payout is EARNED
///    (for `InRangeDonateHook`: after each swap, with the fee that swap paid; for a reward streamed per second: after
///    each interval, with what the interval released). The ledger splits it over the positions in range AT THAT MOMENT,
///    by liquidity - read from the manager (`slot0.tick`, each position's liquidity), and in range meaning v4's
///    `lower <= tick < upper`. Liquidity in range that no tracked position explains (a real pool's other LPs) is the
///    `WORLD`'s share; a payout earned while nothing is in range is `unownedEntitled` - owed to no LP.
///  * RECEIVED - the truth: for every tracked position, what the manager paid it when it was modified (`noteCollected`,
///    the `feesAccrued` the manager returned) plus what it is owed now (`feeGrowthInside` less the position's own
///    `feeGrowthInsideLast`, times its liquidity - v4's own formula). On a pool whose LP fee is 0, every unit of fee
///    growth is a payout: received is exactly what the payouts gave each party, whoever called what.
///
/// The invariant is then one line per party: `received <= entitled + TOLERANCE`. A payout that goes to a position placed
/// after it was earned breaks it for that position's party, however exact every amount is.
///
/// TOLERANCE is 1 wei per party per currency, over the whole campaign, and it is derived, not chosen: a donation of `d`
/// to liquidity `L` raises fee growth by `floor(d * 2^128 / L)`, and a position of liquidity `l` is paid
/// `floor(growth * l / 2^128)` per segment - never more than `d * l / L`; the model keeps its shares in units of 2^-128
/// wei (rounded down, at most 1 unit per accrual per position), so a party paid exactly by the rule is at most
/// `floor(entitled) + 1`.
///
/// A second, EXACT reading of what the positions received, for a check on the TOTAL (`receivedX128`): the manager rounds
/// each position's fees down once per segment (between two modifications); the ledger keeps the part it rounded away, in
/// units of 2^-128 wei, so that "what was given to the pool's liquidity = what its positions received" can be checked to
/// the one remainder no position is ever paid - `d * 2^128 mod L` units of a donation of `d` to liquidity `L`, fewer than
/// `L` - and not to a padded number of wei (`unreceivableBoundX128`). For that it keeps where each position's current
/// segment began (its liquidity and `feeGrowthInsideLast` as the manager last showed them), and checks, on every
/// `noteCollected`, that the manager paid exactly v4's formula over that segment (a mismatch is a `disagreement`).
///
/// It is the reference model, so it must not share the hook's code: it reads the manager and nothing else of the hook.
contract InRangeLedger {
    using StateLibrary for IPoolManager;

    uint256 internal constant Q128 = 1 << 128;
    uint256 public constant TOLERANCE = 1;
    /// @notice the party that stands for untracked liquidity in range (another LP of a real pool)
    address public constant WORLD = address(uint160(uint256(keccak256("InRangeLedger.WORLD"))));

    IPoolManager public immutable manager;
    PoolId public immutable id;
    /// @notice true when every position of the pool is tracked: then the tracked liquidity in range must be the manager's
    bool public immutable closedWorld;

    struct Position {
        address party;
        address owner;
        int24 lower;
        int24 upper;
        bytes32 salt;
        uint256 collected0;
        uint256 collected1;
        uint256 segments;
        // where the current segment began, as the manager last showed the position
        uint128 segLiquidity;
        uint256 segLast0;
        uint256 segLast1;
        // what the manager's rounding kept of the closed segments, in units of 2^-128 wei
        uint256 frac0;
        uint256 frac1;
    }

    Position[] internal _positions;
    address[] internal _parties;
    mapping(address => bool) internal _isParty;
    mapping(address => uint256[2]) internal _entitledX128;
    uint256[2] internal _worldX128;
    uint256[2] internal _unownedEntitled;
    uint256[2] internal _accrued;
    uint256 public accruals;
    /// @notice every increase of a tracked position's liquidity the ledger has seen, summed: in a closed world no
    /// donation ever meets more liquidity in range than this
    uint256 public liquidityEverPlaced;
    /// @notice accruals where the model's in-range liquidity disagreed with the manager's, and modifications where the
    /// manager paid a position other than v4's formula over the ledger's segment (must stay 0)
    uint256 public disagreements;
    string public lastDisagreement;

    constructor(IPoolManager manager_, PoolId id_, bool closedWorld_) {
        manager = manager_;
        id = id_;
        closedWorld = closedWorld_;
    }

    // ------------------------------------------------------------------ positions
    /// @notice follow a position (the same one twice is the same index): `owner` is who the MANAGER sees (a helper, a
    /// position manager), `party` who the campaign counts it for. Call it before the position's first modification or
    /// right after it, and `noteCollected` right after every later one: the ledger reads where the position's segment
    /// begins at each of those moments
    function track(address party, address owner, int24 lower, int24 upper, bytes32 salt) external returns (uint256 i) {
        (bool found, uint256 at) = indexOf(owner, lower, upper, salt);
        if (found) {
            _startSegment(at);
            return at;
        }
        Position storage p = _positions.push();
        p.party = party;
        p.owner = owner;
        p.lower = lower;
        p.upper = upper;
        p.salt = salt;
        p.segments = 1;
        if (!_isParty[party]) {
            _isParty[party] = true;
            _parties.push(party);
        }
        i = _positions.length - 1;
        _startSegment(i);
    }

    /// @dev the position as the manager shows it now is where its next segment begins (it changes only when modified)
    function _startSegment(uint256 i) internal {
        Position storage p = _positions[i];
        (uint128 liq, uint256 last0, uint256 last1) = manager.getPositionInfo(id, p.owner, p.lower, p.upper, p.salt);
        if (liq > p.segLiquidity) liquidityEverPlaced += liq - p.segLiquidity;
        p.segLiquidity = liq;
        p.segLast0 = last0;
        p.segLast1 = last1;
    }

    function indexOf(address owner, int24 lower, int24 upper, bytes32 salt) public view returns (bool, uint256) {
        for (uint256 i = 0; i < _positions.length; i++) {
            Position storage p = _positions[i];
            if (p.owner == owner && p.lower == lower && p.upper == upper && p.salt == salt) return (true, i);
        }
        return (false, 0);
    }

    /// @notice what the manager paid a tracked position when it was modified: the `feesAccrued` it returned. Called right
    /// after the modification: the segment that closed ran from where the ledger last read the position to the
    /// `feeGrowthInsideLast` the manager has just written, at the liquidity the position had before
    function noteCollected(uint256 i, uint256 fees0, uint256 fees1) external {
        Position storage p = _positions[i];
        (, uint256 last0, uint256 last1) = manager.getPositionInfo(id, p.owner, p.lower, p.upper, p.salt);
        uint256 g0;
        uint256 g1;
        unchecked {
            g0 = last0 - p.segLast0;
            g1 = last1 - p.segLast1;
        }
        if (FullMath.mulDiv(g0, p.segLiquidity, Q128) != fees0 || FullMath.mulDiv(g1, p.segLiquidity, Q128) != fees1) {
            disagreements += 1;
            lastDisagreement = "the manager paid a position other than v4's formula over the ledger's segment";
        }
        p.frac0 += mulmod(g0, p.segLiquidity, Q128);
        p.frac1 += mulmod(g1, p.segLiquidity, Q128);
        p.collected0 += fees0;
        p.collected1 += fees1;
        p.segments += 1;
        _startSegment(i);
    }

    function positionCount() external view returns (uint256) {
        return _positions.length;
    }

    function partyCount() external view returns (uint256) {
        return _parties.length;
    }

    function partyAt(uint256 i) external view returns (address) {
        return _parties[i];
    }

    // ------------------------------------------------------------------ the model
    /// @notice the liquidity of position `i` if it is in range now, else 0
    function inRangeLiquidityOf(uint256 i) public view returns (uint128) {
        Position storage p = _positions[i];
        (, int24 tick,,) = manager.getSlot0(id);
        if (tick < p.lower || tick >= p.upper) return 0;
        (uint128 liq,,) = manager.getPositionInfo(id, p.owner, p.lower, p.upper, p.salt);
        return liq;
    }

    /// @notice a payout of `(a0, a1)` is EARNED now: owed to the positions in range now, by liquidity
    function accrue(uint256 a0, uint256 a1) external {
        accruals += 1;
        _accrued[0] += a0;
        _accrued[1] += a1;
        uint256 total = manager.getLiquidity(id);
        uint256 tracked;
        for (uint256 i = 0; i < _positions.length; i++) {
            uint128 l = inRangeLiquidityOf(i);
            if (l == 0) continue;
            tracked += l;
            if (total == 0) continue;
            address party = _positions[i].party;
            _entitledX128[party][0] += FullMath.mulDiv(a0, uint256(l) << 128, total);
            _entitledX128[party][1] += FullMath.mulDiv(a1, uint256(l) << 128, total);
        }
        if (tracked > total || (closedWorld && tracked != total)) {
            disagreements += 1;
            lastDisagreement = "tracked in-range liquidity is not the manager's";
        }
        if (total == 0) {
            _unownedEntitled[0] += a0;
            _unownedEntitled[1] += a1;
            return;
        }
        if (tracked < total) {
            _worldX128[0] += FullMath.mulDiv(a0, (total - tracked) << 128, total);
            _worldX128[1] += FullMath.mulDiv(a1, (total - tracked) << 128, total);
        }
    }

    /// @notice what `party` is owed by the model, in wei (rounded down)
    function entitled(address party) public view returns (uint256 e0, uint256 e1) {
        return (_entitledX128[party][0] >> 128, _entitledX128[party][1] >> 128);
    }

    function worldEntitled() external view returns (uint256 e0, uint256 e1) {
        return (_worldX128[0] >> 128, _worldX128[1] >> 128);
    }

    function unownedEntitled() external view returns (uint256 e0, uint256 e1) {
        return (_unownedEntitled[0], _unownedEntitled[1]);
    }

    function accrued() external view returns (uint256 a0, uint256 a1) {
        return (_accrued[0], _accrued[1]);
    }

    // ------------------------------------------------------------------ the truth
    /// @notice what the manager has paid `party`'s tracked positions: collected on modification plus owed now
    function received(address party) public view returns (uint256 r0, uint256 r1) {
        for (uint256 i = 0; i < _positions.length; i++) {
            if (_positions[i].party != party) continue;
            (uint256 o0, uint256 o1) = owedNow(i);
            r0 += _positions[i].collected0 + o0;
            r1 += _positions[i].collected1 + o1;
        }
    }

    /// @notice what position `i` is owed now and has not collected: v4's own formula, `Position.update`
    function owedNow(uint256 i) public view returns (uint256 o0, uint256 o1) {
        Position storage p = _positions[i];
        (uint128 liq, uint256 last0, uint256 last1) = manager.getPositionInfo(id, p.owner, p.lower, p.upper, p.salt);
        if (liq == 0) return (0, 0);
        (uint256 in0, uint256 in1) = manager.getFeeGrowthInside(id, p.lower, p.upper);
        unchecked {
            o0 = FullMath.mulDiv(in0 - last0, liq, Q128);
            o1 = FullMath.mulDiv(in1 - last1, liq, Q128);
        }
    }

    /// @notice what ALL tracked positions have received, exactly, in units of 2^-128 wei: collected, plus owed now, plus
    /// what the manager's rounding kept of each (closed segments, and the open one). Everything given to the pool's
    /// liquidity is here but the remainders of the donations themselves (`unreceivableBoundX128`) - in a closed world
    function receivedX128() external view returns (uint256 r0, uint256 r1) {
        for (uint256 i = 0; i < _positions.length; i++) {
            (uint256 o0, uint256 o1) = _owedNowX128(i);
            r0 += (_positions[i].collected0 << 128) + _positions[i].frac0 + o0;
            r1 += (_positions[i].collected1 << 128) + _positions[i].frac1 + o1;
        }
    }

    /// @dev what position `i` is owed now, exactly: v4's formula without its rounding, in units of 2^-128 wei
    function _owedNowX128(uint256 i) internal view returns (uint256 o0, uint256 o1) {
        Position storage p = _positions[i];
        (uint128 liq, uint256 last0, uint256 last1) = manager.getPositionInfo(id, p.owner, p.lower, p.upper, p.salt);
        if (liq == 0) return (0, 0);
        (uint256 in0, uint256 in1) = manager.getFeeGrowthInside(id, p.lower, p.upper);
        unchecked {
            in0 -= last0;
            in1 -= last1;
        }
        o0 = (FullMath.mulDiv(in0, liq, Q128) << 128) + mulmod(in0, liq, Q128);
        o1 = (FullMath.mulDiv(in1, liq, Q128) << 128) + mulmod(in1, liq, Q128);
    }

    /// @notice the most that can have been given to the pool's liquidity and received by no position, in units of 2^-128
    /// wei, derived: a donation of `d` to liquidity `L` raises fee growth by `floor(d * 2^128 / L)`, so `d * 2^128 mod L`
    /// units of it (fewer than `L`) are no position's; no donation meets more than `liquidityEverPlaced` in range (closed
    /// world), and there are no more donations per currency than accruals (a third party's is one; the hook's pays a pot
    /// that at least one accrued fee filled). Everything else a position is owed, `receivedX128` counts to the unit
    function unreceivableBoundX128() external view returns (uint256) {
        return accruals * liquidityEverPlaced;
    }

    /// @notice how much more than its entitlement (plus TOLERANCE) `party` received; (0, 0) is the invariant
    function excess(address party) public view returns (uint256 x0, uint256 x1) {
        (uint256 r0, uint256 r1) = received(party);
        (uint256 e0, uint256 e1) = entitled(party);
        if (r0 > e0 + TOLERANCE) x0 = r0 - e0 - TOLERANCE;
        if (r1 > e1 + TOLERANCE) x1 = r1 - e1 - TOLERANCE;
    }

    /// @notice the share of a pot not paid yet that `party` would get if it were donated NOW
    function pendingShare(address party, uint256 pot0, uint256 pot1) public view returns (uint256 s0, uint256 s1) {
        uint256 total = manager.getLiquidity(id);
        if (total == 0) return (0, 0);
        uint256 l;
        for (uint256 i = 0; i < _positions.length; i++) {
            if (_positions[i].party == party) l += inRangeLiquidityOf(i);
        }
        s0 = FullMath.mulDiv(pot0, l, total);
        s1 = FullMath.mulDiv(pot1, l, total);
    }

    /// @notice how much LESS than its entitlement `party` holds once the pending pot is counted, beyond rounding: at most
    /// 1 wei per accrual (one per donation, and every donation carries at least one accrual) plus 1 per segment of each of
    /// its positions (the manager rounds down once per segment) plus 1 for the pending share's own rounding
    function shortfall(address party, uint256 pot0, uint256 pot1) external view returns (uint256 y0, uint256 y1) {
        (uint256 r0, uint256 r1) = received(party);
        (uint256 e0, uint256 e1) = entitled(party);
        (uint256 s0, uint256 s1) = pendingShare(party, pot0, pot1);
        uint256 tol = accruals + 1;
        for (uint256 i = 0; i < _positions.length; i++) {
            if (_positions[i].party == party) tol += _positions[i].segments;
        }
        if (r0 + s0 + tol < e0) y0 = e0 - r0 - s0 - tol;
        if (r1 + s1 + tol < e1) y1 = e1 - r1 - s1 - tol;
    }
}
