// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BasketVault } from "../contracts/BasketVault.sol";
import { MockHtsToken } from "./mocks/MockHtsToken.sol";
import { BasketVaultBase } from "./BasketVaultBase.sol";

contract BasketVaultDepositTest is BasketVaultBase {
    uint256 internal constant D1 = 1000e8;
    uint256 internal constant D2 = 500e8;

    /// Fee the pools take from a deposit of `amount` spread over the two legs at 30% each.
    function _poolFees(uint256 amount) internal pure returns (uint256) {
        uint256 spend = amount * 3000 / 10_000;
        return spend * SAUCE_FEE / 1_000_000 + spend * USDC_FEE / 1_000_000;
    }

    function test_firstDeposit_locksDeadSharesAndMintsTheRestToTheDepositor() public {
        uint256 valueAdded = D1 - _poolFees(D1);
        uint256 shares = _deposit(alice, D1);

        // A raw USDC unit is worth 500 tinybars, so the router and valuation floors move this by hundreds.
        assertApproxEqRel(share.totalSupply(), valueAdded, 1e11, "first deposit mints one share per WHBAR of value");
        assertEq(share.balanceOf(address(vault)), vault.DEAD_SHARES(), "dead shares stay in the treasury");
        assertEq(shares, share.totalSupply() - vault.DEAD_SHARES(), "depositor gets valueAdded minus the dead shares");
        assertEq(share.balanceOf(alice), shares);
        assertEq(vault.DEAD_SHARES(), 1e5);
    }

    function test_firstDeposit_buysEachLegAtItsTargetWeightLessFees() public {
        uint256 shares = _deposit(alice, D1);
        assertGt(shares, 0);

        uint256 spend = D1 * 3000 / 10_000;
        uint256 expectedSauce = spend * SAUCE_PRICE_DEN / SAUCE_PRICE_NUM * (1_000_000 - SAUCE_FEE) / 1_000_000;
        uint256 expectedUsdc = spend * USDC_PRICE_DEN / USDC_PRICE_NUM * (1_000_000 - USDC_FEE) / 1_000_000;
        assertApproxEqRel(sauce.balanceOf(address(vault)), expectedSauce, 1e12);
        assertApproxEqRel(usdc.balanceOf(address(vault)), expectedUsdc, 1e12);
        assertEq(whbar.balanceOf(address(vault)), D1 - 2 * spend, "the WHBAR leg is what the legs leave");
        assertEq(router.swapCount(), 2);

        uint256[3] memory w = _weightsBps();
        assertApproxEqAbs(w[0], 4000, 10);
        assertApproxEqAbs(w[1], 3000, 10);
        assertApproxEqAbs(w[2], 3000, 10);
    }

    function test_deposit_wrapsTheHbarAndKeepsNoneNative() public {
        uint256 fuelBefore = address(vault).balance;
        _deposit(alice, D1);
        assertEq(helper.depositCount(), 1);
        assertEq(address(vault).balance, fuelBefore, "deposited HBAR becomes WHBAR, not vault fuel");
    }

    function test_deposit_emitsDeposited() public {
        vm.expectEmit(true, false, false, false, address(vault));
        emit BasketVault.Deposited(alice, D1, 0, 0);
        _deposit(alice, D1);
    }

    function test_deposit_revertsBelowMinShares() public {
        uint256 snap = vm.snapshotState();
        uint256 shares = _deposit(alice, D1);
        vm.revertToState(snap);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.InsufficientShares.selector, shares, shares + 1));
        vault.deposit{ value: D1 }(shares + 1);

        vm.prank(alice);
        assertEq(vault.deposit{ value: D1 }(shares), shares, "exactly minShares is accepted");
    }

    function test_deposit_revertsOnZeroValue() public {
        vm.prank(alice);
        vm.expectRevert(BasketVault.ZeroAmount.selector);
        vault.deposit{ value: 0 }(0);
    }

    function test_deposit_dustThatWouldAllBecomeDeadSharesReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.InsufficientShares.selector, 0, 0));
        vault.deposit{ value: 1e5 }(0);
        assertEq(share.totalSupply(), 0);
    }

    function test_deposit_revertsWhenOracleIsStale() public {
        vm.warp(T0 + MAX_ORACLE_AGE);
        _deposit(alice, D1); // exactly at the limit is still fresh

        vm.warp(T0 + MAX_ORACLE_AGE + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StaleOracle.selector, T0));
        vault.deposit{ value: D2 }(0);
    }

    function test_deposit_revertsOnNonPositiveOracleAnswer() public {
        feed.set(0, T0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.BadOraclePrice.selector, int256(0)));
        vault.deposit{ value: D1 }(0);

        feed.set(-5, T0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.BadOraclePrice.selector, int256(-5)));
        vault.deposit{ value: D1 }(0);
    }

    function test_deposit_revertsWhenDepositorIsNotAssociatedWithTheShareToken() public {
        address carol = makeAddr("carol");
        vm.deal(carol, 2 * D1);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(MockHtsToken.TokenNotAssociatedToAccount.selector, carol));
        vault.deposit{ value: D1 }(0);
        assertEq(share.totalSupply(), 0, "the mint rolled back with the revert");
    }

    function test_deposit_revertsWhenHtsMintFails() public {
        hts.setForcedCodes(0, int64(8), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.HtsCallFailed.selector, int64(8)));
        vault.deposit{ value: D1 }(0);
    }

    function test_deposit_revertsWhenSwapFallsBelowSlippage() public {
        // 0.3% pool fee plus a 1% worse market is past the vault's 1% tolerance on the SAUCE leg.
        router.setHaircutBps(100);
        vm.prank(alice);
        vm.expectRevert(bytes("Too little received"));
        vault.deposit{ value: D1 }(0);
        assertEq(share.totalSupply(), 0);
        assertEq(whbar.totalSupply(), 0, "the wrap rolled back too");
    }

    function test_deposit_passesTheSlippageMinOutToTheRouter() public {
        _deposit(alice, D1);
        // Last swap was the USDC leg: minOut is spot value less the 1% tolerance, before the pool fee.
        uint256 spend = D1 * 3000 / 10_000;
        uint256 spotOut = spend * USDC_PRICE_DEN / USDC_PRICE_NUM;
        assertEq(router.lastAmountIn(), spend);
        assertApproxEqRel(router.lastAmountOutMinimum(), spotOut * 99 / 100, 1e12);
    }

    // ---------------------------------------------------------------- second depositor

    function test_secondDeposit_getsSharesProportionalToValueAddedAndDoesNotDiluteTheFirstHolder() public {
        uint256 aliceShares = _deposit(alice, D1);
        uint256 supply1 = share.totalSupply();
        uint256 nav1 = vault.nav();
        uint256 aliceValue1 = _valueOf(aliceShares);

        uint256 bobShares = _deposit(bob, D2);
        uint256 supply2 = share.totalSupply();
        uint256 nav2 = vault.nav();

        uint256 valueAdded2 = D2 - _poolFees(D2);
        assertApproxEqRel(bobShares, valueAdded2 * supply1 / nav1, 1e12, "shares are proportional to value added");
        assertLt(bobShares, D2, "the depositor's shares reflect fees, not the full HBAR sent");
        assertEq(supply2, supply1 + bobShares);
        assertGe(nav2 * supply1, nav1 * supply2, "NAV per share never falls on a deposit");
        assertGe(_valueOf(aliceShares), aliceValue1, "the first holder's redeemable value does not drop");
        assertApproxEqRel(_valueOf(bobShares), valueAdded2, 1e12, "bob owns the value he added");
    }

    function test_secondDeposit_priceImpactAndFeesAreBorneByTheDepositor() public {
        uint256 aliceShares = _deposit(alice, D1);
        uint256 snap = vm.snapshotState();

        // Baseline: what bob gets with the pools' own fees only.
        uint256 baseline = _deposit(bob, D2);
        vm.revertToState(snap);

        // A market 0.5% worse than spot on top of the fee: still inside the 1% tolerance.
        router.setHaircutBps(50);
        uint256 supply1 = share.totalSupply();
        uint256 nav1 = vault.nav();
        uint256 aliceValue1 = _valueOf(aliceShares);
        uint256 bobShares = _deposit(bob, D2);

        assertLt(bobShares, baseline, "a worse fill costs the depositor shares");
        assertGe(vault.nav() * supply1, nav1 * share.totalSupply(), "NAV per share does not fall");
        assertGe(_valueOf(aliceShares), aliceValue1, "the first holder pays nothing for bob's slippage");
        // Bob's slice is worth what he actually bought (fee and haircut taken off each leg), less than the HBAR he
        // sent: the whole shortfall is his.
        uint256 spend = D2 * 3000 / 10_000;
        uint256 bought = spend * (1_000_000 - SAUCE_FEE) / 1_000_000 * 9950 / 10_000 + spend * (1_000_000 - USDC_FEE)
            / 1_000_000 * 9950 / 10_000;
        assertLt(_valueOf(bobShares), D2);
        assertApproxEqRel(_valueOf(bobShares), D2 - 2 * spend + bought, 1e11);
    }

    function test_deposit_onlyApprovesWhenAllowanceIsShort() public {
        _deposit(alice, D1);
        // Two WHBAR spends in one deposit, one approval: the first covers the second.
        assertEq(whbar.approveCount(), 1);
        assertEq(whbar.lastApproveValue(), D1, "approves the token's total supply, the cap HTS accepts");
        assertEq(whbar.allowance(address(vault), address(router)), D1 - 2 * (D1 * 3000 / 10_000));
        assertEq(sauce.approveCount(), 0, "the vault never spends a leg token on a deposit");

        // A small deposit fits inside the 40% of allowance left over.
        _deposit(bob, 50e8);
        assertEq(whbar.approveCount(), 1, "no new approval while allowance covers the spend");

        // A large one does not.
        uint256 allowance = whbar.allowance(address(vault), address(router));
        uint256 big = 10_000e8;
        assertLt(allowance, big * 3000 / 10_000);
        _deposit(bob, big);
        assertEq(whbar.approveCount(), 2, "approval renewed once, not once per leg");
    }

    function test_deposit_isNotBlockedByAnotherHoldersDonationToTheVault() public {
        // Attacker takes the smallest deposit that mints any shares, then donates to inflate NAV per share.
        uint256 attackerShares = _deposit(alice, 200_000);
        assertGt(attackerShares, 0);
        uint256 donation = 1000e8;
        whbar.mint(address(vault), donation);

        uint256 bobValueAdded = D2 - _poolFees(D2);
        uint256 bobShares = _deposit(bob, D2);
        assertGt(bobShares, 0, "the dead shares keep the victim from rounding to zero");
        assertApproxEqRel(_valueOf(bobShares), bobValueAdded, 1e15, "the victim keeps his value");

        (uint256 w, uint256[] memory legs) = _redeem(alice, attackerShares);
        assertLt(_bundleValue(w, legs), 200_000 + donation, "the donation is mostly lost to the dead shares");
    }

    // ---------------------------------------------------------------- redeem

    function _twoDepositors() internal returns (uint256 aliceShares, uint256 bobShares) {
        aliceShares = _deposit(alice, D1);
        bobShares = _deposit(bob, D2);
    }

    function test_redeem_paysProRataInKindForEveryTokenAndBurnsShares() public {
        (, uint256 bobShares) = _twoDepositors();
        uint256 supply = share.totalSupply();
        uint256 vw = whbar.balanceOf(address(vault));
        uint256 vs = sauce.balanceOf(address(vault));
        uint256 vu = usdc.balanceOf(address(vault));
        assertGt(vs, 0);
        assertGt(vu, 0);

        (uint256 whbarOut, uint256[] memory legs) = _redeem(bob, bobShares);

        assertEq(whbarOut, vw * bobShares / supply);
        assertEq(legs.length, 2);
        assertEq(legs[0], vs * bobShares / supply);
        assertEq(legs[1], vu * bobShares / supply);
        assertEq(whbar.balanceOf(bob), whbarOut);
        assertEq(sauce.balanceOf(bob), legs[0]);
        assertEq(usdc.balanceOf(bob), legs[1]);
        assertEq(whbar.balanceOf(address(vault)), vw - whbarOut);
        assertEq(sauce.balanceOf(address(vault)), vs - legs[0]);
        assertEq(usdc.balanceOf(address(vault)), vu - legs[1]);

        assertEq(share.balanceOf(bob), 0);
        assertEq(share.totalSupply(), supply - bobShares, "the shares are burned, not parked");
        assertEq(hts.burnCount(), 1);
        assertEq(
            share.balanceOf(address(vault)), vault.DEAD_SHARES(), "nothing but the dead shares is left in the vault"
        );
    }

    function test_redeem_partialLeavesTheRestOfTheHolding() public {
        uint256 aliceShares = _deposit(alice, D1);
        uint256 half = aliceShares / 2;
        _redeem(alice, half);
        assertEq(share.balanceOf(alice), aliceShares - half);
        _redeem(alice, aliceShares - half);
        assertEq(share.balanceOf(alice), 0);
        assertEq(share.totalSupply(), vault.DEAD_SHARES());
    }

    function test_redeem_everyoneOutLeavesOnlyDustForTheDeadShares() public {
        (uint256 aliceShares, uint256 bobShares) = _twoDepositors();
        _redeem(alice, aliceShares);
        _redeem(bob, bobShares);
        assertEq(share.totalSupply(), vault.DEAD_SHARES());
        uint256 dust = vault.nav();
        assertGt(dust, 0, "the dead shares own a sliver of the basket");
        assertLt(dust, 1e6, "and it is worth far less than a hundredth of an HBAR");

        // The vault is still usable: a new depositor buys in at NAV per share, not at a broken price.
        uint256 carolValueAdded = D2 - _poolFees(D2);
        uint256 carolShares = _deposit(alice, D2);
        assertApproxEqRel(_valueOf(carolShares), carolValueAdded, 1e12, "she owns the value she added");
    }

    function test_redeem_worksWithStaleOracleWhereDepositReverts() public {
        (uint256 aliceShares,) = _twoDepositors();
        vm.warp(T0 + MAX_ORACLE_AGE + 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StaleOracle.selector, T0));
        vault.deposit{ value: D2 }(0);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.StaleOracle.selector, T0));
        vault.hbarUsd();

        (uint256 whbarOut, uint256[] memory legs) = _redeem(alice, aliceShares);
        assertGt(whbarOut, 0);
        assertGt(legs[0], 0);
        assertGt(legs[1], 0);
        assertEq(share.balanceOf(alice), 0);
    }

    function test_redeem_worksWhenTheGuardPoolIsBroken() public {
        uint256 aliceShares = _deposit(alice, D1);
        _scaleUsdcPrice(1, 3); // USDC pool at a third of the oracle price: the deposit guard trips
        vm.prank(bob);
        vm.expectPartialRevert(BasketVault.PoolPriceDeviates.selector);
        vault.deposit{ value: D2 }(0);

        (uint256 whbarOut,) = _redeem(alice, aliceShares);
        assertGt(whbarOut, 0, "exits never depend on a price");
    }

    function test_redeem_requiresShareAllowance() public {
        uint256 aliceShares = _deposit(alice, D1);

        vm.prank(alice);
        vm.expectRevert(bytes(""));
        vault.redeem(aliceShares);

        vm.startPrank(alice);
        share.approve(address(vault), aliceShares - 1);
        vm.expectRevert(bytes(""));
        vault.redeem(aliceShares);
        vm.stopPrank();
        assertEq(share.balanceOf(alice), aliceShares, "a failed redeem leaves the shares where they were");

        (uint256 whbarOut,) = _redeem(alice, aliceShares);
        assertGt(whbarOut, 0);
    }

    function test_redeem_revertsWhenShareTransferReturnsFalse() public {
        uint256 aliceShares = _deposit(alice, D1);
        share.setQuietFailure(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.TransferFailed.selector, address(share)));
        vault.redeem(aliceShares);
    }

    function test_redeem_revertsWhenHtsBurnFails() public {
        uint256 aliceShares = _deposit(alice, D1);
        hts.setForcedCodes(0, 0, int64(8));
        vm.startPrank(alice);
        share.approve(address(vault), aliceShares);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.HtsCallFailed.selector, int64(8)));
        vault.redeem(aliceShares);
        vm.stopPrank();
    }

    function test_redeem_revertsOnZeroShares() public {
        _deposit(alice, D1);
        vm.prank(alice);
        vm.expectRevert(BasketVault.ZeroAmount.selector);
        vault.redeem(0);
    }

    function test_redeem_revertsWhenRedeemerIsNotAssociatedWithAPayoutToken() public {
        uint256 aliceShares = _deposit(alice, D1);
        address carol = makeAddr("carol");
        vm.prank(carol);
        share.associate();
        vm.prank(alice);
        assertTrue(share.transfer(carol, aliceShares));

        vm.startPrank(carol);
        share.approve(address(vault), aliceShares);
        vm.expectRevert(abi.encodeWithSelector(MockHtsToken.TokenNotAssociatedToAccount.selector, carol));
        vault.redeem(aliceShares);
        vm.stopPrank();
        assertEq(share.balanceOf(carol), aliceShares, "the whole redemption rolled back");
    }

    function test_redeem_emitsRedeemed() public {
        uint256 aliceShares = _deposit(alice, D1);
        vm.startPrank(alice);
        share.approve(address(vault), aliceShares);
        vm.expectEmit(true, false, false, false, address(vault));
        emit BasketVault.Redeemed(alice, aliceShares, 0, new uint256[](0));
        vault.redeem(aliceShares);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- fuzz

    /// A depositor who buys in and immediately redeems everything gets back no more value than he put in, and the
    /// holder who was already there never ends up worse off.
    function testFuzz_depositRedeemRoundTripNeverPaysMore(uint256 amount, uint256 seed, uint256 haircutBps) public {
        amount = bound(amount, 1e6, 1e14);
        seed = bound(seed, 1e8, 1e14);
        router.setHaircutBps(bound(haircutBps, 0, 50));

        uint256 aliceShares = _deposit(alice, seed);
        uint256 aliceValueBefore = _valueOf(aliceShares);

        uint256 bobShares = _deposit(bob, amount);
        assertGt(bobShares, 0);
        (uint256 whbarOut, uint256[] memory legs) = _redeem(bob, bobShares);

        assertLe(_bundleValue(whbarOut, legs), amount, "no free money");
        // Pool fees go to the pool, not to the vault, so the existing holder neither gains nor loses; what moves is
        // floor rounding in the leg valuations, up to about 23 tinybars per floor on the 500:1 USDC leg.
        assertGe(_valueOf(aliceShares) + 100, aliceValueBefore, "the existing holder is not diluted beyond rounding");
        assertEq(share.balanceOf(bob), 0);
    }
}
