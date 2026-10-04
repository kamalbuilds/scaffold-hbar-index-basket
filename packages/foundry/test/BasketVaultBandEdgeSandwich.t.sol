// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/Test.sol";
import { SignedMath } from "@openzeppelin/contracts/utils/math/SignedMath.sol";

import { BasketVault } from "../contracts/BasketVault.sol";
import { DepositSandwichHarness } from "./BasketVaultDepositSandwich.t.sol";

contract BasketVaultBandEdgeSandwichTest is DepositSandwichHarness {
    uint256 internal constant BAND = 500; // driftBps in the fixture
    uint256 internal constant WEIGHT = 3000; // SAUCE and USDC weightBps
    uint256 internal constant SWEEP = 288; // 4 pool/direction cases x 12 move sizes x 6 deposit sizes

    function setUp() public {
        _build(200_000, 10_000);
    }

    /// Reprices one leg's pool, WHBAR depth unchanged, until that leg is worth `pct` bps of NAV. Closed form: with
    /// the other holdings worth `rest`, the leg's value must be pct / (10_000 - pct) * rest.
    function _driftLeg(bool useUsdc, uint256 pct) internal {
        BasketVault.Holding[] memory rows = vault.holdings();
        uint256 legIdx = useUsdc ? 2 : 1;
        uint256 rest = vault.nav() - rows[legIdx].valueWhbar;
        uint256 want = pct * rest / (10_000 - pct);
        uint256 bal = (useUsdc ? usdc : sauce).balanceOf(address(vault));
        if (useUsdc) usdcPool.setReserves(depth * bal / want, depth); // token0 USDC, token1 WHBAR
        else saucePool.setReserves(depth, depth * bal / want); // token0 WHBAR, token1 SAUCE
    }

    function _legPct(bool useUsdc) internal view returns (uint256) {
        return vault.holdings()[useUsdc ? 2 : 1].valueWhbar * 10_000 / vault.nav();
    }

    /// Best attacker result over every pool, direction, move size and deposit size, from the drifted state.
    function _sweep() internal returns (int256 best, uint256 executed) {
        best = type(int256).min;
        _snapRefs();
        uint256 snap = vm.snapshotState();
        for (uint256 p; p < 4; ++p) {
            for (uint256 m; m < 12; ++m) {
                uint256 moveBps = m < 6 ? 100 * (m + 1) : 800 + 200 * (m - 5);
                for (uint256 d = 1; d <= 6; ++d) {
                    vm.revertToState(snap);
                    (bool ok, int256 profit) = _sandwich(p & 1 == 1, p >> 1 == 1, moveBps, d * 25_000 * HBAR);
                    if (!ok) continue;
                    ++executed;
                    if (profit > best) best = profit;
                }
            }
        }
        vm.revertToState(snap);
    }

    /// Drifts one leg `deltaBps` of NAV away from its 30% weight, then returns the attacker's best result over the sweep.
    function _edge(bool useUsdc, bool over, uint256 deltaBps) internal returns (int256 best, uint256 executed) {
        uint256 pct = over ? WEIGHT + deltaBps : WEIGHT - deltaBps;
        _driftLeg(useUsdc, pct);
        assertApproxEqAbs(_legPct(useUsdc), pct, 1, "leg sits at the requested drift");
        (best, executed) = _sweep();
        console.log(useUsdc ? "usdc" : "sauce", over ? "over, delta bps" : "under, delta bps", deltaBps);
        console.log("  executed", executed);
        console.logInt(best / int256(HBAR));
    }

    function _assertBounded(bool useUsdc, bool over, uint256 deltaBps) internal {
        (int256 best, uint256 executed) = _edge(useUsdc, over, deltaBps);
        assertEq(executed, SWEEP, "every sandwich in the grid ran the full path");
        assertLe(best, 0, "a deposit sandwich on a leg inside the allowed drift must not profit");
    }

    function _assertBroken(bool useUsdc, bool over, uint256 deltaBps, int256 minProfitHbar) internal {
        (int256 best, uint256 executed) = _edge(useUsdc, over, deltaBps);
        assertEq(executed, SWEEP, "every sandwich in the grid ran the full path");
        assertGe(best, minProfitHbar * int256(HBAR), "past the band the sandwich is profitable");
    }

    // At the band edge (driftBps = 500: a leg may sit at 35% or 25% of NAV before the keeper trades it back).
    // Measured best attacker result, 200k HBAR vault, 2M HBAR pools: sauce/usdc over -148 HBAR, under -162 HBAR.
    function test_bandEdge_sauceOver() public {
        _assertBounded(false, true, BAND);
    }

    function test_bandEdge_sauceUnder() public {
        _assertBounded(false, false, BAND);
    }

    function test_bandEdge_usdcOver() public {
        _assertBounded(true, true, BAND);
    }

    function test_bandEdge_usdcUnder() public {
        _assertBounded(true, false, BAND);
    }

    // At 3x the band the round-trip fee still outweighs the gain: -86 HBAR over, -144 HBAR under.
    function test_threeBands_sauceOver() public {
        _assertBounded(false, true, 3 * BAND);
    }

    function test_threeBands_sauceUnder() public {
        _assertBounded(false, false, 3 * BAND);
    }

    function test_threeBands_usdcOver() public {
        _assertBounded(true, true, 3 * BAND);
    }

    function test_threeBands_usdcUnder() public {
        _assertBounded(true, false, 3 * BAND);
    }

    // The break: the first measured profit is at 3.5x the band over (+510 HBAR). At 4x, over +1401 HBAR and under
    // +454 HBAR. A leg's weight in NAV sets how far a pool move shifts the NAV the attacker's shares are priced at,
    // while the round-trip fee is fixed, so the gain crosses zero between 3x and 3.5x. The band bounds it: a keeper
    // run trades a leg back inside it long before this drift, and one swap moves at most maxTradeBps (2000) of NAV.
    function test_beyondBand_sauceOver3p5x() public {
        _assertBroken(false, true, 1750, 400);
    }

    function test_beyondBand_sauceOver4x() public {
        _assertBroken(false, true, 4 * BAND, 1000);
    }

    function test_beyondBand_sauceUnder4x() public {
        _assertBroken(false, false, 4 * BAND, 300);
    }

    function test_beyondBand_usdcOver4x() public {
        _assertBroken(true, true, 4 * BAND, 1000);
    }

    function test_beyondBand_usdcUnder4x() public {
        _assertBroken(true, false, 4 * BAND, 300);
    }
}
