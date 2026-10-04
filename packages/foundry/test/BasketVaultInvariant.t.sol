// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { BasketVault } from "../contracts/BasketVault.sol";
import { MockHtsToken } from "./mocks/MockHtsToken.sol";
import { MockHss } from "./mocks/MockHederaSystem.sol";
import { CpPool } from "./mocks/CpAmm.sol";
import { CpFixture } from "./BasketVaultSandwich.t.sol";

/// Drives BasketVault through random sequences of deposit, redeem, redeemExcept, owner rebalance, real swaps on the
/// constant-product pools (price moves with impact and fees), oracle refreshes, time warps and scheduled runs.
///
/// A reverting handler call is discarded by the fuzzer, so an invariant that only asserts "nothing broke" would pass
/// if the handler never reached the vault. Properties that must hold on every call are therefore checked inside the
/// handler against the state it read just before the call, and recorded in a flag the invariants assert on. The
/// flags are false unless the vault misbehaved; `test_handlerReachesEveryAction` proves each path executes.
///
/// Prices are read from the pools at the instant before each call (the "pre-trade mark"), the way the vault reads
/// them. NAV at a mark is recomputed here from raw balances, so the checks do not trust `vault.nav()`.
contract BasketHandler is CpFixture {
    uint256 private constant Q96 = 2 ** 96;
    int256 private constant ORACLE_PRICE = 20_000_000;
    /// Rounding allowance, in tinybar, on a depositor's claim: each leg's NAV term floors separately.
    uint256 private constant CLAIM_TOLERANCE = 4;

    struct Mark {
        uint160[2] sq;
        uint256[3] bal;
        uint256 supply;
    }

    address[] internal actors;
    uint256 public fuel;
    uint256 public maxOracleAge;

    // Properties, true when broken.
    bool public redeemReverted;
    bool public redeemNotProRata;
    bool public depositDilutedHolders;
    bool public depositorOverpaid;
    bool public staleOracleAccepted;
    bool public runScheduledReverted;

    // Reach counters.
    uint256 public deposits;
    uint256 public depositsRefused;
    uint256 public redeems;
    uint256 public redeemsExcept;
    uint256 public hostileRedeems;
    uint256 public rebalancesTraded;
    uint256 public rebalancesRefused;
    uint256 public priceMoves;
    uint256 public scheduledRuns;
    uint256 public scheduledRunsOnStaleOracle;

    constructor() {
        _build(200_000, 2000);
        actors.push(alice);
        actors.push(trader);
        actors.push(attacker);
        fuel = address(vault).balance;
        maxOracleAge = vault.maxOracleAge();
        (refS0, refS1) = (saucePool.r0(), saucePool.r1());
        (refU0, refU1) = (usdcPool.r0(), usdcPool.r1());
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function vaultAddr() external view returns (BasketVault) {
        return vault;
    }

    function shareAddr() external view returns (MockHtsToken) {
        return MockHtsToken(address(share));
    }

    function basketTokens() external view returns (address[3] memory t) {
        t = [address(whbar), address(sauce), address(usdc)];
    }

    function selectors() external pure returns (bytes4[] memory s) {
        s = new bytes4[](9);
        s[0] = this.deposit.selector;
        s[1] = this.redeem.selector;
        s[2] = this.ownerRebalance.selector;
        s[3] = this.movePrice.selector;
        s[4] = this.warp.selector;
        s[5] = this.refreshOracle.selector;
        s[6] = this.startAutomation.selector;
        s[7] = this.stopAutomation.selector;
        s[8] = this.runScheduled.selector;
    }

    // ------------------------------------------------------------ marks

    function _mark() internal view returns (Mark memory m) {
        m.sq = [saucePool.sqrtPriceX96(), usdcPool.sqrtPriceX96()];
        m.bal = [whbar.balanceOf(address(vault)), sauce.balanceOf(address(vault)), usdc.balanceOf(address(vault))];
        m.supply = share.totalSupply();
    }

    /// The vault's NAV formula at a fixed price vector, applied to a balance vector.
    function _navAt(uint160[2] memory sq, uint256[3] memory bal) internal view returns (uint256 total) {
        total = bal[0];
        BasketVault.Leg[] memory legs = vault.legs();
        for (uint256 i; i < 2; ++i) {
            total += legs[i].tokenIsToken0
                ? Math.mulDiv(Math.mulDiv(bal[i + 1], sq[i], Q96), sq[i], Q96)
                : Math.mulDiv(Math.mulDiv(bal[i + 1], Q96, sq[i]), Q96, sq[i]);
        }
    }

    function _oracleFresh() internal view returns (bool) {
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp <= feed.updatedAt() + maxOracleAge;
    }

    // ------------------------------------------------------------ actions

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1000, 60_000 * HBAR);
        vm.deal(actor, amount);
        bool fresh = _oracleFresh();
        Mark memory pre = _mark();
        uint256 navPre = _navAt(pre.sq, pre.bal);
        uint256 held = share.balanceOf(actor);

        vm.prank(actor);
        try vault.deposit{ value: amount }(0) returns (uint256 shares) {
            ++deposits;
            if (!fresh) staleOracleAccepted = true;
            Mark memory post = _mark();
            uint256 navPost = _navAt(pre.sq, post.bal);
            // Existing holders: NAV per share at the pre-trade mark never falls.
            if (navPost * pre.supply < navPre * post.supply) depositDilutedHolders = true;
            // The depositor: what the new shares are worth at that mark never exceeds the HBAR sent.
            if (shares * navPost > (amount + CLAIM_TOLERANCE) * post.supply) depositorOverpaid = true;
            if (share.balanceOf(actor) != held + shares) depositDilutedHolders = true;
        } catch {
            ++depositsRefused;
        }
    }

    /// `hostile` makes every price source revert for the length of the call: the Chainlink feed and both pools' slot0.
    /// `maskSeed` picks a skip mask for `redeemExcept`; `useMask` false calls plain `redeem`.
    function redeem(uint256 actorSeed, uint256 shareSeed, uint256 maskSeed, bool useMask, bool hostile) external {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = share.balanceOf(actor);
        if (balance == 0) return;
        uint256 shares = bound(shareSeed, 1, balance);
        uint256 mask = useMask ? bound(maskSeed, 0, 3) : 0;

        if (hostile) {
            vm.mockCallRevert(address(feed), abi.encodeWithSignature("latestRoundData()"), "oracle down");
            vm.mockCallRevert(address(saucePool), abi.encodeWithSignature("slot0()"), "pool down");
            vm.mockCallRevert(address(usdcPool), abi.encodeWithSignature("slot0()"), "pool down");
        }
        Mark memory pre = _mark();

        vm.prank(actor);
        if (useMask) {
            try vault.redeemExcept(shares, mask) returns (uint256 whbarOut, uint256[] memory legAmounts) {
                _checkRedeem(pre, shares, mask, whbarOut, legAmounts, actor, balance);
                ++redeemsExcept;
            } catch {
                redeemReverted = true;
            }
        } else {
            try vault.redeem(shares) returns (uint256 whbarOut, uint256[] memory legAmounts) {
                _checkRedeem(pre, shares, 0, whbarOut, legAmounts, actor, balance);
                ++redeems;
            } catch {
                redeemReverted = true;
            }
        }
        if (hostile) {
            vm.clearMockedCalls();
            ++hostileRedeems;
        }
    }

    function _checkRedeem(
        Mark memory pre,
        uint256 shares,
        uint256 mask,
        uint256 whbarOut,
        uint256[] memory legAmounts,
        address actor,
        uint256 sharesBefore
    ) internal {
        Mark memory post = _mark();
        // Pro rata of each held balance, floored, the skipped legs paying nothing. No price enters the formula.
        uint256[3] memory expected;
        expected[0] = pre.bal[0] * shares / pre.supply;
        for (uint256 i; i < 2; ++i) {
            expected[i + 1] = mask & (uint256(1) << i) != 0 ? 0 : pre.bal[i + 1] * shares / pre.supply;
        }
        if (whbarOut != expected[0] || legAmounts[0] != expected[1] || legAmounts[1] != expected[2]) {
            redeemNotProRata = true;
        }
        // The vault's balances fell by exactly the payout, and the share supply by exactly the shares burned.
        for (uint256 i; i < 3; ++i) {
            if (post.bal[i] != pre.bal[i] - expected[i]) redeemNotProRata = true;
        }
        if (post.supply != pre.supply - shares || share.balanceOf(actor) != sharesBefore - shares) {
            redeemNotProRata = true;
        }
    }

    function ownerRebalance() external {
        bool fresh = _oracleFresh();
        vm.prank(owner);
        try vault.rebalance() returns (bool traded) {
            if (!fresh) staleOracleAccepted = true;
            if (traded) ++rebalancesTraded;
        } catch {
            ++rebalancesRefused;
        }
    }

    /// A real swap by the trader on one pool, so the price moves with impact and the fee stays in the pool. Skipped
    /// when it would carry the pool past a factor of two from its starting price.
    function movePrice(uint256 poolSeed, bool token0In, uint256 amount) external {
        CpPool pool = poolSeed % 2 == 0 ? saucePool : usdcPool;
        (uint256 ref0, uint256 ref1) = poolSeed % 2 == 0 ? (refS0, refS1) : (refU0, refU1);
        address tokenIn = token0In ? pool.token0() : pool.token1();
        address tokenOut = token0In ? pool.token1() : pool.token0();
        uint256 reserveIn = token0In ? pool.r0() : pool.r1();
        amount = bound(amount, reserveIn / 1000, reserveIn / 10);
        uint256 out = pool.quote(tokenIn, amount);
        uint256 n0 = token0In ? pool.r0() + amount : pool.r0() - out;
        uint256 n1 = token0In ? pool.r1() - out : pool.r1() + amount;
        // new price n1/n0 against reference ref1/ref0, within [1/2, 2]
        if (n1 * ref0 * 2 < ref1 * n0 || n1 * ref0 > 2 * ref1 * n0) return;
        MockHtsToken(tokenIn).mint(trader, amount);
        _swap(trader, tokenIn, tokenOut, amount);
        ++priceMoves;
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 20 hours));
    }

    function refreshOracle() external {
        feed.set(ORACLE_PRICE, block.timestamp);
    }

    function startAutomation(uint256 interval) external {
        if (vault.rebalanceInterval() != 0) return;
        vm.prank(owner);
        try vault.startAutomation(bound(interval, 60, 5 days)) { } catch { }
    }

    function stopAutomation() external {
        vm.prank(owner);
        vault.stopAutomation();
    }

    /// Plays the network's part for the newest booking: reach its second, optionally keep the oracle fresh, and call
    /// `runScheduled` as the vault with the gas it was booked with. It must never revert, whatever the pools and the
    /// oracle look like and whether automation is still on.
    function runScheduled(bool refresh) external {
        MockHss hss = MockHss(HSS_ADDR);
        uint256 count = hss.callCount();
        if (count == 0) return;
        MockHss.ScheduledCall memory c = hss.callAt(count - 1);
        if (c.responseCode != 22) return;
        // forge-lint: disable-next-line(block-timestamp)
        if (c.expirySecond > block.timestamp) vm.warp(c.expirySecond);
        if (refresh) feed.set(ORACLE_PRICE, block.timestamp);
        bool fresh = _oracleFresh();
        vm.prank(c.to);
        (bool ok,) = c.to.call{ gas: c.gasLimit }(c.callData);
        if (!ok) runScheduledReverted = true;
        ++scheduledRuns;
        if (!fresh) ++scheduledRunsOnStaleOracle;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 80
contract BasketVaultInvariantTest is StdInvariant, Test {
    BasketHandler internal h;
    BasketVault internal vault;
    MockHtsToken internal share;

    function setUp() public {
        h = new BasketHandler();
        vault = h.vaultAddr();
        share = h.shareAddr();

        targetContract(address(h));
        bytes4[] memory sel = h.selectors();
        targetSelector(FuzzSelector({ addr: address(h), selectors: sel }));
    }

    // ------------------------------------------------------------ (a) share accounting

    function invariant_shareSupplyIsHoldersPlusLockedTreasury() public view {
        uint256 sum;
        for (uint256 i; i < h.actorCount(); ++i) {
            sum += share.balanceOf(h.actorAt(i));
        }
        uint256 treasury = share.balanceOf(address(vault));
        assertEq(treasury, vault.DEAD_SHARES(), "the treasury holds exactly the locked shares, nothing a redeem left");
        assertEq(share.totalSupply(), sum + treasury, "supply is the sum of holders plus the locked treasury");
    }

    // ------------------------------------------------------------ (b) redeem reads no price

    function invariant_redeemNeverReadsAPriceAndPaysProRata() public view {
        assertFalse(h.redeemReverted(), "a redeem reverted while the oracle and slot0 were down");
        assertFalse(h.redeemNotProRata(), "a redeem paid something other than balance * shares / supply");
    }

    // ------------------------------------------------------------ (c) value conservation

    function invariant_noOneGainsValueFromAnotherHolder() public view {
        assertFalse(h.depositDilutedHolders(), "a deposit lowered NAV per share for existing holders");
        assertFalse(h.depositorOverpaid(), "a depositor's shares are worth more than the HBAR they sent");
    }

    // ------------------------------------------------------------ (d) the vault holds the basket and nothing else

    function invariant_vaultHoldsOnlyTheBasketAndIsBacked() public view {
        assertEq(address(vault).balance, h.fuel(), "native HBAR in the vault is fuel and no deposit or redeem moves it");
        BasketVault.Holding[] memory rows = vault.holdings();
        address[3] memory basket = h.basketTokens();
        assertEq(rows.length, 3, "WHBAR plus two legs");
        for (uint256 i; i < 3; ++i) {
            assertEq(rows[i].token, basket[i], "the basket is the three tokens it was built with");
            assertEq(rows[i].balance, MockHtsToken(basket[i]).balanceOf(address(vault)), "holdings reads real balances");
        }
        assertGt(vault.nav(), 0, "outstanding shares are backed by a positive NAV");
    }

    // ------------------------------------------------------------ (e) automation

    function invariant_runScheduledNeverReverts() public view {
        assertFalse(h.runScheduledReverted(), "runScheduled reverted");
    }

    function invariant_staleOracleBlocksDepositsAndRebalances() public view {
        assertFalse(h.staleOracleAccepted(), "a deposit or rebalance went through on an oracle past maxOracleAge");
    }

    // ------------------------------------------------------------ the handler is not vacuous

    /// Scripts one sequence through the handler and asserts every action reached the vault and every property flag
    /// stayed false. Without this a handler whose calls all revert would leave every invariant green.
    function test_handlerReachesEveryAction() public {
        h.deposit(0, 5000 * 1e8);
        h.deposit(1, 20_000 * 1e8);
        h.deposit(2, 100 * 1e8);
        h.movePrice(0, true, 5e13);
        h.movePrice(0, true, 5e13);
        h.movePrice(0, true, 5e13);
        h.movePrice(1, false, 5e11);
        h.redeem(0, 1e12, 0, false, true);
        h.redeem(1, 1e11, 3, true, true);
        h.redeem(2, 1e9, 1, true, false);
        h.ownerRebalance();
        h.startAutomation(3600);
        h.runScheduled(true);
        h.warp(20 hours);
        h.warp(20 hours);
        h.runScheduled(false);
        h.stopAutomation();
        h.runScheduled(true);

        assertEq(h.deposits(), 3, "all three deposits executed");
        assertEq(h.priceMoves(), 4, "all four swaps moved a pool");
        assertEq(h.redeems(), 1, "the plain redeem executed");
        assertEq(h.redeemsExcept(), 2, "both masked redeems executed");
        assertEq(h.hostileRedeems(), 2, "two redeems ran with every price source reverting");
        assertGt(h.scheduledRuns(), 2, "scheduled runs executed");
        assertEq(h.scheduledRunsOnStaleOracle(), 1, "one scheduled run hit a stale oracle");
        assertFalse(h.redeemReverted());
        assertFalse(h.redeemNotProRata());
        assertFalse(h.depositDilutedHolders());
        assertFalse(h.depositorOverpaid());
        assertFalse(h.staleOracleAccepted());
        assertFalse(h.runScheduledReverted());
        assertEq(h.rebalancesTraded(), 1, "SAUCE pumped past the drift band, so the owner rebalance traded");
    }
}
