// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {ExchangeBase} from "./ExchangeBase.sol";
import {MakoOutcomeExchangeV1 as X} from "../../src/MakoOutcomeExchangeV1.sol";

/// Plan section 3.1 rule 4 (r31 d6, d7): the whole-class property behind plan 4.4 "Amount slots never return to zero" and 6.2 out-of-gas rule 3.
///
/// Nothing a party (or a third party) does on its own between the settler's gas estimate and inclusion may make
/// `matchOrders` cost more than it did at the estimate. For each kind (direct with 1, 2 and 3 makers, mint, merge) the
/// test builds a valid matched call with fuzzed party states (cash, shares, net, touched or untouched records, market
/// totals), measures its gas, reverts to the snapshot, applies 1 to 4 fuzzed actions the parties or a third party can
/// take for themselves (deposit, withdraw, mintSets, mergeSets, redeem, cancelOrders of an unrelated order,
/// incrementNonce), and measures the same call again. An action that makes the call revert (the order
/// itself invalid: cash, shares, nonce) is undone and skipped; those revert with named errors and are tested elsewhere.
///
/// Asserts gas_after <= estimate + TOL_PER_PARTY per party (taker plus makers). The registered signer of the spike's
/// action list (`setOrderSigner`) is not part of this build.
contract GasMonotoneTest is ExchangeBase {
    /// @notice Canary for the CI step that runs this file with `FOUNDRY_PROFILE=monad` (adversary pass 1): a skipped
    /// cash write shows against the 3,000-gas per-party bound only under Monad's gas schedule, so that step must prove
    /// the schedule is really applied. A cold account access costs 2,600 gas on Ethereum and 10,100 on Monad. With
    /// `EXPECT_MONAD_GAS=true` (set by that CI step) the run must be on Monad's schedule; without it, on Ethereum's.
    function test_gasSchedule_isTheOneThisRunExpects() public view {
        address fresh = address(uint160(uint256(keccak256("mako exchange gas schedule canary"))));
        uint256 g = gasleft();
        uint256 bal = fresh.balance;
        uint256 used = g - gasleft();
        assertEq(bal, 0, "canary account must be empty");
        if (vm.envOr("EXPECT_MONAD_GAS", false)) {
            assertGt(
                used,
                8_000,
                "EXPECT_MONAD_GAS is set but a cold account access cost Ethereum's price: the Monad schedule is NOT applied"
            );
        } else {
            assertLt(used, 5_000, "a cold account access cost Monad's price in a run that expects Ethereum's schedule");
        }
    }

    uint256 internal constant GAS_CAP = 20_000_000;
    /// One write that changes a slot costs 2,800 more than one that rewrites the same value (EIP-2200 warm: 2,900 vs 100).
    /// That wobble is allowed once per party in the call and nothing more; anything above is a defect.
    uint256 internal constant TOL_PER_PARTY = 3_000;
    uint8 internal constant DIRECT = 0;
    uint8 internal constant MINT = 1;
    uint8 internal constant MERGE = 2;

    struct Party {
        address a;
        uint256 k;
    }

    int256 internal maxDelta;
    uint256 internal fullMergeSettled;
    uint256 internal fullMergeOwnSellFailures;
    Party[] internal ps; // taker, makers..., two third parties
    uint256 internal M;
    bytes internal data;

    // ------------------------------------------------------------------------------------------------ fuzz entries
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_gasMonotone_direct1(uint256 seed) public {
        _run(DIRECT, 1, seed, "direct1");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_gasMonotone_direct2(uint256 seed) public {
        _run(DIRECT, 2, seed, "direct2");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_gasMonotone_direct3(uint256 seed) public {
        _run(DIRECT, 3, seed, "direct3");
    }

    /// forge-config: default.fuzz.runs = 96
    function testFuzz_gasMonotone_direct10(uint256 seed) public {
        _run(DIRECT, 10, seed, "direct10");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_gasMonotone_mint(uint256 seed) public {
        _run(MINT, 0, seed, "mint");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_gasMonotone_merge(uint256 seed) public {
        _run(MERGE, 0, seed, "merge");
    }

    /// Codex R14 F1 counterexample (merge used 376,540 against a 373,950 bound that counted one party); kept as a
    /// regression: it must pass with the bound counting the taker and every maker.
    function test_gasMonotone_merge_codexR14Counterexample() public {
        _run(MERGE, 0, 15639020638419159078663078, "merge-r14");
    }

    // ------------------------------------------------------------------------------------------------ the property
    function _run(uint8 kindId, uint256 nM, uint256 seed, string memory tag) internal {
        _build(kindId, nM, seed);
        uint256 s0 = vm.snapshotState();
        (bool ok0, uint256 est) = _gas(data);
        require(ok0, "fixture: the estimate call must settle");
        vm.revertToState(s0);

        uint256 nAct = 1 + _r(seed, 900) % 4;
        for (uint256 i; i < nAct; ++i) {
            uint256 pre = vm.snapshotState();
            if (!_apply(seed, i)) {
                vm.revertToState(pre);
                continue;
            }
            uint256 pr = vm.snapshotState();
            (bool ok,) = _gas(data);
            vm.revertToState(pr);
            if (!ok) vm.revertToState(pre);
        }

        (bool okA, uint256 used) = _gas(data);
        require(okA, "fixture: the call after the actions must settle");
        int256 delta = int256(used) - int256(est);
        if (delta > maxDelta) maxDelta = delta;
        tag;
        // parties in the call = taker + makers as built (mint and merge derive their makers from the option count, so
        // nM is 0 for them); ps also holds two third parties, who act but are not in the call (Codex R14 F1)
        uint256 nParties = ps.length - 2;
        assertLe(
            used, est + TOL_PER_PARTY * nParties, "a party's own action made matchOrders dearer than at the estimate"
        );
    }

    function _gas(bytes memory d) internal returns (bool ok, uint256 used) {
        // a test is one transaction: make every account and slot the call can touch cold again, as in a real block
        vm.cool(address(ex));
        vm.cool(operator);
        vm.cool(address(usd));
        for (uint256 i; i < ps.length; ++i) {
            vm.cool(ps[i].a);
        }
        ex.MAX_MAKERS(); // constant read: warms the exchange account (its slots stay cold) so the CALL's own cold-account
        // charge, which depends on what ran earlier in this test transaction, is the same for every measurement
        vm.prank(operator);
        uint256 g = gasleft();
        (ok,) = address(ex).call{gas: GAS_CAP}(d);
        used = g - gasleft();
    }

    // ------------------------------------------------------------------------------------------------ actions
    function _apply(uint256 seed, uint256 i) internal returns (bool) {
        uint256 r = _r(seed, 100 + i);
        (uint256 kind, uint256 who) = _pick(r, ps.length);
        address a = ps[who].a;
        uint256 amt = _amt(r >> 16);
        if (kind == 0 || kind == 8) {
            usd.mint(a, amt);
            vm.prank(a);
            usd.approve(address(ex), amt);
            return _try(a, abi.encodeCall(ex.deposit, (amt)));
        }
        if (kind == 1) {
            uint256 c = ex.cash(a);
            if ((r >> 100) & 1 == 1 || amt > c) amt = c;
            return _try(a, abi.encodeCall(ex.withdraw, (amt)));
        }
        if (kind == 9) return _fullMerge(a) != 0;
        if (kind == 2) return _try(a, abi.encodeCall(ex.mintSets, (M, amt)));
        if (kind == 3) return _try(a, abi.encodeCall(ex.mergeSets, (M, amt)));
        if (kind == 4) return _try(a, abi.encodeCall(ex.redeem, (M)));
        if (kind == 5) {
            X.Order[] memory os = new X.Order[](1);
            os[0] = _order(a, M, 0, true, 7, 10 * SHARE);
            os[0].salt = r;
            return _try(a, abi.encodeCall(ex.cancelOrders, (os)));
        }
        if (kind == 6) return _try(a, abi.encodeCall(ex.incrementNonce, ()));
        return _try(a, abi.encodeCall(ex.incrementNonce, ()));
    }

    /// @dev Which action, by whom. Kinds 0-9 once each, plus 10 and 11 as a second mintSets and mergeSets (twice as
    /// likely). Codex R1 F1: the earlier `% 11` with `kind -= 7` from 9 never produced kind 9 (merge every set).
    /// 3 in 4 actions come from a party of the call (the interesting ones), the rest from anyone, third parties included.
    function _pick(uint256 r, uint256 nPs) internal pure returns (uint256 kind, uint256 who) {
        who = (r >> 120) & 3 != 0 ? r % (nPs - 2) : r % nPs;
        kind = (r >> 8) % 12;
        if (kind >= 10) kind -= 8;
    }

    /// @dev Merge every complete set `a` holds in M (empties a third party's share of the market totals, zeroes a net).
    /// Returns the sets merged, 0 if none or the merge reverted.
    function _fullMerge(address a) internal returns (uint256 amt) {
        uint256 nOpt = ex.marketOf(M).nOptions;
        amt = type(uint256).max;
        for (uint256 o; o < nOpt; ++o) {
            uint256 h = ex.positionOf(M, uint8(o), a);
            if (h < amt) amt = h;
        }
        amt = amt / LOT * LOT;
        if (amt == 0 || !_try(a, abi.encodeCall(ex.mergeSets, (M, amt)))) return 0;
    }

    /// Codex R1 F1: the generator reaches the full merge, from a party of the call and from a third party.
    function test_gasMonotone_generator_reachesFullMerge_byPartyAndByThirdParty() public pure {
        uint256 nPs = 1 + 3 + 2; // a 3-maker direct: taker, three makers, two third parties
        bool byParty;
        bool byThird;
        for (uint256 seed; seed < 1024 && !(byParty && byThird); ++seed) {
            for (uint256 i; i < 4; ++i) {
                (uint256 kind, uint256 who) = _pick(_r(seed, 100 + i), nPs);
                if (kind != 9) continue;
                if (who < nPs - 2) byParty = true;
                else byThird = true;
            }
        }
        assertTrue(byParty, "the generator never picks a full merge by a party of the call");
        assertTrue(byThird, "the generator never picks a full merge by a third party");
    }

    /// Codex R1 F1, deterministic: the wallet holds complete sets at the estimate and merges every one of them before
    /// inclusion, for the taker, the first maker and a third party, in every match kind. The merge must really happen
    /// (all sets gone) and the call must stay within estimate + 3,000 per party.
    function test_gasMonotone_fullMergeBetweenEstimateAndInclusion_everyKind_partyAndThirdParty() public {
        uint8[4] memory kinds = [DIRECT, DIRECT, MINT, MERGE];
        uint256[4] memory makers = [uint256(1), 3, 0, 0];
        for (uint256 k; k < 4; ++k) {
            for (uint256 w; w < 3; ++w) {
                _runFullMerge(kinds[k], makers[k], 7 + k, w);
            }
        }
        // 12 cases: the third party settles in all 4 kinds; a selling party may fail on its own shares, a buying one never
        assertEq(fullMergeSettled + fullMergeOwnSellFailures, 12, "every case ran");
        assertGe(fullMergeSettled, 8, "too few full-merge cases settled to prove the bound");
    }

    /// @dev The hash of party `w`'s order in the built call (0 the taker, else maker w - 1).
    function _orderHashOf(uint256 w) internal view returns (bytes32) {
        bytes memory d = data;
        bytes memory args = new bytes(d.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = d[i + 4];
        }
        (X.Order memory t,, X.Order[] memory ms,,,) =
            abi.decode(args, (X.Order, bytes, X.Order[], bytes[], uint128[], uint128));
        return _hash(w == 0 ? t : ms[w - 1]);
    }

    /// @dev `w`: 0 the taker, 1 the first maker, 2 the last third party.
    function _runFullMerge(uint8 kindId, uint256 nM, uint256 seed, uint256 w) internal {
        _build(kindId, nM, seed);
        address a = w == 2 ? ps[ps.length - 1].a : ps[w].a;
        uint256 sets = 3 * SHARE;
        usd.mint(a, sets);
        vm.prank(a);
        usd.approve(address(ex), sets);
        require(_try(a, abi.encodeCall(ex.deposit, (sets))), "fixture: deposit");
        require(
            _try(a, abi.encodeCall(ex.mintSets, (M, sets))), "fixture: the wallet holds complete sets at the estimate"
        );
        uint256 s0 = vm.snapshotState();
        (bool ok0, uint256 est) = _gas(data);
        require(ok0, "fixture: the estimate call must settle");
        vm.revertToState(s0);

        uint256 merged = _fullMerge(a);
        assertGe(merged, sets, "the full merge did not run");
        uint256 nOpt = ex.marketOf(M).nOptions;
        uint256 least = type(uint256).max;
        for (uint256 o; o < nOpt; ++o) {
            uint256 h = ex.positionOf(M, uint8(o), a);
            if (h < least) least = h;
        }
        assertLt(least, LOT, "a complete set is left after the full merge");

        (bool okA, uint256 used) = _gas(data);
        if (!okA) {
            // allowed only when the merge took the shares this wallet's own order sells: then the call fails with that
            // order's InsufficientShares (the settler's simulation fails, it is not an out-of-gas), and nothing else
            require(w != 2, "a third party's full merge made the call fail");
            vm.prank(operator);
            (, bytes memory err) = address(ex).call(data);
            assertEq(
                bytes4(err), X.InsufficientShares.selector, "the call failed after the full merge for another reason"
            );
            assertEq(
                keccak256(err),
                keccak256(abi.encodeWithSelector(X.InsufficientShares.selector, _orderHashOf(w))),
                "not this wallet's own order"
            );
            ++fullMergeOwnSellFailures;
            return;
        }
        ++fullMergeSettled;
        assertLe(
            used, est + TOL_PER_PARTY * (ps.length - 2), "a full merge made matchOrders dearer than at the estimate"
        );
    }

    function _try(address from, bytes memory cd) internal returns (bool ok) {
        vm.prank(from);
        (ok,) = address(ex).call(cd);
    }

    // ------------------------------------------------------------------------------------------------ fixture
    function _r(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    /// Amounts that cross the interesting boundaries (a receipt vs a net, a position vs a fill), all lot multiples.
    function _amt(uint256 r) internal pure returns (uint256) {
        uint256 c = r % 8;
        if (c == 0) return LOT;
        if (c == 1) return 5 * LOT;
        if (c == 2) return SHARE;
        if (c == 3) return 3 * SHARE;
        if (c == 4) return 10 * SHARE;
        if (c == 5) return 25 * SHARE;
        if (c == 6) return (1 + (r >> 8) % 3000) * LOT;
        return 100 * LOT;
    }

    struct Spec {
        bool isBuy;
        uint8 option;
        uint8 price;
        uint256 fill;
        uint256 pay; // cash a buyer needs for this call
    }

    function _build(uint8 kindId, uint256 nM, uint256 seed) internal {
        delete ps;
        uint8 nOpt = kindId == DIRECT ? 2 : uint8(3 + _r(seed, 1) % 2);
        uint256 n = kindId == DIRECT ? nM : nOpt - 1;
        M = _market(nOpt);
        (Spec[] memory sp, uint256 total) = _specs(kindId, n, seed);
        _assemble(sp, n, seed, total);
    }

    function _specs(uint8 kindId, uint256 n, uint256 seed) internal view returns (Spec[] memory sp, uint256 total) {
        bool takerBuy = kindId == DIRECT ? (_r(seed, 2) & 1 == 0) : kindId == MINT;
        sp = new Spec[](n + 1); // 0 = taker
        if (kindId == DIRECT) {
            sp[0] = Spec(takerBuy, 0, takerBuy ? 70 : 30, 0, 0);
            for (uint256 i = 1; i <= n; ++i) {
                uint256 f = _amt(_r(seed, 10 + i));
                total += f;
                sp[i] =
                    Spec(!takerBuy, 0, uint8(takerBuy ? 20 + _r(seed, 20 + i) % 40 : 40 + _r(seed, 20 + i) % 40), f, 0);
            }
            sp[0].fill = total;
            _setPaysDirect(sp, takerBuy);
        } else {
            total = _amt(_r(seed, 10));
            uint256 sum;
            for (uint256 i = 1; i <= n; ++i) {
                uint8 pr = uint8(5 + _r(seed, 20 + i) % 16);
                sum += pr;
                sp[i] = Spec(takerBuy, uint8(i), pr, total, 0);
            }
            sp[0] = Spec(takerBuy, 0, takerBuy ? 99 : 1, total, 0);
            _setPays(sp, 100 - sum, kindId);
        }
    }

    function _assemble(Spec[] memory sp, uint256 n, uint256 seed, uint256 total) internal {
        X.Order[] memory ms = new X.Order[](n);
        bytes[] memory sigs = new bytes[](n);
        uint128[] memory fills = new uint128[](n);
        for (uint256 i; i <= n + 2; ++i) {
            (address a, uint256 k) = makeAddrAndKey(string.concat("gm", vm.toString(seed), "-", vm.toString(i)));
            ps.push(Party(a, k));
            if (i > n) {
                _fundThird(a, _r(seed, 300 + i));
                continue;
            }
            _fund(a, sp[i], _r(seed, 300 + i));
            if (i > 0) {
                ms[i - 1] = _ord(a, sp[i]);
                sigs[i - 1] = _sign(k, ms[i - 1]);
                fills[i - 1] = uint128(sp[i].fill);
            }
        }
        X.Order memory to = _ord(ps[0].a, sp[0]);
        data = abi.encodeCall(X.matchOrders, (to, _sign(ps[0].k, to), ms, sigs, fills, uint128(total)));
    }

    function _ord(address a, Spec memory s) internal view returns (X.Order memory) {
        return _order(a, M, s.option, s.isBuy, s.price, s.fill);
    }

    function _setPays(Spec[] memory sp, uint256 tp, uint8 kindId) internal view {
        for (uint256 i = 1; i < sp.length; ++i) {
            if (sp[i].isBuy) sp[i].pay = sp[i].fill * sp[i].price / 100;
        }
        if (kindId == MINT) sp[0].pay = sp[0].fill * tp / 100 + ex.feeOf(M, sp[0].fill, tp);
    }

    function _setPaysDirect(Spec[] memory sp, bool takerBuy) internal view {
        for (uint256 i = 1; i < sp.length; ++i) {
            uint256 v = sp[i].fill * sp[i].price / 100;
            if (takerBuy) sp[0].pay += v + ex.feeOf(M, sp[i].fill, sp[i].price);
            else sp[i].pay = v;
        }
    }

    /// One party's starting state: an optional prelude of its own trades (touches its account record, sets a net), the
    /// cash a buyer needs (exact or with spare), and the shares a seller needs (seeded: net 0, or with spare).
    function _fund(address a, Spec memory s, uint256 r) internal {
        // 1 mint, 2 mint+merge (touched, net 0), 3 mint+partial merge; 0 (untouched, rarely) can only make the later
        // call cheaper, so most parties start with every settlement slot already non-zero, the costly baseline
        // Two in three sellers hold SEEDED shares: shares in storage with no net record and no cash slot of their own, as a
        // seller whose net is zero has (the plan's "first position of every party", and the case that makes a skipped cash
        // write visible). The others get theirs by minting, which leaves a net record behind.
        bool seeded = !s.isBuy && (r >> 40) % 3 != 0;
        uint256 prelude = r % 16 == 0 || seeded ? 0 : 1 + (r >> 4) % 3;
        uint256 mintAmt = _amt(r >> 8);
        uint256 cashAmt = s.isBuy ? s.pay + ((r >> 16) & 1 == 1 ? 0 : _amt(r >> 20)) : _amt(r >> 21);
        if (prelude != 0) cashAmt += mintAmt;
        if (cashAmt != 0) _deposit(a, cashAmt);
        if (prelude != 0) {
            vm.startPrank(a);
            ex.mintSets(M, mintAmt);
            if (prelude == 2) ex.mergeSets(M, mintAmt);
            if (prelude == 3) ex.mergeSets(M, mintAmt > LOT ? mintAmt / 2 / LOT * LOT : 0 == 0 ? mintAmt : 0);
            vm.stopPrank();
        }
        if (s.isBuy) {
            // a buyer must still be able to pay after the prelude spent cash: top up to exactly pay or more
            uint256 c = ex.cash(a);
            if (c < s.pay) _deposit(a, s.pay - c);
        } else {
            uint256 have = ex.positionOf(M, s.option, a);
            if (have < s.fill) {
                uint256 need = s.fill - have + ((r >> 30) & 3 == 0 ? 0 : _amt(r >> 34));
                if (seeded) {
                    _seed(a, s.option, need);
                    if ((r >> 46) & 1 == 1) _touchNet(a); // half of them have a record at zero
                } else {
                    _mint(a, M, need);
                }
            }
        }
    }

    // ------------------------------------------------------------------------------------------------ seeding by storage
    // `_sharesS` is storage slot 10 and `_markets` slot 8 (the surface gate pins the layout); `test_seedHelper_...` checks
    // both against the real functions, so a layout change fails there first.
    uint256 internal constant SHARES_SLOT = 10;
    uint256 internal constant MARKETS_SLOT = 8;

    function _shareSlot(uint256 m, uint8 option, address a) internal pure returns (bytes32) {
        return keccak256(abi.encode(keccak256(abi.encode(m, uint256(option), a)), SHARES_SLOT));
    }

    function _marketSlot(uint256 m, uint256 offset) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(m, MARKETS_SLOT))) + offset);
    }

    /// @dev `n` shares of one option for `a`, written straight to storage (stored as amount + 1), with the market's sets
    /// outstanding and collateral raised by `n` so a merge in the same market stays backed.
    function _seed(address a, uint8 option, uint256 n) internal {
        bytes32 slot = _shareSlot(M, option, a);
        uint256 cur = uint256(vm.load(address(ex), slot));
        vm.store(address(ex), slot, bytes32((cur == 0 ? 1 : cur) + n));
        bytes32 s1 = _marketSlot(M, 1); // positionCap (low 128), setsOutstanding (high 128)
        vm.store(address(ex), s1, bytes32(uint256(vm.load(address(ex), s1)) + (n << 128)));
        bytes32 s2 = _marketSlot(M, 2); // collateral (low 128), feesHeld, markA
        vm.store(address(ex), s2, bytes32(uint256(vm.load(address(ex), s2)) + n));
    }

    uint256 internal constant REC_SLOT = 11; // `_rec`

    /// @dev `a`'s per-market record exists with a net of zero (net is stored as net + 1, so the slot holds 1): a wallet that
    /// traded its way back to zero, as opposed to one that never traded.
    function _touchNet(address a) internal {
        bytes32 key = keccak256(abi.encode(M, a));
        vm.store(address(ex), keccak256(abi.encode(key, REC_SLOT)), bytes32(uint256(1)));
    }

    function test_seedHelper_matchesTheContractsStorageLayout() public {
        M = _market(3);
        (address a,) = makeAddrAndKey("seedCheck");
        _mint(a, M, 7 * SHARE);
        assertEq(
            uint256(vm.load(address(ex), _shareSlot(M, 1, a))), 7 * SHARE + 1, "_sharesS holds amount + 1 at slot 10"
        );
        assertEq(
            uint256(vm.load(address(ex), _marketSlot(M, 1))) >> 128,
            7 * SHARE,
            "setsOutstanding is the high half of the market's slot 1"
        );
        assertEq(
            uint128(uint256(vm.load(address(ex), _marketSlot(M, 2)))),
            7 * SHARE,
            "collateral is the low half of the market's slot 2"
        );
        (address b,) = makeAddrAndKey("seedCheck2");
        _seed(b, 2, 3 * SHARE);
        assertEq(ex.positionOf(M, 2, b), 3 * SHARE, "a seeded position reads back as its amount");
        assertEq(ex.marketOf(M).setsOutstanding, 10 * SHARE);
        assertEq(ex.marketOf(M).collateral, 10 * SHARE);
        (uint256 net,) = ex.recOf(M, b);
        assertEq(net, 0, "and has no net");
        // a touched record reads back as net 0 and is non-zero in storage
        _touchNet(b);
        bytes32 recSlot = keccak256(abi.encode(keccak256(abi.encode(M, b)), REC_SLOT));
        assertEq(uint256(vm.load(address(ex), recSlot)), 1);
        (net,) = ex.recOf(M, b);
        assertEq(net, 0);
        // and a real mint writes the record at exactly that slot (net + 1 in the low half)
        _mint(a, M, 2 * SHARE);
        bytes32 aRec = keccak256(abi.encode(keccak256(abi.encode(M, a)), REC_SLOT));
        assertEq(
            uint256(uint128(uint256(vm.load(address(ex), aRec)))),
            9 * SHARE + 1,
            "net is the low half of the record, plus one"
        );
    }

    // ------------------------------------------------------------------------------------------------ fixed scenarios
    // The fuzz hunts; these pin the two rules by name, so a mutant that removes one dies on a fixed scenario and not only
    // when a seed happens to reach it. (Both need the Monad schedule to see the whole cost: see foundry.toml, profile monad.)

    function _pair(string memory name) internal returns (address a, uint256 k) {
        (a, k) = makeAddrAndKey(name);
        ps.push(Party(a, k));
    }

    /// @dev Rule 2: no write is skipped because of a party-controlled value. The maker seller holds seeded shares and has
    /// a net of zero, so its receipt goes entirely to the hold at the estimate; before inclusion it mints sets of its own
    /// (net above zero), so the same receipt now reaches free cash. A cash write guarded by "something goes to free cash"
    /// would be skipped at the estimate and made at inclusion.
    function test_gasMonotone_rule2_sellerWithNoNetThenMints_cashWriteIsUnconditional() public {
        delete ps;
        M = _market(2);
        (address t, uint256 tk) = _pair("r2-taker");
        (address s, uint256 sk) = _pair("r2-seller");
        _pair("r2-third-a");
        _pair("r2-third-b");
        _deposit(t, 100e6);
        _deposit(s, 1e6);
        _seed(s, 0, 10 * SHARE);
        _touchNet(s); // a record at net zero, so the record slot costs the same before and after the mint
        X.Order memory to = _order(t, M, 0, true, 70, 10 * SHARE);
        X.Order[] memory ms = _one(_order(s, M, 0, false, 40, 10 * SHARE));
        data = abi.encodeCall(
            X.matchOrders, (to, _sign(tk, to), ms, _oneSig(_sign(sk, ms[0])), _oneFill(10 * SHARE), uint128(10 * SHARE))
        );
        uint256 snap = vm.snapshotState();
        (bool ok0, uint256 est) = _gas(data);
        require(ok0, "fixture: the estimate must settle");
        vm.revertToState(snap);
        _deposit(s, 20 * SHARE);
        vm.prank(s);
        ex.mintSets(M, 10 * SHARE); // the seller's net is now above zero
        (bool ok1, uint256 used) = _gas(data);
        require(ok1, "fixture: the call after the action must settle");
        assertLe(used, est + TOL_PER_PARTY * 2, "a party's own mint made matchOrders dearer than at the estimate");
    }

    /// @dev Rule 2 as a count: `matchOrders` makes the same number of storage writes whether or not the seller's receipt is
    /// held. One seller's net covers its receipt (everything to free cash, nothing held); another's is zero (everything
    /// held, nothing to free cash). A write guarded by "something goes to free cash" or "something is held" differs.
    function test_gasMonotone_rule2_sameWritesWhetherOrNotAReceiptIsHeld() public {
        uint256 covered = _sellerMatchWrites(false);
        uint256 held = _sellerMatchWrites(true);
        assertEq(held, covered, "the number of storage writes depends on a party's net");
        assertGt(covered, 8, "the count is of real settlement writes");
    }

    function _sellerMatchWrites(bool sellerHoldsReceipt) internal returns (uint256 n) {
        delete ps;
        M = _market(2);
        string memory tag = sellerHoldsReceipt ? "w-held" : "w-free";
        (address t, uint256 tk) = _pair(string.concat(tag, "-taker"));
        (address s, uint256 sk) = _pair(string.concat(tag, "-seller"));
        _deposit(t, 100e6);
        _deposit(s, 1e6);
        if (sellerHoldsReceipt) {
            _seed(s, 0, 10 * SHARE);
            _touchNet(s); // a record at net zero: the whole 4 USDC receipt is held
        } else {
            _mint(s, M, 10 * SHARE); // net 10: the 4 USDC receipt is all free cash
        }
        X.Order memory to = _order(t, M, 0, true, 70, 10 * SHARE);
        X.Order[] memory ms = _one(_order(s, M, 0, false, 40, 10 * SHARE));
        bytes memory d = abi.encodeCall(
            X.matchOrders, (to, _sign(tk, to), ms, _oneSig(_sign(sk, ms[0])), _oneFill(10 * SHARE), uint128(10 * SHARE))
        );
        vm.startStateDiffRecording();
        vm.prank(operator);
        (bool ok,) = address(ex).call(d);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        require(ok, "fixture: the match must settle");
        for (uint256 i; i < acc.length; ++i) {
            for (uint256 j; j < acc[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory sa = acc[i].storageAccesses[j];
                if (sa.account == address(ex) && sa.isWrite) ++n;
            }
        }
    }

    /// @dev Rule 3: the market slot the settlement writes is never zero while the market trades. A mint match writes
    /// collateral; before inclusion the only holder of sets merges them all away, so without a marker the slot is zero
    /// and the same write costs a zero-to-nonzero store instead of a rewrite.
    function test_gasMonotone_rule3_marketSlotStaysNonZero_whenEverySetIsMergedAway() public {
        delete ps;
        M = _market(3);
        (address t, uint256 tk) = _pair("r3-taker");
        (address a, uint256 ak) = _pair("r3-a");
        (address b, uint256 bk) = _pair("r3-b");
        _pair("r3-third");
        _pair("r3-third-b");
        address third = ps[3].a;
        _deposit(t, 100e6);
        _deposit(a, 100e6);
        _deposit(b, 100e6);
        _mint(third, M, 10 * SHARE); // the market's only sets
        X.Order memory to = _order(t, M, 0, true, 99, 10 * SHARE);
        X.Order[] memory ms = _two(_order(a, M, 1, true, 20, 10 * SHARE), _order(b, M, 2, true, 30, 10 * SHARE));
        data = abi.encodeCall(
            X.matchOrders,
            (
                to,
                _sign(tk, to),
                ms,
                _twoSig(_sign(ak, ms[0]), _sign(bk, ms[1])),
                _twoFill(10 * SHARE, 10 * SHARE),
                uint128(10 * SHARE)
            )
        );
        uint256 snap = vm.snapshotState();
        (bool ok0, uint256 est) = _gas(data);
        require(ok0, "fixture: the estimate must settle");
        vm.revertToState(snap);
        vm.prank(third);
        ex.mergeSets(M, 10 * SHARE); // collateral and feesHeld are both zero now
        (bool ok1, uint256 used) = _gas(data);
        require(ok1, "fixture: the call after the action must settle");
        assertLe(used, est + TOL_PER_PARTY * 3, "a third party's merge made matchOrders dearer than at the estimate");
    }

    /// @dev Rule 3, read straight from storage: both market slots that settlement writes (collateral and fees; profit and
    /// unwind pool) hold their marker byte from creation, through minting and merging everything away, trades, and
    /// the closing of trading.
    function test_marketMarkers_slotsAreNeverZeroWhileTheMarketTrades() public {
        M = _market(2);
        assertTrue(uint256(vm.load(address(ex), _marketSlot(M, 2))) != 0, "collateral/fees slot at creation");
        assertTrue(uint256(vm.load(address(ex), _marketSlot(M, 3))) != 0, "profit/pool slot at creation");
        (address a,) = makeAddrAndKey("mk-a");
        _mint(a, M, 10 * SHARE);
        vm.prank(a);
        ex.mergeSets(M, 10 * SHARE); // every set merged away: collateral is zero again
        assertEq(ex.marketOf(M).collateral, 0);
        assertEq(ex.marketOf(M).feesHeld, 0);
        assertTrue(uint256(vm.load(address(ex), _marketSlot(M, 2))) != 0, "collateral/fees slot with nothing in it");
        assertTrue(uint256(vm.load(address(ex), _marketSlot(M, 3))) != 0, "profit/pool slot with nothing in it");
        ex.closeEarly(M);
        assertTrue(uint256(vm.load(address(ex), _marketSlot(M, 2))) != 0);
        assertTrue(uint256(vm.load(address(ex), _marketSlot(M, 3))) != 0);
    }

    function _fundThird(address a, uint256 r) internal {
        _deposit(a, 1_000 * SHARE);
        if (r & 3 != 0) {
            vm.prank(a);
            ex.mintSets(M, _amt(r >> 8));
        }
    }
}
