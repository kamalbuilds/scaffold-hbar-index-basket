// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Test.sol";

import { BasketVault } from "../contracts/BasketVault.sol";
import { BasketVaultBase } from "./BasketVaultBase.sol";

contract BasketVaultTradeCapTest is BasketVaultBase {
    uint256 internal constant D1 = 1000e8;
    uint256 internal constant CAP_BPS = 300;

    function setUp() public override {
        super.setUp();
        BasketVault.Config memory c = _config();
        c.maxTradeBps = CAP_BPS;
        vault = _deployVault(c, _legs());
        _initialize();
        _fund(alice);
        _deposit(alice, D1);
        _scaleSaucePrice(2, 1);
    }

    function _swappedOut(Vm.Log[] memory logs) internal pure returns (uint256[] memory outs) {
        bytes32 sig = BasketVault.Swapped.selector;
        outs = new uint256[](_countOf(logs, sig));
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                (, outs[n++]) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
    }

    function test_cap_limitsEachSwapToAShareOfNav() public {
        uint256 navNow = vault.nav();
        uint256[3] memory before = _weightsBps();
        vm.recordLogs();
        assertTrue(_rebalance());
        uint256[] memory outs = _swappedOut(vm.getRecordedLogs());

        assertEq(outs.length, 2, "one sell, one buy");
        uint256 cap = navNow * CAP_BPS / 10_000;
        // The sell returns WHBAR worth the capped excess less the pool fee. The buy spends no more than the cap.
        assertLe(outs[0], cap, "the sale returned at most the cap");
        assertGt(outs[0], cap * 98 / 100, "and it used the cap, since the drift was larger");
        uint256[3] memory afterOne = _weightsBps();
        assertLt(afterOne[1], before[1], "SAUCE moved toward its target");
        assertGt(afterOne[1], 3000 + DRIFT_BPS, "but one call did not finish the job");
    }

    function test_cap_limitsABuyToo() public {
        _scaleSaucePrice(1, 1);
        _scaleUsdcPrice(1, 2); // USDC halves: a 15% hole, with plenty of WHBAR on hand to fill it
        feed.set(HBAR_USD * 2, block.timestamp); // and Chainlink agrees, so the price guard stays quiet
        uint256 navNow = vault.nav();
        uint256 usdcBefore = usdc.balanceOf(address(vault));
        vm.recordLogs();
        assertTrue(_rebalance());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = BasketVault.Swapped.selector;
        uint256 buys;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != sig) continue;
            if (logs[i].topics[2] != bytes32(uint256(uint160(USDC_ADDR)))) continue;
            (uint256 amountIn,) = abi.decode(logs[i].data, (uint256, uint256));
            assertLe(amountIn, navNow * CAP_BPS / 10_000, "the WHBAR spent on USDC is at most the cap");
            assertGt(amountIn, navNow * CAP_BPS / 10_000 * 98 / 100, "and the cap was what limited it");
            ++buys;
        }
        assertEq(buys, 1, "one USDC buy");
        assertGt(usdc.balanceOf(address(vault)), usdcBefore);
    }

    function test_cap_repeatedCallsConvergeIntoTheBand() public {
        uint256 last = _weightsBps()[1];
        uint256 calls;
        while (calls < 12) {
            if (!_rebalance()) break;
            ++calls;
            uint256 current = _weightsBps()[1];
            assertLt(current, last, "each call moves SAUCE closer to target");
            last = current;
        }
        assertGt(calls, 1, "it took several calls");
        assertLt(calls, 12, "and then it stopped trading");
        uint256[3] memory w = _weightsBps();
        BasketVault.Holding[] memory rows = vault.holdings();
        for (uint256 i; i < 3; ++i) {
            uint256 d = w[i] > rows[i].targetBps ? w[i] - rows[i].targetBps : rows[i].targetBps - w[i];
            assertLe(d, DRIFT_BPS, "inside the band");
        }
    }

    function test_cap_aFullSizedCapChangesNothing() public {
        BasketVault.Config memory c = _config();
        c.maxTradeBps = 10_000;
        vault = _deployVault(c, _legs());
        _initialize();
        _fund(bob);
        _deposit(bob, D1);
        _scaleSaucePrice(4, 1); // the fixture's pool is now double the price this vault deposited at
        assertGt(_weightsBps()[1], 3000 + DRIFT_BPS);
        assertTrue(_rebalance());
        uint256[3] memory w = _weightsBps();
        assertLe(w[1] > 3000 ? w[1] - 3000 : 3000 - w[1], DRIFT_BPS, "one call finished it");
    }
}
