// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ExchangeBase} from "./ExchangeBase.sol";
import {MakoOutcomeExchangeV1 as X} from "../../src/MakoOutcomeExchangeV1.sol";
import {MockUSDC} from "../mocks/TokenMocks.sol";

/// @notice The fuzzer's only door into the exchange for `Invariants.t.sol`: four wallets with keys, one operator, the
/// admin (this contract's creator), two markets, and one action per thing a party, the operator, the admin or anyone can do.
/// Every action that succeeds is checked against an independent computation of what it must change (the ghost flags),
/// every action that must succeed (the pause-proof ones) is checked to succeed, and every wallet outside an action is
/// checked untouched (X9). A violation sets a flag; the invariant contract reads the flags after every call.
contract ExchangeHandler is ExchangeBase {
    uint256 internal constant N = 4;
    uint8 internal constant UNWIND = 255;

    address[N] internal who;
    uint256[2] public mk; // market ids: [0] three options, fee 700; [1] two options, fee 100
    uint16[2] internal rate;

    // ---- ghost flags: any true means an invariant broke ----
    bool public gMoney; // X3, X4, X5, X18, X20 and X9: a successful action changed something other than what it must
    bool public gClosed; // X6: a fill or a mint succeeded after tradingClose, while paused, or after finalization
    bool public gPauseProof; // X10: withdraw, merge, cancel, redeem or finalize refused while it was valid
    bool public gStatus; // X8: status moved backwards or a final outcome changed
    bool public gBackstop; // X11, X19
    bool public gUnwind; // X16
    bool public gRelease; // X17
    bool public gOperatorOnly; // O4
    bool public gCancelOnly; // X7: a stranger cancelled, or a cancel changed more than the flag
    bool public gFilled; // O1
    bool public gNonceCancel; // O3: a cancelled or old-nonce order filled

    // ---- trackers ----
    X.Order[] internal seen;
    mapping(bytes32 => uint128) internal lastFilled;
    mapping(bytes32 => bool) internal wasCancelled;
    uint8[2] internal lastStatus;
    uint8[2] internal lastFinal;
    uint64[2] internal initClose;
    mapping(uint256 => mapping(uint256 => bool)) internal redeemedAfterUnwind;
    uint256 public successfulMatches;
    uint256 public successfulSets;
    uint256 public successfulMerges;

    constructor() {
        setUp();
        vm.warp(1_700_000_000);
        rate[0] = 700;
        rate[1] = 100;
        mk[0] = _marketCap(3, 700, CAP);
        mk[1] = _marketCap(2, 100, CAP);
        for (uint256 i; i < 2; ++i) {
            lastStatus[i] = 1;
            initClose[i] = ex.marketOf(mk[i]).tradingClose;
        }
        for (uint256 i; i < N; ++i) {
            (, address a) = _party(string.concat("hx", vm.toString(i)), mk[0], 5_000e6, 0);
            who[i] = a;
        }
    }

    // ------------------------------------------------------------------------------------------------ views for the invariants
    function exchange() external view returns (X) {
        return ex;
    }

    function token() external view returns (MockUSDC) {
        return usd;
    }

    function operatorAddr() external view returns (address) {
        return operator;
    }

    function party(uint256 i) external view returns (address) {
        return who[i];
    }

    function seenCount() external view returns (uint256) {
        return seen.length;
    }

    function seenAt(uint256 i) external view returns (X.Order memory) {
        return seen[i];
    }

    function initialClose(uint256 i) external view returns (uint64) {
        return initClose[i];
    }

    function unwindAllRedeemed(uint256 i) external view returns (bool) {
        for (uint256 j; j < N; ++j) {
            if (!redeemedAfterUnwind[i][j]) return false;
        }
        return true;
    }

    // ------------------------------------------------------------------------------------------------ small helpers
    function _pick(uint256 s) internal view returns (address) {
        return who[s % N];
    }

    function _idx(address a) internal view returns (uint256) {
        for (uint256 i; i < N; ++i) {
            if (who[i] == a) return i;
        }
        revert("not a party");
    }

    function _feeR(uint256 r, uint256 size, uint256 t) internal pure returns (uint256) {
        uint256 num = r * size * t * (100 - t);
        return (num + 99_999_999) / 100_000_000;
    }

    function _lots(uint256 x) internal pure returns (uint256) {
        return x / LOT * LOT;
    }

    function _status() internal {
        for (uint256 i; i < 2; ++i) {
            X.Market memory k = ex.marketOf(mk[i]);
            if (k.status < lastStatus[i]) gStatus = true;
            if (lastStatus[i] >= 2 && k.finalOutcome != lastFinal[i]) gStatus = true;
            if (k.status >= 2) lastFinal[i] = k.finalOutcome;
            lastStatus[i] = k.status;
        }
    }

    function _trackOrder(X.Order memory o) internal {
        seen.push(o);
    }

    struct Snap {
        uint256 cashHeld; // cash + held profit: a seller's whole receipt shows here
        uint256 cash;
        uint256[3] pos;
    }

    function _snap(uint256 m, address a) internal view returns (Snap memory s) {
        s.cash = ex.cash(a);
        (, uint256 h) = ex.recOf(m, a);
        s.cashHeld = s.cash + h;
        uint8 nOpt = ex.marketOf(m).nOptions;
        for (uint8 o; o < nOpt; ++o) {
            s.pos[o] = ex.positionOf(m, o, a);
        }
    }

    /// @dev The expected effect of one match on one wallet.
    struct Eff {
        int256 cashHeld;
        int256[3] pos;
    }

    function _checkEffects(uint256 m, Snap[N] memory before, Eff[N] memory e) internal {
        uint8 nOpt = ex.marketOf(m).nOptions;
        for (uint256 i; i < N; ++i) {
            Snap memory a = _snap(m, who[i]);
            if (int256(a.cashHeld) - int256(before[i].cashHeld) != e[i].cashHeld) gMoney = true;
            for (uint8 o; o < nOpt; ++o) {
                if (int256(a.pos[o]) - int256(before[i].pos[o]) != e[i].pos[o]) gMoney = true;
            }
        }
    }

    function _snapAll(uint256 m) internal view returns (Snap[N] memory s) {
        for (uint256 i; i < N; ++i) {
            s[i] = _snap(m, who[i]);
        }
    }

    function _open(uint256 m) internal view returns (bool) {
        X.Market memory k = ex.marketOf(m);
        return k.status == 1 && !ex.paused() && block.timestamp < k.tradingClose;
    }

    // ------------------------------------------------------------------------------------------------ cash
    function act_deposit(uint256 s, uint256 amt) external {
        amt = bound(amt, 1, 2_000e6);
        address a = _pick(s);
        Snap[N] memory b = _snapAll(mk[0]);
        _deposit(a, amt);
        Eff[N] memory e;
        e[_idx(a)].cashHeld = int256(amt);
        _checkEffects(mk[0], b, e);
    }

    function act_withdraw(uint256 s, uint256 amt) external {
        address a = _pick(s);
        uint256 c = ex.cash(a);
        amt = bound(amt, 0, c);
        Snap[N] memory b = _snapAll(mk[0]);
        vm.prank(a);
        (bool ok,) = address(ex).call(abi.encodeCall(X.withdraw, (amt)));
        if (!ok) gPauseProof = true; // X10: a withdraw within the cash must always succeed, paused or not
        Eff[N] memory e;
        e[_idx(a)].cashHeld = -int256(amt);
        _checkEffects(mk[0], b, e);
    }

    // ------------------------------------------------------------------------------------------------ sets
    function act_mint(uint256 s, uint256 ms, uint256 n) external {
        uint256 m = mk[ms % 2];
        address a = _pick(s);
        n = _lots(bound(n, LOT, 400e6));
        bool mustFail = !_open(m) || ex.cash(a) < n;
        Snap[N] memory b = _snapAll(m);
        uint256 coll = ex.marketOf(m).collateral;
        vm.prank(a);
        (bool ok,) = address(ex).call(abi.encodeCall(X.mintSets, (m, n)));
        if (ok) {
            if (!_open(m)) gClosed = true; // X6
            Eff[N] memory e;
            e[_idx(a)].cashHeld = -int256(n);
            uint8 nOpt = ex.marketOf(m).nOptions;
            for (uint8 o; o < nOpt; ++o) {
                e[_idx(a)].pos[o] = int256(n);
            }
            _checkEffects(m, b, e);
            if (ex.marketOf(m).collateral != coll + n) gMoney = true; // X4
            successfulSets++;
        } else if (!mustFail) {
            // open, funded and under the (huge) cap: it must have worked
            gClosed = true;
        }
    }

    function act_merge(uint256 s, uint256 ms, uint256 n) external {
        uint256 m = mk[ms % 2];
        address a = _pick(s);
        uint8 nOpt = ex.marketOf(m).nOptions;
        uint256 minPos = type(uint256).max;
        for (uint8 o; o < nOpt; ++o) {
            uint256 p = ex.positionOf(m, o, a);
            if (p < minPos) minPos = p;
        }
        n = _lots(bound(n, 0, minPos));
        if (n == 0) return;
        bool open = ex.marketOf(m).status == 1;
        Snap[N] memory b = _snapAll(m);
        (uint256 toFree, uint256 toHold) = ex.splitOf(m, a, n);
        uint256 coll = ex.marketOf(m).collateral;
        vm.prank(a);
        (bool ok,) = address(ex).call(abi.encodeCall(X.mergeSets, (m, n)));
        if (open && !ok) gPauseProof = true; // X10: merge works until finalization, paused or not
        if (ok) {
            Eff[N] memory e;
            e[_idx(a)].cashHeld = int256(toFree + toHold); // X18: the split is the one splitOf gave
            for (uint8 o; o < nOpt; ++o) {
                e[_idx(a)].pos[o] = -int256(n);
            }
            _checkEffects(m, b, e);
            if (ex.cash(a) != b[_idx(a)].cash + toFree) gMoney = true; // X18
            if (ex.marketOf(m).collateral != coll - n) gMoney = true; // X4
            successfulMerges++;
        }
    }

    // ------------------------------------------------------------------------------------------------ matches
    /// @dev A direct match: one maker, any side, at the maker's price. `seed` fixes everything else.
    function act_direct(uint256 a, uint256 b, uint256 seed) external {
        uint256 ti = a % N;
        uint256 mi = (ti + 1 + (b % (N - 1))) % N;
        uint256 mid = mk[seed & 1];
        uint8 nOpt = ex.marketOf(mid).nOptions;
        uint8 option = uint8((seed >> 1) % nOpt);
        bool takerBuy = (seed >> 5) & 1 == 1;
        uint8 p = uint8(1 + (seed >> 6) % 99);
        address buyer = who[takerBuy ? ti : mi];
        address seller = who[takerBuy ? mi : ti];
        uint256 fill = _lots(ex.positionOf(mid, option, seller));
        uint256 byCash = _lots(ex.cash(buyer) * 100 / (uint256(p) + 8)); // leaves room for the fee
        if (byCash < fill) fill = byCash;
        fill = _lots(fill * (1 + (seed >> 14) % 4) / 4);
        if (fill == 0) return;
        uint256 size = fill + LOT * ((seed >> 20) % 3);
        uint8 lim = takerBuy ? uint8(p + (seed >> 24) % (100 - p)) : uint8(1 + (seed >> 24) % p);
        if (lim > 99) lim = 99;
        X.Order memory to = _order(who[ti], mid, option, takerBuy, lim, size);
        X.Order memory mo = _order(who[mi], mid, option, !takerBuy, p, size);
        to.salt = uint256(keccak256(abi.encode(seed, 1)));
        mo.salt = uint256(keccak256(abi.encode(seed, 2)));
        _matchOne(mid, to, mo, fill, takerBuy, seed);
    }

    function _matchOne(uint256 mid, X.Order memory to, X.Order memory mo, uint256 fill, bool takerBuy, uint256 seed)
        internal
    {
        bytes32 th = _hash(to);
        bytes32 mh = _hash(mo);
        bool stale =
            lastFilled[th] + fill > to.size || lastFilled[mh] + fill > mo.size || wasCancelled[th] || wasCancelled[mh];
        Snap[N] memory b = _snapAll(mid);
        uint256 fees = ex.marketOf(mid).feesHeld;
        address seller = takerBuy ? mo.maker : to.maker;
        uint256 v = fill * mo.price / 100;
        uint256 fee = _feeR(rate[mid == mk[0] ? 0 : 1], fill, mo.price);
        if (fee != ex.feeOf(mid, fill, mo.price)) gMoney = true; // X5, X20: feeOf is the charged fee
        uint256 receipt = takerBuy ? v : v - fee;
        (uint256 wf,) = ex.splitOf(mid, seller, receipt); // X18
        bool wasOpen = _open(mid);
        bytes memory sig1 = _sign(keyOf[to.maker], to);
        bytes memory sig2 = _sign(keyOf[mo.maker], mo);
        vm.prank(operator);
        (bool ok,) = address(ex)
            .call(abi.encodeCall(X.matchOrders, (to, sig1, _one(mo), _oneSig(sig2), _oneFill(fill), uint128(fill))));
        _afterMatch(mid, ok, wasOpen, stale);
        if (!ok) return;
        successfulMatches++;
        _trackOrder(to);
        _trackOrder(mo);
        lastFilled[th] += uint128(fill);
        lastFilled[mh] += uint128(fill);
        Eff[N] memory e;
        uint256 bi = _idx(takerBuy ? to.maker : mo.maker);
        uint256 si = _idx(seller);
        e[bi].cashHeld = -int256(takerBuy ? v + fee : v);
        e[bi].pos[to.option] = int256(fill);
        e[si].cashHeld = int256(receipt);
        e[si].pos[to.option] = -int256(fill);
        _checkEffects(mid, b, e);
        if (ex.marketOf(mid).feesHeld != fees + fee) gMoney = true; // X5
        Snap memory sa = _snap(mid, seller);
        if (sa.cash != b[si].cash + wf) gMoney = true; // X18: the split applied is the split quoted
        seed;
    }

    function _afterMatch(uint256 mid, bool ok, bool wasOpen, bool stale) internal {
        if (ok && !wasOpen) gClosed = true; // X6
        if (ok && stale) gNonceCancel = true; // O1, O3: a spent, cancelled or over-filled order filled
        mid;
    }

    struct SetPlan {
        uint256 mid;
        uint8 nOpt;
        bool takerBuy;
        uint256 ti;
        uint8 tOpt;
        uint256 tp;
        uint256 fill;
        X.Order[] ms;
    }

    /// @dev A set match: N = 3 mint or merge on the three-option market, N = 2 on the two-option one.
    function act_set(uint256 seed) external {
        SetPlan memory sp = _planSet(seed);
        if (sp.fill == 0 || sp.fill == type(uint256).max) return;
        _finishSet(sp, seed);
    }

    function _planSet(uint256 seed) internal view returns (SetPlan memory sp) {
        sp.mid = mk[seed & 1];
        sp.nOpt = ex.marketOf(sp.mid).nOptions;
        sp.takerBuy = (seed >> 1) & 1 == 1;
        sp.ti = (seed >> 2) % N;
        sp.tOpt = uint8((seed >> 4) % sp.nOpt);
        sp.ms = new X.Order[](sp.nOpt - 1);
        uint256 fill = type(uint256).max;
        uint256 sum;
        uint256 k;
        for (uint8 o; o < sp.nOpt; ++o) {
            if (o == sp.tOpt) continue;
            uint8 price = uint8(1 + ((seed >> (8 + 8 * o)) % (sp.nOpt == 2 ? 80 : 40)));
            sum += price;
            address w = who[(sp.ti + 1 + k) % N];
            sp.ms[k] = _order(w, sp.mid, o, sp.takerBuy, price, 0);
            sp.ms[k].salt = uint256(keccak256(abi.encode(seed, o)));
            uint256 cap = sp.takerBuy ? ex.cash(w) * 100 / price : ex.positionOf(sp.mid, o, w);
            if (cap < fill) fill = cap;
            ++k;
        }
        sp.tp = 100 - sum;
        address taker = who[sp.ti];
        uint256 tcap = sp.takerBuy
            ? (sp.tp == 0 ? type(uint256).max : ex.cash(taker) * 100 / (sp.tp + 8))
            : ex.positionOf(sp.mid, sp.tOpt, taker);
        if (tcap < fill) fill = tcap;
        sp.fill = _lots(fill * (1 + (seed >> 40) % 4) / 4);
    }

    function _finishSet(SetPlan memory sp, uint256 seed) internal {
        uint256 n = sp.ms.length;
        bytes[] memory sigs = new bytes[](n);
        uint128[] memory fs = new uint128[](n);
        for (uint256 k; k < n; ++k) {
            sp.ms[k].size = uint128(sp.fill);
            sigs[k] = _sign(keyOf[sp.ms[k].maker], sp.ms[k]);
            fs[k] = uint128(sp.fill);
        }
        uint256 span = sp.takerBuy ? 100 - sp.tp : sp.tp;
        if (span == 0) span = 1;
        uint256 lim = sp.takerBuy ? sp.tp + (seed >> 48) % span : 1 + (seed >> 48) % span;
        if (lim > 99) lim = 99;
        if (lim == 0) lim = 1;
        X.Order memory to = _order(who[sp.ti], sp.mid, sp.tOpt, sp.takerBuy, uint8(lim), sp.fill);
        to.salt = uint256(keccak256(abi.encode(seed, 99)));
        _runSet(sp.mid, to, sp.ms, sigs, fs, sp.fill, sp.takerBuy, sp.tp);
    }

    function _runSet(
        uint256 mid,
        X.Order memory to,
        X.Order[] memory ms,
        bytes[] memory sigs,
        uint128[] memory fs,
        uint256 fill,
        bool takerBuy,
        uint256 tp
    ) internal {
        Snap[N] memory b = _snapAll(mid);
        X.Market memory before = ex.marketOf(mid);
        bool wasOpen = _open(mid);
        uint256 fee = _feeR(rate[mid == mk[0] ? 0 : 1], fill, tp);
        (uint256 wf, uint256 wh) =
            takerBuy ? (uint256(0), uint256(0)) : ex.splitOf(mid, to.maker, fill * tp / 100 - fee);
        bytes memory ts = _sign(keyOf[to.maker], to);
        vm.prank(operator);
        (bool ok,) = address(ex).call(abi.encodeCall(X.matchOrders, (to, ts, ms, sigs, fs, uint128(fill))));
        _afterMatch(mid, ok, wasOpen, false);
        if (!ok) return;
        successfulMatches++;
        _trackOrder(to);
        Eff[N] memory e;
        uint256 ti = _idx(to.maker);
        e[ti].cashHeld = takerBuy ? -int256(fill * tp / 100 + fee) : int256(fill * tp / 100 - fee);
        e[ti].pos[to.option] = takerBuy ? int256(fill) : -int256(fill);
        for (uint256 k; k < ms.length; ++k) {
            uint256 mi = _idx(ms[k].maker);
            uint256 v = fill * ms[k].price / 100;
            e[mi].cashHeld = takerBuy ? -int256(v) : int256(v);
            e[mi].pos[ms[k].option] = takerBuy ? int256(fill) : -int256(fill);
            _trackOrder(ms[k]);
        }
        _checkEffects(mid, b, e);
        X.Market memory aft = ex.marketOf(mid);
        // X4: exactly one set per unit created or destroyed, one USDC backing each
        if (takerBuy) {
            if (aft.setsOutstanding != before.setsOutstanding + fill || aft.collateral != before.collateral + fill) {
                gMoney = true;
            }
        } else {
            if (aft.setsOutstanding != before.setsOutstanding - fill || aft.collateral != before.collateral - fill) {
                gMoney = true;
            }
        }
        if (aft.feesHeld != before.feesHeld + fee) gMoney = true; // X5: the taker leaf pays the fee, makers none
        if (!takerBuy && ex.cash(to.maker) != b[ti].cash + wf) gMoney = true; // X18
        wh;
    }

    // ------------------------------------------------------------------------------------------------ cancel, nonce, access
    function act_cancel(uint256 s, bool byStranger) external {
        if (seen.length == 0) return;
        X.Order memory o = seen[s % seen.length];
        bytes32 h = _hash(o);
        address caller = byStranger ? who[(_idx(o.maker) + 1) % N] : o.maker;
        (uint128 f0,) = ex.orders(h);
        vm.prank(caller);
        (bool ok,) = address(ex).call(abi.encodeCall(X.cancelOrders, (_one(o))));
        if (byStranger) {
            if (ok) gCancelOnly = true; // X7: only the maker cancels
            return;
        }
        if (!ok) gPauseProof = true; // X10: cancel always works
        wasCancelled[h] = true;
        (uint128 f1, bool c1) = ex.orders(h);
        if (!c1 || f1 != f0) gCancelOnly = true;
    }

    function act_nonce(uint256 s) external {
        address a = _pick(s);
        uint256 n0 = ex.nonces(a);
        vm.prank(a);
        ex.incrementNonce();
        if (ex.nonces(a) != n0 + 1) gNonceCancel = true;
    }

    function act_notOperator(uint256 s) external {
        // O4: nobody but an operator settles
        address a = s % 3 == 0 ? address(this) : s % 3 == 1 ? ex.resolver() : _pick(s);
        X.Order memory to = _order(who[0], mk[0], 0, true, 50, LOT);
        X.Order memory mo = _order(who[1], mk[0], 0, false, 50, LOT);
        vm.prank(a);
        (bool ok,) = address(ex)
            .call(abi.encodeCall(X.matchOrders, (to, "", _one(mo), _oneSig(""), _oneFill(LOT), uint128(LOT))));
        if (ok) gOperatorOnly = true;
    }

    // ------------------------------------------------------------------------------------------------ time and admin
    function act_warp(uint256 d) external {
        vm.warp(block.timestamp + bound(d, 1, 3 days));
        _status();
    }

    /// @dev Paused one call in five, so the run spends most of its time trading.
    function act_pause(uint256 x) external {
        ex.setPaused(x % 5 == 0);
    }

    /// @dev Rare on purpose (one call in sixteen takes effect): an early close ends trading in a market for good.
    function act_closeEarly(uint256 ms) external {
        if (ms % 16 != 0) return;
        uint256 m = mk[(ms >> 4) % 2];
        if (ex.marketOf(m).status != 1) return;
        uint64 before = ex.marketOf(m).tradingClose;
        ex.closeEarly(m);
        if (ex.marketOf(m).tradingClose > before) gClosed = true; // X12: tradingClose only moves earlier
        _status();
    }

    function act_propose(uint256 ms, uint256 o) external {
        uint256 m = mk[ms % 2];
        X.Market memory k = ex.marketOf(m);
        uint8 outcome = o % 4 == 3 ? UNWIND : uint8((o >> 2) % k.nOptions);
        try ex.proposeOutcome(m, outcome, keccak256(abi.encode(o))) {} catch {}
        _status();
    }

    function act_finalize(uint256 ms) external {
        uint256 m = mk[ms % 2];
        X.Market memory k = ex.marketOf(m);
        bool valid = k.status == 1 && k.hasProposal && block.timestamp >= k.finalizableAt;
        uint256 feesBefore = k.feesHeld;
        uint256 tre = ex.treasuryBalance();
        (bool ok,) = address(ex).call(abi.encodeCall(X.finalize, (m)));
        if (valid && !ok) gPauseProof = true; // X10: finalize works whenever it is valid, paused or not
        if (!valid && ok) gStatus = true;
        if (ok) {
            X.Market memory a = ex.marketOf(m);
            if (a.finalOutcome != k.proposedOutcome) gStatus = true;
            if (k.proposedOutcome != UNWIND) {
                // X17: feesHeld moves to the treasury exactly once
                if (ex.treasuryBalance() != tre + feesBefore || a.feesHeld != 0) gRelease = true;
            } else {
                if (a.collateral != 0 || a.feesHeld != 0 || a.profitHeldTotal != 0) gUnwind = true;
                if (a.unwindPool != uint256(k.collateral) + k.feesHeld + k.profitHeldTotal) gUnwind = true;
                if (ex.treasuryBalance() != tre) gUnwind = true; // an unwind keeps the fees in the pool
            }
        }
        _status();
    }

    function act_backstop(uint256 ms) external {
        uint256 m = mk[ms % 2];
        X.Market memory k = ex.marketOf(m);
        bool atOrAfter = block.timestamp >= uint256(k.resolutionDeadline) + 7 days;
        bool valid = k.status == 1 && atOrAfter && !k.hasProposal;
        bool finalizeValid = k.status == 1 && k.hasProposal && block.timestamp >= k.finalizableAt;
        (bool ok,) = address(ex).call(abi.encodeCall(X.backstopUnwind, (m)));
        if (valid != ok) gBackstop = true; // X11: reachable by anyone when valid, and only then
        if (ok && finalizeValid) gBackstop = true; // X19: never both valid at once
        // X19: at or after the line a proposal accepted in time is finalizable, so the backstop is closed to it
        if (atOrAfter && k.status == 1 && k.hasProposal && !finalizeValid) gBackstop = true;
        _status();
    }

    function act_redeem(uint256 s, uint256 ms) external {
        uint256 m = mk[ms % 2];
        address a = _pick(s);
        X.Market memory k = ex.marketOf(m);
        (uint256 net, uint256 held) = ex.recOf(m, a);
        uint256 cashBefore = ex.cash(a);
        uint256 win = k.status == 2 ? ex.positionOf(m, k.finalOutcome, a) : 0;
        vm.prank(a);
        (bool ok,) = address(ex).call(abi.encodeCall(X.redeem, (m)));
        if (k.status >= 2 && !ok) gPauseProof = true; // X10: redeem never pausable
        if (k.status < 2 && ok) gStatus = true;
        if (!ok) return;
        uint256 got = ex.cash(a) - cashBefore;
        if (k.status == 2) {
            if (got != win + held) gRelease = true; // X17: shares plus held profit, once
            (, uint256 h2) = ex.recOf(m, a);
            if (h2 != 0 || ex.positionOf(m, k.finalOutcome, a) != 0) gRelease = true;
        } else {
            if (got != net) gUnwind = true; // X16: exactly its net, once
            (uint256 n2,) = ex.recOf(m, a);
            if (n2 != 0) gUnwind = true;
            redeemedAfterUnwind[m == mk[0] ? 0 : 1][_idx(a)] = true;
        }
    }

    function act_withdrawTreasury() external {
        uint256 t = ex.treasuryBalance();
        uint256 before = usd.balanceOf(treasury);
        vm.prank(treasury);
        (bool ok,) = address(ex).call(abi.encodeCall(X.withdrawTreasury, ()));
        if ((t != 0) != ok) gRelease = true;
        if (ok && usd.balanceOf(treasury) != before + t) gRelease = true;
    }

    /// @dev O1 and the status check, evaluated by the invariants after every call.
    function checkFilled() external view returns (bool bad) {
        for (uint256 i; i < seen.length; ++i) {
            bytes32 h = _hash(seen[i]);
            (uint128 f,) = ex.orders(h);
            if (f < lastFilled[h] || f > seen[i].size) return true;
        }
    }
}
