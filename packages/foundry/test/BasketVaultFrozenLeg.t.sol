// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Test.sol";

import { BasketVault } from "../contracts/BasketVault.sol";
import { BasketVaultBase } from "./BasketVaultBase.sol";

/// A token issuer with a freeze key can freeze the vault's account (or a holder's) for one leg. Every holder's other
/// legs must stay redeemable.
contract BasketVaultFrozenLegTest is BasketVaultBase {
    uint256 internal constant D1 = 1000e8;
    uint256 internal constant SKIP_USDC = 1 << 1;
    uint256 internal constant SKIP_SAUCE = 1;

    uint256 internal aliceShares;
    uint256 internal bobShares;

    function setUp() public override {
        super.setUp();
        aliceShares = _deposit(alice, D1);
        bobShares = _deposit(bob, D1);
    }

    function _approve(address user, uint256 shares) internal {
        vm.prank(user);
        share.approve(address(vault), shares);
    }

    function test_frozenLeg_blocksPlainRedeemForEveryone() public {
        usdc.freeze(address(vault), true);
        _approve(alice, aliceShares);
        _approve(bob, bobShares);
        vm.startPrank(alice);
        vm.expectRevert();
        vault.redeem(aliceShares);
        vm.stopPrank();
        vm.startPrank(bob);
        vm.expectRevert();
        vault.redeem(bobShares);
        vm.stopPrank();
    }

    function test_redeemExcept_paysTheOtherLegsWhenOneIsFrozen() public {
        usdc.freeze(address(vault), true);
        _approve(alice, aliceShares);
        uint256 supply = share.totalSupply();
        uint256 whbarExpected = whbar.balanceOf(address(vault)) * aliceShares / supply;
        uint256 sauceExpected = sauce.balanceOf(address(vault)) * aliceShares / supply;
        uint256 usdcInVault = usdc.balanceOf(address(vault));
        uint256 whbarBefore = whbar.balanceOf(alice);
        uint256 sauceBefore = sauce.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.recordLogs();
        vm.prank(alice);
        (uint256 whbarOut, uint256[] memory legAmounts) = vault.redeemExcept(aliceShares, SKIP_USDC);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(whbarExpected, 0);
        assertGt(sauceExpected, 0);
        assertEq(whbarOut, whbarExpected);
        assertEq(legAmounts[0], sauceExpected);
        assertEq(legAmounts[1], 0, "the skipped leg pays nothing");
        assertEq(whbar.balanceOf(alice) - whbarBefore, whbarExpected);
        assertEq(sauce.balanceOf(alice) - sauceBefore, sauceExpected);
        assertEq(usdc.balanceOf(alice), usdcBefore);
        assertEq(usdc.balanceOf(address(vault)), usdcInVault, "her slice of USDC stays in the vault");
        assertEq(share.balanceOf(alice), 0);
        assertEq(share.totalSupply(), supply - aliceShares, "her shares were burned");

        uint256 skipped = _indexOf(logs, BasketVault.LegsSkipped.selector);
        assertTrue(skipped != type(uint256).max, "LegsSkipped emitted");
        assertEq(abi.decode(logs[skipped].data, (uint256)), SKIP_USDC);
        assertTrue(_indexOf(logs, BasketVault.Redeemed.selector) != type(uint256).max);
    }

    function test_redeemExcept_theSkippedSliceGoesToTheRemainingHolders() public {
        usdc.freeze(address(vault), true);
        _approve(alice, aliceShares);
        vm.prank(alice);
        vault.redeemExcept(aliceShares, SKIP_USDC);

        usdc.freeze(address(vault), false);
        uint256 usdcInVault = usdc.balanceOf(address(vault));
        uint256 bobFairBefore = usdcInVault / 2;
        _approve(bob, bobShares);
        vm.prank(bob);
        (, uint256[] memory legAmounts) = vault.redeem(bobShares);
        // Bob is the only holder left bar the dead shares, so he takes nearly all the USDC, alice's slice included.
        assertGt(legAmounts[1], bobFairBefore, "bob got more than half the USDC left");
        assertApproxEqRel(legAmounts[1], usdcInVault, 1e13); // the dead shares keep a dust
    }

    function test_redeemExcept_worksWhenTheRedeemersOwnAccountIsFrozenForOneLeg() public {
        usdc.freeze(alice, true);
        _approve(alice, aliceShares);
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(aliceShares);

        vm.prank(alice);
        vault.redeemExcept(aliceShares, SKIP_USDC);
        assertGt(sauce.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), 0);
    }

    function test_redeemExcept_zeroMaskIsExactlyRedeem() public {
        _approve(alice, aliceShares);
        _approve(bob, bobShares);
        uint256 snap = vm.snapshotState();

        vm.prank(alice);
        (uint256 w1, uint256[] memory a1) = vault.redeem(aliceShares);
        vm.revertToState(snap);
        vm.prank(alice);
        (uint256 w2, uint256[] memory a2) = vault.redeemExcept(aliceShares, 0);

        assertGt(w1, 0);
        assertEq(w1, w2);
        assertEq(a1[0], a2[0]);
        assertEq(a1[1], a2[1]);
        assertGt(a2[1], 0, "with no mask, USDC is paid");
    }

    function test_redeemExcept_everyLegSkippedPaysOnlyWhbar() public {
        _approve(alice, aliceShares);
        uint256 sauceInVault = sauce.balanceOf(address(vault));
        vm.prank(alice);
        (uint256 whbarOut, uint256[] memory legAmounts) = vault.redeemExcept(aliceShares, SKIP_SAUCE | SKIP_USDC);
        assertGt(whbarOut, 0);
        assertEq(legAmounts[0] + legAmounts[1], 0);
        assertEq(sauce.balanceOf(address(vault)), sauceInVault);
    }

    function test_redeemExcept_rejectsBitsBeyondTheLegs() public {
        _approve(alice, aliceShares);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.BadSkipMask.selector, 1 << 2));
        vault.redeemExcept(aliceShares, 1 << 2);
        assertEq(share.balanceOf(alice), aliceShares, "nothing was burned");
    }

    function test_redeemExcept_stillReadsNoPrice() public {
        vm.warp(T0 + MAX_ORACLE_AGE + 1); // stale oracle
        usdcPool.setSqrtPriceX96(1); // broken pool
        _approve(alice, aliceShares);
        vm.prank(alice);
        (uint256 whbarOut,) = vault.redeemExcept(aliceShares, SKIP_USDC);
        assertGt(whbarOut, 0);
    }

    function test_redeemExcept_requiresSharesAndAnAllowance() public {
        vm.prank(alice);
        vm.expectRevert(BasketVault.ZeroAmount.selector);
        vault.redeemExcept(0, SKIP_USDC);

        vm.prank(alice);
        vm.expectRevert();
        vault.redeemExcept(aliceShares, SKIP_USDC);
    }

    function test_redeemExcept_cannotTakeMoreThanTheShareOfNav() public {
        // Skipping a leg never lets a holder take more of the others than their pro-rata slice.
        usdc.freeze(address(vault), true);
        _approve(alice, aliceShares);
        uint256 whbarBefore = whbar.balanceOf(address(vault));
        uint256 supply = share.totalSupply();
        vm.prank(alice);
        (uint256 whbarOut,) = vault.redeemExcept(aliceShares, SKIP_USDC);
        assertLe(whbarOut, whbarBefore * aliceShares / supply);
    }
}
