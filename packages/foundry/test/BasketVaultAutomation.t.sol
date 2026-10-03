// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { BasketVault } from "../contracts/BasketVault.sol";
import { MockHss } from "./mocks/MockHederaSystem.sol";
import { BasketVaultBase } from "./BasketVaultBase.sol";

contract BasketVaultAutomationTest is BasketVaultBase {
    uint256 internal constant D1 = 1000e8;
    uint256 internal constant INTERVAL = 1 hours;
    int64 internal constant SUCCESS = 22;
    int64 internal constant EXPIRY_BUSY = 370;

    function _start() internal {
        vm.prank(owner);
        vault.startAutomation(INTERVAL);
    }

    function _startWithDrift() internal {
        _deposit(alice, D1);
        _start();
        _scaleSaucePrice(2, 1);
    }

    // ---------------------------------------------------------------- startAutomation

    function test_start_isOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.startAutomation(INTERVAL);
        assertEq(hss.callCount(), 0);
    }

    function test_start_rejectsIntervalsBelowTheMinimum() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.BadInterval.selector, 59));
        vault.startAutomation(59);

        vm.prank(owner);
        vault.startAutomation(60);
        assertEq(vault.rebalanceInterval(), 60);
    }

    function test_start_rejectsIntervalsAboveSixtyDays() public {
        uint256 max = vault.MAX_INTERVAL();
        assertEq(max, 60 days);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.BadInterval.selector, max + 1));
        vault.startAutomation(max + 1);

        vm.prank(owner);
        vault.startAutomation(max);
        assertEq(hss.callAt(0).expirySecond, T0 + max);
    }

    function test_start_booksARunnableScheduleWithTheConfiguredGas() public {
        vm.expectEmit(address(vault));
        emit BasketVault.AutomationStarted(INTERVAL);
        _start();

        assertEq(hss.callCount(), 1);
        MockHss.ScheduledCall memory c = hss.callAt(0);
        assertEq(c.to, address(vault), "the vault schedules a call to itself");
        assertEq(c.expirySecond, T0 + INTERVAL);
        assertEq(c.gasLimit, SCHEDULED_GAS);
        assertEq(c.gasLimit, 3_000_000);
        assertEq(c.value, 0);
        assertEq(c.callData, abi.encodeCall(vault.runScheduled, ()));
        assertEq(c.callData, abi.encodeWithSelector(BasketVault.runScheduled.selector));
        assertEq(c.responseCode, SUCCESS);

        assertEq(vault.rebalanceInterval(), INTERVAL);
        assertEq(vault.pendingSchedule(), c.schedule);
        assertTrue(c.schedule != address(0));
        assertEq(vault.nextRunAt(), c.expirySecond);
    }

    function test_start_cannotRunTwice() public {
        _start();
        vm.prank(owner);
        vm.expectRevert(BasketVault.AutomationActive.selector);
        vault.startAutomation(2 hours);
        assertEq(hss.callCount(), 1, "no second schedule was booked");
        assertEq(vault.rebalanceInterval(), INTERVAL);
    }

    function test_start_revertsWithTheResponseCodeWhenBookingFails() public {
        hss.setForcedCodes(int64(373), 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.ScheduleFailed.selector, int64(373)));
        vault.startAutomation(INTERVAL);
        assertEq(vault.rebalanceInterval(), 0, "a failed start leaves automation off");
        assertEq(vault.pendingSchedule(), address(0));
        assertEq(vault.nextRunAt(), 0);
    }

    // ---------------------------------------------------------------- capacity probe

    function _expiryWhenBusy(uint256[] memory delays) internal returns (uint256 expiry) {
        uint256 ideal = T0 + INTERVAL;
        for (uint256 i; i < delays.length; ++i) {
            hss.setBusy(ideal + delays[i], true);
        }
        _start();
        expiry = hss.callAt(0).expirySecond;
    }

    function test_capacity_usesTheIdealSecondWhenFree() public {
        assertEq(_expiryWhenBusy(new uint256[](0)), T0 + INTERVAL);
    }

    function test_capacity_picksIdealPlusDelayWhenIdealIsBusy() public {
        uint256[] memory busy = new uint256[](1);
        busy[0] = 0;
        assertEq(_expiryWhenBusy(busy), T0 + INTERVAL + 1);
    }

    function test_capacity_backsOffExponentially() public {
        uint256[] memory busy = new uint256[](3);
        busy[0] = 0;
        busy[1] = 1;
        busy[2] = 2;
        assertEq(_expiryWhenBusy(busy), T0 + INTERVAL + 4, "probes 1, 2, 4: the first free one wins");
    }

    function test_capacity_reachesTheLongestProbe() public {
        uint256[] memory busy = new uint256[](5);
        busy[0] = 0;
        busy[1] = 1;
        busy[2] = 2;
        busy[3] = 4;
        busy[4] = 8;
        assertEq(_expiryWhenBusy(busy), T0 + INTERVAL + 16);
    }

    function test_capacity_failsWithBusyCodeWhenEverySlotIsTaken() public {
        uint256 ideal = T0 + INTERVAL;
        uint256[6] memory busy = [uint256(0), 1, 2, 4, 8, 16];
        for (uint256 i; i < busy.length; ++i) {
            hss.setBusy(ideal + busy[i], true);
        }
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.ScheduleFailed.selector, EXPIRY_BUSY));
        vault.startAutomation(INTERVAL);
        assertEq(vault.rebalanceInterval(), 0);
    }

    // ---------------------------------------------------------------- runScheduled

    function test_runScheduled_revertsForEveryoneButTheVault() public {
        _start();
        address[4] memory callers = [alice, owner, HSS_ADDR, keeper];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(BasketVault.OnlySelf.selector);
            vault.runScheduled();
        }
        assertEq(hss.callCount(), 1, "nothing was rebooked");
        assertEq(vault.pendingSchedule(), hss.callAt(0).schedule);
    }

    function test_runScheduled_runsWhenTheVaultCallsItself() public {
        _start();
        vm.prank(address(vault));
        vault.runScheduled();
        assertEq(hss.callCount(), 2);
    }

    function test_scheduledRun_booksTheSuccessorBeforeItRebalances() public {
        _startWithDrift();
        vm.recordLogs();
        (bool ok,) = _runSchedule(0, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);

        uint256 booked = _indexOf(logs, BasketVault.RunBooked.selector);
        uint256 swapped = _indexOf(logs, BasketVault.Swapped.selector);
        uint256 rebalanced = _indexOf(logs, BasketVault.Rebalanced.selector);
        uint256 ran = _indexOf(logs, BasketVault.ScheduledRun.selector);
        assertTrue(booked != type(uint256).max, "successor booked");
        assertTrue(swapped != type(uint256).max, "rebalance traded");
        assertLt(booked, swapped, "booked before the first swap");
        assertLt(booked, rebalanced);
        assertLt(rebalanced, ran);
        assertTrue(abi.decode(logs[ran].data, (bool)), "ScheduledRun reports that it traded");
        assertEq(_countOf(logs, BasketVault.RunBooked.selector), 1, "exactly one booking per scheduled execution");
    }

    function test_scheduledRun_rebalancesAndRollsTheScheduleForward() public {
        _startWithDrift();
        address first = vault.pendingSchedule();
        uint256[3] memory before = _weightsBps();
        uint256 usdcBefore = usdc.balanceOf(address(vault));
        (bool ok,) = _runSchedule(0, true);
        assertTrue(ok);

        assertEq(hss.callCount(), 2);
        MockHss.ScheduledCall memory next = hss.callAt(1);
        assertEq(next.expirySecond, T0 + INTERVAL + INTERVAL, "the next run is one interval after this one");
        assertEq(next.gasLimit, SCHEDULED_GAS);
        assertEq(next.callData, abi.encodeCall(vault.runScheduled, ()));
        assertEq(vault.pendingSchedule(), next.schedule);
        assertTrue(next.schedule != first);
        assertEq(vault.nextRunAt(), next.expirySecond);
        assertEq(vault.rebalanceInterval(), INTERVAL);

        uint256[3] memory afterRun = _weightsBps();
        assertGt(before[1], 3000 + DRIFT_BPS);
        assertLe(afterRun[1], 3000 + DRIFT_BPS, "SAUCE is back inside the band");
        assertGe(afterRun[2] + DRIFT_BPS, 3000, "USDC was topped up to within the band");
        assertGt(usdc.balanceOf(address(vault)), usdcBefore);
    }

    function test_scheduledRun_chainsAcrossSeveralRuns() public {
        _deposit(alice, D1);
        _start();
        for (uint256 i; i < 3; ++i) {
            (bool ok,) = _runSchedule(i, true);
            assertTrue(ok);
            assertEq(hss.callCount(), i + 2);
            assertEq(vault.pendingSchedule(), hss.callAt(i + 1).schedule);
        }
        assertEq(hss.callAt(3).expirySecond, T0 + 4 * INTERVAL);
    }

    function test_scheduledRun_neverRevertsWhenTheRebalanceDoes_andStillBooksTheNextRun() public {
        _deposit(alice, D1);
        vm.prank(owner);
        vault.startAutomation(2 days); // the oracle is 26 hours old by the time this fires
        (bool ok,) = _runSchedule(0, false);

        assertTrue(ok, "the scheduled call itself succeeds");
        assertEq(hss.callCount(), 2, "the successor is booked despite the failure");
        assertEq(vault.pendingSchedule(), hss.callAt(1).schedule);
    }

    function test_scheduledRun_reportsWhyTheRebalanceFailed() public {
        _deposit(alice, D1);
        vm.prank(owner);
        vault.startAutomation(2 days);
        vm.recordLogs();
        (bool ok,) = _runSchedule(0, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(ok);
        uint256 failed = _indexOf(logs, BasketVault.ScheduledRunFailed.selector);
        assertTrue(failed != type(uint256).max, "ScheduledRunFailed emitted");
        bytes memory reason = abi.decode(logs[failed].data, (bytes));
        assertEq(reason, abi.encodeWithSelector(BasketVault.StaleOracle.selector, T0));
        assertEq(_indexOf(logs, BasketVault.ScheduledRun.selector), type(uint256).max, "no success event");
        assertLt(_indexOf(logs, BasketVault.RunBooked.selector), failed);
    }

    function test_scheduledRun_reportsASlippageRevertFromTheRouter() public {
        _startWithDrift();
        router.setHaircutBps(100);
        vm.recordLogs();
        (bool ok,) = _runSchedule(0, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(ok);
        uint256 failed = _indexOf(logs, BasketVault.ScheduledRunFailed.selector);
        assertTrue(failed != type(uint256).max);
        assertEq(
            abi.decode(logs[failed].data, (bytes)), abi.encodeWithSignature("Error(string)", "Too little received")
        );
        assertEq(hss.callCount(), 2);
    }

    function test_scheduledRun_emitsBookingFailedAndStillRebalancesWhenTheSuccessorCannotBeBooked() public {
        _startWithDrift();
        hss.setForcedCodes(int64(373), 0);
        vm.recordLogs();
        (bool ok,) = _runSchedule(0, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(ok, "a booking failure does not revert the scheduled call");
        uint256 failed = _indexOf(logs, BasketVault.BookingFailed.selector);
        assertTrue(failed != type(uint256).max, "BookingFailed emitted");
        assertEq(abi.decode(logs[failed].data, (int64)), int64(373));
        assertEq(_indexOf(logs, BasketVault.RunBooked.selector), type(uint256).max);
        assertTrue(_indexOf(logs, BasketVault.ScheduledRun.selector) != type(uint256).max, "the rebalance still ran");
        assertTrue(_indexOf(logs, BasketVault.Swapped.selector) != type(uint256).max);

        assertEq(hss.callCount(), 2, "one refused attempt is on record");
        assertEq(hss.callAt(1).responseCode, int64(373));
        assertEq(vault.pendingSchedule(), address(0));
        assertEq(vault.nextRunAt(), 0);
        assertEq(vault.rebalanceInterval(), 0, "a lost booking turns automation off");
    }

    function test_scheduledRun_doesNothingOnceAutomationIsStopped() public {
        _startWithDrift();
        vm.prank(owner);
        vault.stopAutomation();

        uint256 swaps = router.swapCount();
        (bool ok,) = _runSchedule(0, true);
        assertTrue(ok);
        assertEq(hss.callCount(), 1, "no successor");
        assertEq(router.swapCount(), swaps, "no rebalance");
        assertEq(vault.pendingSchedule(), address(0));
    }

    // ---------------------------------------------------------------- stopAutomation

    function test_stop_isOwnerOnly() public {
        _start();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.stopAutomation();
        assertEq(vault.rebalanceInterval(), INTERVAL);
        assertEq(hss.deleteCount(), 0);
    }

    function test_stop_deletesThePendingScheduleAndClearsState() public {
        _start();
        address pending = vault.pendingSchedule();
        assertTrue(pending != address(0));

        vm.expectEmit(address(vault));
        emit BasketVault.AutomationStopped();
        vm.prank(owner);
        vault.stopAutomation();

        assertEq(hss.deleteCount(), 1);
        assertEq(hss.lastDeleted(), pending);
        assertEq(vault.pendingSchedule(), address(0));
        assertEq(vault.nextRunAt(), 0);
        assertEq(vault.rebalanceInterval(), 0);
    }

    function test_stop_whenIdleDeletesNothing() public {
        vm.prank(owner);
        vault.stopAutomation();
        assertEq(hss.deleteCount(), 0);
    }

    function test_stop_thenStartBooksAFreshSchedule() public {
        _start();
        vm.prank(owner);
        vault.stopAutomation();
        vm.prank(owner);
        vault.startAutomation(2 hours);
        assertEq(hss.callCount(), 2);
        assertEq(hss.callAt(1).expirySecond, T0 + 2 hours);
        assertEq(vault.pendingSchedule(), hss.callAt(1).schedule);
    }

    function test_lostBooking_turnsAutomationOffAndAllowsRestart() public {
        _deposit(alice, D1);
        _start();
        hss.setForcedCodes(int64(373), 0);
        _runSchedule(0, true);
        assertEq(vault.pendingSchedule(), address(0));
        assertEq(vault.rebalanceInterval(), 0);

        hss.setForcedCodes(0, 0);
        vm.prank(owner);
        vault.startAutomation(INTERVAL);
        assertTrue(vault.pendingSchedule() != address(0));
    }

    // ---------------------------------------------------------------- withdrawFuel

    function test_withdrawFuel_isOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.withdrawFuel(payable(alice), 1);
    }

    function test_withdrawFuel_movesNativeHbarAndNeverBasketTokens() public {
        _deposit(alice, D1);
        uint256 fuel = address(vault).balance;
        assertEq(fuel, INIT_VALUE - CREATE_FEE);
        uint256 whbarBal = whbar.balanceOf(address(vault));
        uint256 sauceBal = sauce.balanceOf(address(vault));
        uint256 usdcBal = usdc.balanceOf(address(vault));
        uint256 shareBal = share.balanceOf(address(vault));
        uint256 navBefore = vault.nav();
        uint256 keeperBefore = keeper.balance;

        vm.prank(owner);
        vault.withdrawFuel(payable(keeper), fuel);

        assertEq(keeper.balance, keeperBefore + fuel);
        assertEq(address(vault).balance, 0);
        assertEq(whbar.balanceOf(address(vault)), whbarBal);
        assertEq(sauce.balanceOf(address(vault)), sauceBal);
        assertEq(usdc.balanceOf(address(vault)), usdcBal);
        assertEq(share.balanceOf(address(vault)), shareBal);
        assertEq(vault.nav(), navBefore, "NAV is untouched");
        assertEq(whbar.balanceOf(keeper) + sauce.balanceOf(keeper) + usdc.balanceOf(keeper), 0);
    }

    function test_withdrawFuel_cannotWithdrawMoreThanTheVaultHolds() public {
        uint256 fuel = address(vault).balance;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.TransferFailed.selector, address(0)));
        vault.withdrawFuel(payable(keeper), fuel + 1);
    }

    function test_withdrawFuel_revertsWhenTheRecipientRejectsHbar() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.TransferFailed.selector, address(0)));
        vault.withdrawFuel(payable(WHBAR_ADDR), 1); // the WHBAR token has no receive function
        assertEq(address(vault).balance, INIT_VALUE - CREATE_FEE);
    }

    function test_vaultAcceptsFuelDirectly() public {
        uint256 before = address(vault).balance;
        vm.deal(alice, 10e8);
        vm.prank(alice);
        (bool ok,) = address(vault).call{ value: 3e8 }("");
        assertTrue(ok);
        assertEq(address(vault).balance, before + 3e8);
        assertEq(vault.nav(), 0, "fuel is not part of the basket");
    }
}
