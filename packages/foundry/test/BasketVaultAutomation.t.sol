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
        assertEq(hss.callAt(0).expirySecond, T0 + max + _jitter());
    }

    function test_start_booksARunnableScheduleWithTheConfiguredGas() public {
        vm.expectEmit(address(vault));
        emit BasketVault.AutomationStarted(INTERVAL);
        _start();

        assertEq(hss.callCount(), 1);
        MockHss.ScheduledCall memory c = hss.callAt(0);
        assertEq(c.to, address(vault), "the vault schedules a call to itself");
        assertEq(c.expirySecond, T0 + INTERVAL + _jitter());
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
        uint256 ideal = T0 + INTERVAL + _jitter();
        for (uint256 i; i < delays.length; ++i) {
            hss.setBusy(ideal + delays[i], true);
        }
        _start();
        expiry = hss.callAt(0).expirySecond;
    }

    function test_capacity_usesTheIdealSecondWhenFree() public {
        assertEq(_expiryWhenBusy(new uint256[](0)), T0 + INTERVAL + _jitter());
    }

    function test_capacity_picksIdealPlusDelayWhenIdealIsBusy() public {
        uint256[] memory busy = new uint256[](1);
        busy[0] = 0;
        assertEq(_expiryWhenBusy(busy), T0 + INTERVAL + _jitter() + 1);
    }

    function test_capacity_backsOffExponentially() public {
        uint256[] memory busy = new uint256[](3);
        busy[0] = 0;
        busy[1] = 1;
        busy[2] = 2;
        assertEq(_expiryWhenBusy(busy), T0 + INTERVAL + _jitter() + 4, "probes 1, 2, 4: the first free one wins");
    }

    function test_capacity_reachesTheLongestProbe() public {
        uint256[] memory busy = new uint256[](7);
        busy[0] = 0;
        busy[1] = 1;
        busy[2] = 2;
        busy[3] = 4;
        busy[4] = 8;
        busy[5] = 16;
        busy[6] = 32;
        assertEq(_expiryWhenBusy(busy), T0 + INTERVAL + _jitter() + 64);
    }

    function test_capacity_failsWithBusyCodeWhenEverySlotIsTaken() public {
        uint256 ideal = T0 + INTERVAL + _jitter();
        uint256[8] memory busy = [uint256(0), 1, 2, 4, 8, 16, 32, 64];
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
        uint256 gap = next.expirySecond - hss.callAt(0).expirySecond;
        assertGe(gap, INTERVAL, "the next run is one interval after this one");
        assertLt(gap, INTERVAL + 30);
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
        // Every run is booked a jittered interval after the one before it.
        for (uint256 i = 1; i < 4; ++i) {
            uint256 gap = hss.callAt(i).expirySecond - hss.callAt(i - 1).expirySecond;
            assertGe(gap, INTERVAL);
            assertLt(gap, INTERVAL + 30);
        }
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
        assertEq(vault.rebalanceInterval(), INTERVAL, "a lost booking keeps automation on, rearm books again");
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
        assertEq(hss.callAt(1).expirySecond, T0 + 2 hours + _jitter());
        assertEq(vault.pendingSchedule(), hss.callAt(1).schedule);
    }

    function test_lostBooking_keepsTheIntervalSoAnyoneCanRearm() public {
        _deposit(alice, D1);
        _start();
        hss.setForcedCodes(int64(373), 0);
        _runSchedule(0, true);
        assertEq(vault.pendingSchedule(), address(0), "the chain is broken");
        assertEq(vault.rebalanceInterval(), INTERVAL, "but automation was not switched off");

        hss.setForcedCodes(0, 0);
        uint256 calls = hss.callCount();
        vm.prank(alice);
        vault.rearm();
        assertEq(hss.callCount(), calls + 1, "rearm made one booking");
        assertEq(vault.pendingSchedule(), hss.callAt(calls).schedule);
        assertEq(vault.nextRunAt(), hss.callAt(calls).expirySecond);
        assertGt(vault.nextRunAt(), block.timestamp);

        // And the rearmed schedule runs and chains on like any other.
        (bool ok,) = _runSchedule(calls, true);
        assertTrue(ok);
        assertTrue(vault.pendingSchedule() != address(0));
    }

    function test_rearm_isPermissionlessAndPaidFromTheVault() public {
        _start();
        hss.setForcedCodes(int64(373), 0);
        _runSchedule(0, true);
        hss.setForcedCodes(0, 0);
        uint256 callerBalance = keeper.balance;
        vm.prank(keeper);
        vault.rearm();
        assertEq(keeper.balance, callerBalance, "the caller sends and receives nothing");
        assertTrue(vault.pendingSchedule() != address(0));
    }

    function test_rearm_revertsWhileARunIsPending() public {
        _start();
        address pending = vault.pendingSchedule();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.RunAlreadyPending.selector, pending));
        vault.rearm();
        assertEq(hss.callCount(), 1, "no second booking");
    }

    function test_rearm_revertsWhenAutomationIsOff() public {
        vm.prank(keeper);
        vm.expectRevert(BasketVault.NotAutomated.selector);
        vault.rearm();

        _start();
        vm.prank(owner);
        vault.stopAutomation();
        vm.prank(keeper);
        vm.expectRevert(BasketVault.NotAutomated.selector);
        vault.rearm();
        assertEq(hss.callCount(), 1);
    }

    function test_rearm_revertsWithTheCodeWhenTheBookingIsRefusedAgain() public {
        _start();
        hss.setForcedCodes(int64(373), 0);
        _runSchedule(0, true);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.ScheduleFailed.selector, int64(373)));
        vault.rearm();
        assertEq(vault.rebalanceInterval(), INTERVAL);
    }

    function test_attacker_fillingEverySecondTheProbeCouldPickCannotSwitchAutomationOff() public {
        // The report's attack: book schedules into the seconds the successor will probe. With the jitter the
        // attacker must also guess the draw; here they guess it right and still only delay the chain.
        vm.deal(address(vault), 100e8);
        _start();
        uint256 ideal = vault.nextRunAt() + INTERVAL;
        vm.warp(vault.nextRunAt());
        feed.set(HBAR_USD, block.timestamp);
        ideal = block.timestamp + INTERVAL + _jitter();
        uint256[8] memory probes = [uint256(0), 1, 2, 4, 8, 16, 32, 64];
        for (uint256 i; i < probes.length; ++i) {
            hss.setBusy(ideal + probes[i], true);
        }
        vm.prank(address(vault));
        vault.runScheduled();
        assertEq(vault.rebalanceInterval(), INTERVAL, "automation is still on");
        assertEq(vault.pendingSchedule(), address(0), "the successor was refused");

        for (uint256 i; i < probes.length; ++i) {
            hss.setBusy(ideal + probes[i], false);
        }
        vm.prank(keeper);
        vault.rearm();
        assertTrue(vault.pendingSchedule() != address(0), "anyone re-arms it");
    }

    function test_booking_jitterStaysInsideThirtySecondsAndFollowsChainRandomness() public {
        uint256 snap = vm.snapshotState();
        uint256[] memory seen = new uint256[](40);
        uint256 distinct;
        for (uint256 r; r < 40; ++r) {
            vm.revertToState(snap);
            vm.prevrandao(bytes32(r + 1));
            _start();
            uint256 jitter = vault.nextRunAt() - (T0 + INTERVAL);
            assertLt(jitter, 30, "jitter is 0..29 seconds");
            bool fresh = true;
            for (uint256 k; k < r; ++k) {
                if (seen[k] == jitter) fresh = false;
            }
            seen[r] = jitter;
            if (fresh) ++distinct;
        }
        assertGt(distinct, 10, "the booking second moves with prevrandao, so it cannot be filled in advance");
    }

    function test_stop_emitsTheDeleteResponseCode() public {
        _start();
        address pending = vault.pendingSchedule();
        vm.expectEmit(address(vault));
        emit BasketVault.ScheduleDeleted(pending, SUCCESS);
        vm.prank(owner);
        vault.stopAutomation();
    }

    function test_stop_doesNotRevertWhenTheScheduleAlreadyRanOrExpired() public {
        _start();
        address pending = vault.pendingSchedule();
        for (uint256 i; i < 3; ++i) {
            int64 code = i == 0 ? int64(201) : (i == 1 ? int64(212) : int64(213));
            hss.setForcedCodes(0, code);
            vm.expectEmit(address(vault));
            emit BasketVault.ScheduleDeleted(pending, code);
            vm.prank(owner);
            vault.stopAutomation();
            assertEq(vault.rebalanceInterval(), 0, "automation is off whatever deleteSchedule said");
            assertEq(vault.pendingSchedule(), address(0));
            hss.setForcedCodes(0, 0);
            if (i < 2) {
                _start();
                pending = vault.pendingSchedule();
            }
        }
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
