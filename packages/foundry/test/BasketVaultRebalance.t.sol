// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Test.sol";

import { BasketVault } from "../contracts/BasketVault.sol";
import { BasketVaultBase } from "./BasketVaultBase.sol";

contract BasketVaultRebalanceTest is BasketVaultBase {
    uint256 internal constant D1 = 1000e8;

    function setUp() public override {
        super.setUp();
        _deposit(alice, D1);
    }

    function _abs(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /// Asserts every holding sits within the drift band of its target weight.
    function _assertInBand() internal view {
        uint256[3] memory w = _weightsBps();
        BasketVault.Holding[] memory rows = vault.holdings();
        for (uint256 i; i < 3; ++i) {
            assertLe(_abs(w[i], rows[i].targetBps), DRIFT_BPS, "holding is outside the drift band");
        }
    }

    function test_rebalance_isANoOpWithinTheBand() public {
        uint256 swaps = router.swapCount();
        uint256 sauceBal = sauce.balanceOf(address(vault));
        uint256 whbarBal = whbar.balanceOf(address(vault));

        vm.prank(keeper);
        assertFalse(vault.rebalance());

        assertEq(router.swapCount(), swaps, "no trade");
        assertEq(sauce.balanceOf(address(vault)), sauceBal);
        assertEq(whbar.balanceOf(address(vault)), whbarBal);
    }

    function test_rebalance_isANoOpWhenSauceDriftsButStaysInsideTheBand() public {
        _scaleSaucePrice(105, 100);
        uint256[3] memory w = _weightsBps();
        assertGt(w[1], 3000, "SAUCE is overweight");
        assertLt(w[1], 3000 + DRIFT_BPS, "but not past the band");

        uint256 swaps = router.swapCount();
        assertFalse(vault.rebalance());
        assertEq(router.swapCount(), swaps);
    }

    function test_rebalance_isANoOpOnAnEmptyVault() public {
        BasketVault empty = _deployVault(_config(), _legs());
        vm.deal(owner, INIT_VALUE);
        vm.prank(owner);
        empty.initialize{ value: INIT_VALUE }("Empty", "EMP");
        assertFalse(empty.rebalance());
    }

    function test_rebalance_sellsTheOverweightLegThenBuysTheUnderweightOne() public {
        _scaleSaucePrice(2, 1); // SAUCE doubles: it is now about 46% of the basket
        uint256[3] memory before = _weightsBps();
        assertGt(before[1], 3000 + DRIFT_BPS, "SAUCE is overweight past the band");
        assertLt(before[2], 3000 - DRIFT_BPS, "USDC is underweight past the band");
        uint256 sauceBefore = sauce.balanceOf(address(vault));
        uint256 usdcBefore = usdc.balanceOf(address(vault));

        vm.recordLogs();
        vm.prank(keeper);
        bool traded = vault.rebalance();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(traded);
        assertLt(sauce.balanceOf(address(vault)), sauceBefore, "SAUCE was sold");
        assertGt(usdc.balanceOf(address(vault)), usdcBefore, "USDC was bought");
        _assertInBand();

        // The first swap sells SAUCE for WHBAR; the second spends WHBAR on USDC.
        bytes32 swapped = BasketVault.Swapped.selector;
        assertEq(_countOf(logs, swapped), 2);
        uint256 first = _indexOf(logs, swapped);
        assertEq(logs[first].topics[1], bytes32(uint256(uint160(SAUCE_ADDR))), "sell first: tokenIn is SAUCE");
        assertEq(logs[first].topics[2], bytes32(uint256(uint160(WHBAR_ADDR))));
        uint256 second;
        for (uint256 i = first + 1; i < logs.length; ++i) {
            if (logs[i].topics[0] == swapped) {
                second = i;
                break;
            }
        }
        assertEq(logs[second].topics[1], bytes32(uint256(uint160(WHBAR_ADDR))), "buy second: tokenIn is WHBAR");
        assertEq(logs[second].topics[2], bytes32(uint256(uint160(USDC_ADDR))));

        uint256 rebalanced = _indexOf(logs, BasketVault.Rebalanced.selector);
        assertLt(second, rebalanced);
        (uint256 navBefore, uint256 navAfter, bool tradedLogged) =
            abi.decode(logs[rebalanced].data, (uint256, uint256, bool));
        assertTrue(tradedLogged);
        assertGt(navBefore, D1, "NAV rose with the SAUCE price");
        assertLe(navAfter, navBefore, "swaps cost the pool fee, they never add value");
        assertApproxEqRel(navAfter, navBefore, 1e16, "and the cost is a fraction of a percent");
    }

    function test_rebalance_buysAreFundedByTheSalesWhenWhbarAloneCouldNotPayForThem() public {
        // WHBAR is 2% of this basket, so the USDC buy can only be paid for with what SAUCE sells for.
        BasketVault.LegConfig[] memory legs = _legs();
        legs[0].weightBps = 4900;
        legs[1].weightBps = 4900;
        vault = _deployVault(_config(), legs);
        _initialize();
        _fund(alice);
        _deposit(alice, D1);
        _scaleSaucePrice(3, 1);

        BasketVault.Holding[] memory rows = vault.holdings();
        uint256 deficit = vault.nav() * 4900 / 10_000 - rows[2].valueWhbar;
        assertGt(deficit, whbar.balanceOf(address(vault)) * 5, "the WHBAR on hand is nowhere near the USDC deficit");

        assertTrue(vault.rebalance());
        uint256[3] memory w = _weightsBps();
        assertApproxEqAbs(w[1], 4900, DRIFT_BPS);
        assertApproxEqAbs(w[2], 4900, DRIFT_BPS);
        assertApproxEqAbs(w[0], 200, DRIFT_BPS);
    }

    function test_rebalance_isPermissionless() public {
        _scaleSaucePrice(2, 1);
        vm.prank(makeAddr("stranger"));
        assertTrue(vault.rebalance());
        _assertInBand();
    }

    function test_rebalance_afterItTradesTheNextCallIsANoOp() public {
        _scaleSaucePrice(2, 1);
        assertTrue(vault.rebalance());
        uint256 swaps = router.swapCount();
        assertFalse(vault.rebalance());
        assertEq(router.swapCount(), swaps);
    }

    function test_rebalance_rebalancesBackWhenThePriceMovesTheOtherWay() public {
        _scaleSaucePrice(1, 2); // SAUCE halves: underweight, WHBAR and USDC overweight
        uint256[3] memory before = _weightsBps();
        assertLt(before[1], 3000 - DRIFT_BPS);
        uint256 sauceBefore = sauce.balanceOf(address(vault));
        assertTrue(vault.rebalance());
        assertGt(sauce.balanceOf(address(vault)), sauceBefore, "SAUCE was bought back up to weight");
        _assertInBand();
    }

    function test_rebalance_revertsWhenTheFillIsWorseThanSlippageAllows() public {
        _scaleSaucePrice(2, 1);
        router.setHaircutBps(100);
        uint256 sauceBefore = sauce.balanceOf(address(vault));
        vm.expectRevert(bytes("Too little received"));
        vault.rebalance();
        assertEq(sauce.balanceOf(address(vault)), sauceBefore, "nothing was sold");
    }

    function test_rebalance_passesMinOutBelowTheExcessItSells() public {
        _scaleSaucePrice(2, 1);
        vm.recordLogs();
        vault.rebalance();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 first = _indexOf(logs, BasketVault.Swapped.selector);
        (uint256 amountIn, uint256 amountOut) = abi.decode(logs[first].data, (uint256, uint256));
        assertGt(amountIn, 0);
        // Sold at 0.3% fee: out is within the 1% tolerance the vault set as minimum, so it passed.
        uint256 spotValue = amountIn * 2 * SAUCE_PRICE_NUM / SAUCE_PRICE_DEN;
        assertGe(amountOut, spotValue * 99 / 100);
        assertLt(amountOut, spotValue);
    }

    function test_rebalance_approvesTheSoldLegOnceForItsSupply() public {
        assertEq(sauce.approveCount(), 0);
        _scaleSaucePrice(2, 1);
        uint256 supplyBefore = sauce.totalSupply();
        vault.rebalance();
        assertEq(sauce.approveCount(), 1);
        assertEq(sauce.lastApproveValue(), supplyBefore, "approves the total supply, which HTS accepts for any cap");
        assertGt(sauce.allowance(address(vault), address(router)), 0, "and the rest stays for the next sale");
    }

    function test_rebalance_revertsWhenOracleIsStale() public {
        _scaleSaucePrice(2, 1);
        vm.warp(T0 + MAX_ORACLE_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StaleOracle.selector, T0));
        vault.rebalance();
    }
}

contract BasketVaultGuardTest is BasketVaultBase {
    uint256 internal constant D1 = 1000e8;

    function setUp() public override {
        super.setUp();
        _deposit(alice, D1);
    }

    function decodeTail(bytes calldata data) external pure returns (uint256 implied, uint256 oracle) {
        return abi.decode(data[4:], (uint256, uint256));
    }

    function _deviation() internal returns (uint256 implied, uint256 oracle) {
        vm.prank(bob);
        (bool ok, bytes memory ret) = address(vault).call{ value: 10e8 }(abi.encodeCall(vault.deposit, (0)));
        assertFalse(ok, "deposit should have reverted");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(bytes4(ret), BasketVault.PoolPriceDeviates.selector);
        return this.decodeTail(ret);
    }

    function test_guard_depositPassesWhenThePoolAgreesWithChainlinkWithinTolerance() public {
        _scaleUsdcPrice(97, 100); // 3% under the oracle, inside the 5% limit
        assertGt(_deposit(bob, 100e8), 0);
        _scaleUsdcPrice(103, 100);
        assertGt(_deposit(bob, 100e8), 0);
    }

    function test_guard_depositRevertsWhenThePoolIsFarBelowTheOracle() public {
        _scaleUsdcPrice(8, 10); // 1 USDC buys 20% fewer HBAR: implied HBAR/USD is 25% above the oracle
        (uint256 implied, uint256 oracle) = _deviation();
        assertEq(oracle, HBAR_USD_U);
        assertApproxEqRel(implied, 25_000_000, 1e12);
    }

    function test_guard_depositRevertsWhenThePoolIsFarAboveTheOracle() public {
        _scaleUsdcPrice(12, 10);
        (uint256 implied,) = _deviation();
        assertApproxEqRel(implied, 16_666_666, 1e12);
    }

    function test_guard_revertsWhenTheOracleMovesAndThePoolDoesNot() public {
        feed.set(HBAR_USD * 2, block.timestamp);
        (uint256 implied, uint256 oracle) = _deviation();
        assertEq(oracle, HBAR_USD_U * 2);
        assertApproxEqRel(implied, HBAR_USD_U, 1e12);
    }

    function test_guard_revertsWhenThePoolPriceIsZeroInWhbar() public {
        usdcPool.setSqrtPriceX96(uint160(uint256(2 ** 96) / 10_000)); // 1e-8 raw WHBAR per raw USDC rounds to nothing
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.PoolPriceDeviates.selector, 0, HBAR_USD_U));
        vault.deposit{ value: 10e8 }(0);
    }

    function test_guard_rebalanceIsGuardedToo() public {
        _scaleSaucePrice(2, 1);
        _scaleUsdcPrice(8, 10);
        vm.expectPartialRevert(BasketVault.PoolPriceDeviates.selector);
        vault.rebalance();

        _scaleUsdcPrice(1, 1);
        assertTrue(vault.rebalance());
    }

    function test_guard_aMoveInTheNonGuardLegDoesNotTripIt() public {
        _scaleSaucePrice(3, 1);
        assertGt(_deposit(bob, 100e8), 0);
    }

    function test_guard_isOffWhenNoGuardLegIsSet() public {
        BasketVault.Config memory c = _config();
        c.guardLeg = type(uint256).max;
        vault = _deployVault(c, _legs());
        _initialize();
        _fund(alice);

        _scaleUsdcPrice(1, 3); // far off the oracle, but nothing checks it
        assertGt(_deposit(alice, 100e8), 0);

        // Freshness is still enforced.
        vm.warp(T0 + MAX_ORACLE_AGE + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StaleOracle.selector, T0));
        vault.deposit{ value: 100e8 }(0);
    }
}

contract BasketVaultViewsTest is BasketVaultBase {
    uint256 internal constant D1 = 1000e8;

    function test_views_areZeroBeforeTheFirstDeposit() public view {
        assertEq(vault.nav(), 0);
        assertEq(vault.navUsd(), 0);
        assertEq(vault.sharePriceUsd(), 0);
        BasketVault.Holding[] memory rows = vault.holdings();
        assertEq(rows.length, 3);
        assertEq(rows[0].balance + rows[1].balance + rows[2].balance, 0);
    }

    function test_views_sharePriceIsZeroBeforeInitialize() public {
        BasketVault v = _deployVault(_config(), _legs());
        assertEq(v.sharePriceUsd(), 0);
        assertEq(v.nav(), 0);
    }

    function test_views_holdingsMatchBalancesTargetsAndNav() public {
        _deposit(alice, D1);
        BasketVault.Holding[] memory rows = vault.holdings();
        assertEq(rows.length, 3);
        assertEq(rows[0].token, WHBAR_ADDR);
        assertEq(rows[1].token, SAUCE_ADDR);
        assertEq(rows[2].token, USDC_ADDR);
        assertEq(rows[0].balance, whbar.balanceOf(address(vault)));
        assertEq(rows[1].balance, sauce.balanceOf(address(vault)));
        assertEq(rows[2].balance, usdc.balanceOf(address(vault)));
        assertEq(rows[0].valueWhbar, rows[0].balance, "WHBAR is its own unit");
        assertEq(rows[0].targetBps, 4000);
        assertEq(rows[1].targetBps, 3000);
        assertEq(rows[2].targetBps, 3000);
        assertApproxEqRel(rows[1].valueWhbar, rows[1].balance * SAUCE_PRICE_NUM / SAUCE_PRICE_DEN, 1e12);
        assertApproxEqRel(rows[2].valueWhbar, rows[2].balance * USDC_PRICE_NUM / USDC_PRICE_DEN, 1e12);
        assertEq(rows[0].valueWhbar + rows[1].valueWhbar + rows[2].valueWhbar, vault.nav(), "rows add up to NAV");
    }

    function test_views_navUsdAndSharePriceFollowChainlink() public {
        uint256 shares = _deposit(alice, D1);
        uint256 supply = share.totalSupply();
        assertGt(shares, 0);

        assertEq(vault.hbarUsd(), HBAR_USD_U);
        assertEq(vault.navUsd(), vault.nav() * HBAR_USD_U / 1e8);
        assertEq(vault.sharePriceUsd(), vault.navUsd() * 1e8 / supply);
        // One share launched at one HBAR, which is 0.20 USD.
        assertApproxEqRel(vault.sharePriceUsd(), 20_000_000, 1e12);

        feed.set(HBAR_USD * 2, block.timestamp);
        assertApproxEqRel(vault.sharePriceUsd(), 40_000_000, 1e12, "doubling the oracle doubles the share price");
    }

    function test_views_sharePriceRisesWhenTheBasketsLegsRise() public {
        _deposit(alice, D1);
        uint256 before = vault.sharePriceUsd();
        _setPrice(saucePool, SAUCE_ADDR, SAUCE_PRICE_NUM * 2, SAUCE_PRICE_DEN);
        uint256 afterMove = vault.sharePriceUsd();
        // SAUCE is about 30% of the basket, so doubling it adds about 30%.
        assertApproxEqRel(afterMove, before * 130 / 100, 1e16);
    }

    function test_views_navUsdRevertsOnStaleOrBrokenOracle() public {
        _deposit(alice, D1);
        vm.warp(T0 + MAX_ORACLE_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StaleOracle.selector, T0));
        vault.navUsd();
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StaleOracle.selector, T0));
        vault.sharePriceUsd();

        feed.set(-1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.BadOraclePrice.selector, int256(-1)));
        vault.hbarUsd();
    }

    function test_views_navIsStillReadableWithAStaleOracle() public {
        _deposit(alice, D1);
        vm.warp(T0 + MAX_ORACLE_AGE + 1);
        assertGt(vault.nav(), 0, "WHBAR NAV needs no oracle");
        assertEq(vault.holdings().length, 3);
    }
}
