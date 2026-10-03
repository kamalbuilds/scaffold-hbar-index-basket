// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";

import { BasketVault } from "../contracts/BasketVault.sol";
import { ISaucerSwapV2Router } from "../contracts/interfaces/ISaucerSwapV2.sol";
import { MockHtsToken } from "./mocks/MockHtsToken.sol";
import { MockShareToken, MockHts, MockHss } from "./mocks/MockHederaSystem.sol";
import { MockWhbarHelper, MockAggregator, MockFactory } from "./mocks/MockSaucerSwap.sol";
import { CpPool, CpRouter } from "./mocks/CpAmm.sol";

/// Price-manipulation tests against BasketVault with constant-product pools, where every swap moves the price and the
/// attacker pays for each move. The repo's MockRouter trades at spot with no impact and MockPool moves price for free,
/// so a manipulation test built on them shows profit that does not exist and cannot show the attacker's cost.
/// Values are WHBAR tinybar at the pre-attack market price.
abstract contract CpFixture is Test {
    address constant HTS_ADDR = address(0x167);
    address constant HSS_ADDR = address(0x16b);
    address constant USDC_ADDR = address(0x1549);
    address constant WHBAR_ADDR = address(0x3ad2);
    address constant SAUCE_ADDR = address(0x9000);
    uint256 constant T0 = 1_700_000_000;
    uint256 constant HBAR = 1e8;
    uint24 constant POOL_FEE = 3000;

    MockHtsToken whbar;
    MockHtsToken sauce;
    MockHtsToken usdc;
    CpPool saucePool; // token0 WHBAR, token1 SAUCE
    CpPool usdcPool; // token0 USDC, token1 WHBAR
    CpRouter router;
    MockFactory factory;
    MockWhbarHelper helper;
    MockAggregator feed;
    BasketVault vault;
    MockShareToken share;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address trader = makeAddr("trader");
    address attacker = makeAddr("attacker");

    uint256 depth;
    uint256 refS0;
    uint256 refS1;
    uint256 refU0;
    uint256 refU1;

    /// 2,000,000 HBAR of depth on each side of each pool; 1 SAUCE = 0.025 HBAR, 1 USDC = 5 HBAR. The vault is built
    /// in chunks, with arbitrage resetting the pools between them. drift 500 and slippage 300 as in Deploy.s.sol.
    function _build(uint256 vaultHbar, uint256 maxTradeBps) internal {
        vm.warp(T0);
        vm.etch(HTS_ADDR, address(new MockHts()).code);
        vm.etch(HSS_ADDR, address(new MockHss()).code);
        deployCodeTo("MockHtsToken.sol:MockHtsToken", abi.encode("Wrapped HBAR", "WHBAR", uint8(8)), WHBAR_ADDR);
        deployCodeTo("MockHtsToken.sol:MockHtsToken", abi.encode("SaucerSwap", "SAUCE", uint8(6)), SAUCE_ADDR);
        deployCodeTo("MockHtsToken.sol:MockHtsToken", abi.encode("USD Coin", "USDC", uint8(6)), USDC_ADDR);
        whbar = MockHtsToken(WHBAR_ADDR);
        sauce = MockHtsToken(SAUCE_ADDR);
        usdc = MockHtsToken(USDC_ADDR);

        router = new CpRouter();
        factory = new MockFactory();
        helper = new MockWhbarHelper(WHBAR_ADDR);
        feed = new MockAggregator();
        feed.set(20_000_000, T0);

        depth = 2_000_000 * HBAR;
        saucePool = new CpPool(SAUCE_ADDR, WHBAR_ADDR, POOL_FEE);
        usdcPool = new CpPool(USDC_ADDR, WHBAR_ADDR, POOL_FEE);
        _resetPools();
        router.registerPool(saucePool);
        router.registerPool(usdcPool);
        factory.registerPool(address(saucePool));
        factory.registerPool(address(usdcPool));

        BasketVault.LegConfig[] memory legs = new BasketVault.LegConfig[](2);
        legs[0] = BasketVault.LegConfig(SAUCE_ADDR, address(saucePool), 3000);
        legs[1] = BasketVault.LegConfig(USDC_ADDR, address(usdcPool), 3000);
        vm.prank(owner);
        vault = new BasketVault(
            BasketVault.Config({
                router: address(router),
                factory: address(factory),
                whbarHelper: address(helper),
                whbar: WHBAR_ADDR,
                hbarUsdFeed: address(feed),
                maxOracleAge: 1 days + 1 hours,
                driftBps: 500,
                slippageBps: 300,
                maxTradeBps: maxTradeBps,
                scheduledGas: 4_000_000,
                guardLeg: type(uint256).max,
                maxDeviationBps: 0
            }),
            legs
        );
        vm.deal(owner, 30 * HBAR);
        vm.prank(owner);
        vault.initialize{ value: 30 * HBAR }("Basket", "BSK");
        share = MockShareToken(vault.shareToken());

        address[3] memory users = [alice, trader, attacker];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(users[i]);
            whbar.associate();
            sauce.associate();
            usdc.associate();
            share.associate();
            whbar.approve(address(router), type(uint256).max);
            sauce.approve(address(router), type(uint256).max);
            usdc.approve(address(router), type(uint256).max);
            share.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }

        uint256 total = vaultHbar * HBAR;
        uint256 chunk = depth / 40;
        vm.deal(alice, total);
        while (total > 0) {
            uint256 c = total < chunk ? total : chunk;
            vm.prank(alice);
            vault.deposit{ value: c }(0);
            total -= c;
            _resetPools();
        }
    }

    function _resetPools() internal {
        saucePool.setReserves(depth, depth * 10 / 25);
        usdcPool.setReserves(depth / 500, depth);
    }

    function _swap(address who, address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256) {
        vm.prank(who);
        return router.exactInput(
            ISaucerSwapV2Router.ExactInputParams({
                path: abi.encodePacked(tokenIn, POOL_FEE, tokenOut),
                recipient: who,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0
            })
        );
    }

    /// A genuine market move: someone buys SAUCE with WHBAR until SAUCE is about 41% dearer.
    function _naturalSaucePump() internal {
        uint256 amt = depth * 19 / 100;
        whbar.mint(trader, amt);
        _swap(trader, WHBAR_ADDR, SAUCE_ADDR, amt);
    }

    function _saucePct() internal view returns (uint256) {
        BasketVault.Holding[] memory rows = vault.holdings();
        return rows[1].valueWhbar * 10_000 / vault.nav();
    }
}

contract BasketVaultSandwichTest is CpFixture {
    function setUp() public {
        _build(200_000, 10_000);
    }

    function _snapRef() internal {
        (refS0, refS1) = (saucePool.r0(), saucePool.r1());
        (refU0, refU1) = (usdcPool.r0(), usdcPool.r1());
    }

    function _valueOf(uint256 w, uint256 s, uint256 u) internal view returns (uint256) {
        return w + s * refS0 / refS1 + u * refU1 / refU0;
    }

    function _vaultValue() internal view returns (uint256) {
        return
            _valueOf(whbar.balanceOf(address(vault)), sauce.balanceOf(address(vault)), usdc.balanceOf(address(vault)));
    }

    function _attackerValue() internal view returns (uint256) {
        return
            _valueOf(whbar.balanceOf(attacker), sauce.balanceOf(attacker), usdc.balanceOf(attacker)) + attacker.balance;
    }

    /// Buy SAUCE with WHBAR until the SAUCE pool is back at the reference price (WHBAR per SAUCE).
    function _restoreSauce() internal {
        uint256 lo;
        uint256 hi = depth;
        for (uint256 i; i < 80; ++i) {
            uint256 mid = (lo + hi) / 2;
            uint256 out = saucePool.quote(WHBAR_ADDR, mid);
            uint256 n0 = saucePool.r0() + mid;
            uint256 n1 = saucePool.r1() - out;
            if (n0 * refS1 < refS0 * n1) lo = mid;
            else hi = mid;
        }
        if (lo == 0) return;
        require(whbar.balanceOf(attacker) >= lo, "attacker budget");
        _swap(attacker, WHBAR_ADDR, SAUCE_ADDR, lo);
    }

    /// Atomic dump -> rebalance -> buy-back, at 16 dump sizes. `bestProfit` is the attacker's best gain and
    /// `maxVaultLoss` the most the vault ends up below an honest rebalance. `blocked` counts the sizes where the
    /// attacker's rebalance call reverted with OnlyOwnerOrSelf.
    function _sandwichSweep() internal returns (uint256 bestProfit, uint256 maxVaultLoss, uint256 blocked) {
        _naturalSaucePump();
        assertGt(_saucePct(), 3000 + 500, "SAUCE sits past the drift band, so a rebalance is due");
        _snapRef();
        uint256 snap = vm.snapshotState();

        vm.prank(owner);
        assertTrue(vault.rebalance(), "the owner's honest rebalance trades");
        uint256 honest = _vaultValue();

        for (uint256 k = 1; k <= 16; ++k) {
            vm.revertToState(snap);
            uint256 sell = k * depth / 800;
            sauce.mint(attacker, sell);
            whbar.mint(attacker, 1_000_000 * HBAR);
            uint256 before = _attackerValue();

            _swap(attacker, SAUCE_ADDR, WHBAR_ADDR, sell); // front-run: dump SAUCE
            vm.prank(attacker);
            try vault.rebalance() { }
            catch (bytes memory err) {
                // forge-lint: disable-next-line(unsafe-typecast)
                assertEq(bytes4(err), BasketVault.OnlyOwnerOrSelf.selector, "refused for the right reason");
                ++blocked;
                continue;
            }
            _restoreSauce(); // back-run: buy SAUCE back to the market price

            uint256 afterValue = _attackerValue();
            uint256 vaultNow = _vaultValue();
            if (afterValue > before && afterValue - before > bestProfit) bestProfit = afterValue - before;
            if (honest > vaultNow && honest - vaultNow > maxVaultLoss) maxVaultLoss = honest - vaultNow;
        }
        console.log("best attacker profit HBAR", bestProfit / HBAR);
        console.log("max vault loss HBAR", maxVaultLoss / HBAR);
    }

    /// H-1. Fails on the permissionless rebalance (attacker profit 524 HBAR on a 200k HBAR vault) and passes once an
    /// outsider cannot run an atomic sandwich around it.
    function test_regression_outsiderCannotProfitFromRebalance() public {
        (uint256 bestProfit, uint256 maxVaultLoss, uint256 blocked) = _sandwichSweep();
        assertEq(bestProfit, 0, "attacker profit");
        assertEq(maxVaultLoss, 0, "vault loss vs honest rebalance");
        assertEq(blocked, 16, "every one of the 16 sandwiches was refused, none merely unprofitable");
    }

    /// The honest path still works: the owner rebalances and the schedule (msg.sender == vault) rebalances.
    function test_scheduledRunStillRebalancesWhenOutsidersCannot() public {
        _naturalSaucePump();
        vm.prank(address(vault));
        assertTrue(vault.rebalance());
        assertLt(_saucePct(), 3000 + 500 + 1);
    }
}

contract BasketVaultOutgrownPoolTest is CpFixture {
    /// M-4. A 1,000,000 HBAR vault in 2,000,000 HBAR pools after SAUCE rises 41%: the correction is too big for one
    /// swap inside the 3% slippage bound.
    function test_uncappedRebalanceRevertsOnceTheVaultOutgrowsItsPools() public {
        _build(1_000_000, 10_000);
        _naturalSaucePump();
        vm.prank(owner);
        vm.expectRevert(bytes("Too little received"));
        vault.rebalance();
    }

    function test_regression_cappedRebalanceTradesAndConverges() public {
        _build(1_000_000, 200);
        _naturalSaucePump();
        uint256 w = _saucePct();
        assertGt(w, 3000 + 500, "SAUCE is past the band");

        uint256 calls;
        for (; calls < 12; ++calls) {
            vm.prank(owner);
            if (!vault.rebalance()) break;
            uint256 next = _saucePct();
            assertLt(next, w, "every call moves SAUCE toward its 30% target");
            w = next;
        }
        assertGt(calls, 0, "the first call traded instead of reverting");
        assertLe(w, 3000 + 500, "and the basket is back inside the band");
    }
}
