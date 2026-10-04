// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/Test.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { SignedMath } from "@openzeppelin/contracts/utils/math/SignedMath.sol";

import { CpFixture } from "./BasketVaultSandwich.t.sol";
import { CpPool } from "./mocks/CpAmm.sol";

/// Deposit-side manipulation against `slot0` spot pricing. The attacker moves a constant-product pool, deposits at the
/// distorted NAV, moves the pool back and redeems in kind. Every swap moves the price and charges the pool fee, so the
/// attacker pays for both legs of the move. The attacker's wealth is valued at the pre-attack reserves, in WHBAR tinybar,
/// and includes native HBAR, so a profit anywhere in the round trip shows up as a positive difference.
contract BasketVaultDepositSandwichTest is CpFixture {
    /// Arbitrary pool-trading budget minted to the attacker. It counts on both sides of the profit, so it cancels.
    uint256 private constant BUDGET = 1_000_000 * HBAR;
    uint256 private constant BUDGET_TOKENS = 1e15;

    uint256 private refSauce0;
    uint256 private refSauce1;
    uint256 private refUsdc0;
    uint256 private refUsdc1;

    function setUp() public {
        // A 200k HBAR vault in 2M HBAR pools: the fixture the teardown probed. A deposit of 200k HBAR or more reverts
        // on the 3% slippage floor, so the sweeps stop at 150k.
        _build(200_000, 10_000);
        (refSauce0, refSauce1) = (saucePool.r0(), saucePool.r1());
        (refUsdc0, refUsdc1) = (usdcPool.r0(), usdcPool.r1());
    }

    /// SAUCE and USDC priced at the pre-attack pools; WHBAR and native HBAR at par.
    function _valueAtRef(address who) internal view returns (uint256) {
        return whbar.balanceOf(who) + who.balance + sauce.balanceOf(who) * refSauce0 / refSauce1 + usdc.balanceOf(who)
            * refUsdc1 / refUsdc0;
    }

    /// Swaps `tokenIn` into `pool` until its reserve ratio is back at `ref0 / ref1`. The first swap moved it one way,
    /// so the restoring swap is the opposite token, sized by bisection.
    function _restore(CpPool pool, uint256 ref0, uint256 ref1) internal {
        bool above = pool.r0() * ref1 > ref0 * pool.r1(); // r0/r1 is above the reference: add token1
        address tokenIn = above ? pool.token1() : pool.token0();
        address tokenOut = above ? pool.token0() : pool.token1();
        uint256 lo;
        uint256 hi = above ? pool.r1() : pool.r0();
        for (uint256 i; i < 80; ++i) {
            uint256 mid = (lo + hi) / 2;
            uint256 out = pool.quote(tokenIn, mid);
            uint256 n0 = above ? pool.r0() - out : pool.r0() + mid;
            uint256 n1 = above ? pool.r1() + mid : pool.r1() - out;
            if (above ? n0 * ref1 >= ref0 * n1 : n0 * ref1 <= ref0 * n1) lo = mid;
            else hi = mid;
        }
        if (lo == 0) return;
        _swap(attacker, tokenIn, tokenOut, lo);
    }

    /// One full sandwich. `useUsdc` picks the pool, `pump` the direction of the first move (buy the leg token with
    /// WHBAR, or dump it for WHBAR), `moveBps` its size as a share of the input-side reserve. Returns executed=false
    /// when the vault refuses the deposit (slippage floor), which is a failed attack and not a profit.
    function _sandwich(bool useUsdc, bool pump, uint256 moveBps, uint256 depositHbar)
        internal
        returns (bool executed, int256 profit)
    {
        CpPool pool = useUsdc ? usdcPool : saucePool;
        (uint256 ref0, uint256 ref1) = (pool.r0(), pool.r1());

        whbar.mint(attacker, BUDGET);
        sauce.mint(attacker, BUDGET_TOKENS);
        usdc.mint(attacker, BUDGET_TOKENS);
        vm.deal(attacker, depositHbar);
        uint256 before = _valueAtRef(attacker);

        // The leg token is token0 of the USDC pool and token1 of the SAUCE pool; WHBAR is the other side.
        address legToken = useUsdc ? USDC_ADDR : SAUCE_ADDR;
        uint256 legReserve = useUsdc ? ref0 : ref1;
        uint256 whbarReserve = useUsdc ? ref1 : ref0;
        if (pump) _swap(attacker, WHBAR_ADDR, legToken, whbarReserve * moveBps / 10_000);
        else _swap(attacker, legToken, WHBAR_ADDR, legReserve * moveBps / 10_000);

        vm.prank(attacker);
        try vault.deposit{ value: depositHbar }(0) {
            executed = true;
        } catch {
            return (false, 0);
        }

        _restore(pool, ref0, ref1);

        uint256 held = share.balanceOf(attacker);
        vm.prank(attacker);
        vault.redeem(held);

        uint256 afterValue = _valueAtRef(attacker);
        profit = SafeCast.toInt256(afterValue) - SafeCast.toInt256(before);
    }

    /// Fuzzes the pool, the direction, the move size (0.5% to 15% of the reserve it trades into) and the deposit size
    /// (10k to 150k HBAR on a 200k HBAR vault). The attacker never gains.
    function test_regression_depositSandwichLosesMoney(bool useUsdc, bool pump, uint256 moveSeed, uint256 depositSeed)
        public
    {
        uint256 moveBps = bound(moveSeed, 50, 1500);
        uint256 deposit = bound(depositSeed, 10_000, 150_000) * HBAR;
        (bool executed, int256 profit) = _sandwich(useUsdc, pump, moveBps, deposit);
        if (executed) assertLe(profit, 0, "a deposit sandwich on constant-product pools must not profit");
    }

    /// The teardown's 50 configurations: SAUCE dumps of k * depth / 200 for k in 1..10 against deposits of 30k to 150k
    /// HBAR. Every one executes, every one loses.
    function test_regression_depositSandwichLosesMoney_teardownGrid() public {
        uint256 snap = vm.snapshotState();
        uint256 executedCount;
        int256 best = type(int256).min;
        for (uint256 k = 1; k <= 10; ++k) {
            for (uint256 d = 1; d <= 5; ++d) {
                vm.revertToState(snap);
                // k * depth / 200 raw SAUCE is k * 1.25% of the 0.4 * depth SAUCE reserve.
                (bool executed, int256 profit) = _sandwich(false, false, k * 125, d * 30_000 * HBAR);
                if (!executed) continue;
                ++executedCount;
                if (profit > best) best = profit;
                assertLt(profit, 0, "this configuration lost money");
            }
        }
        console.log("configs executed", executedCount);
        console.log("best attacker result (negative = loss), HBAR", SignedMath.abs(best) / HBAR);
        assertEq(executedCount, 50, "all 50 configurations ran the full sandwich");
    }
}
