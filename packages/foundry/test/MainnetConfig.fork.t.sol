// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { BasketVault } from "../contracts/BasketVault.sol";

interface IPool {
    function token0() external view returns (address);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

/// The README's "Deploy to mainnet" table, deployed against a Hedera mainnet fork. The constructor checks every pool
/// against the SaucerSwap V2 factory and reads its fee and token order, so a wrong row reverts here.
/// Run: `forge test --match-path test/MainnetConfig.fork.t.sol --fork-url https://mainnet.hashio.io/api`
contract MainnetConfigForkTest is Test {
    address constant ROUTER = 0x00000000000000000000000000000000003c437A;
    address constant FACTORY = 0x00000000000000000000000000000000003c3951;
    address constant WHBAR_HELPER = 0x000000000000000000000000000000000058A2BA;
    address constant WHBAR = 0x0000000000000000000000000000000000163B5a;
    address constant SAUCE = 0x00000000000000000000000000000000000b2aD5;
    address constant USDC = 0x000000000000000000000000000000000006f89a;
    address constant HBAR_USD = 0xAF685FB45C12b92b5054ccb9313e135525F9b5d5;
    address constant WHBAR_SAUCE_POOL = 0x5fc19c944F1BCcF5159e6Ae92dC3bF2fF2576b98;
    address constant WHBAR_USDC_POOL = 0xC5B707348dA504E9Be1bD4E21525459830e7B11d;
    uint256 constant MAX_DEVIATION_BPS = 300;

    function setUp() public {
        if (block.chainid != 295) vm.skip(true);
    }

    function test_mainnetTable_deploysAndPricesTheBasket() public {
        BasketVault.LegConfig[] memory legs = new BasketVault.LegConfig[](2);
        legs[0] = BasketVault.LegConfig({ token: SAUCE, pool: WHBAR_SAUCE_POOL, weightBps: 3000 });
        legs[1] = BasketVault.LegConfig({ token: USDC, pool: WHBAR_USDC_POOL, weightBps: 3000 });
        BasketVault vault = new BasketVault(
            BasketVault.Config({
                router: ROUTER,
                factory: FACTORY,
                whbarHelper: WHBAR_HELPER,
                whbar: WHBAR,
                hbarUsdFeed: HBAR_USD,
                maxOracleAge: 1 days + 1 hours,
                driftBps: 500,
                slippageBps: 300,
                maxTradeBps: 2000,
                scheduledGas: 4_000_000,
                guardLeg: 1,
                maxDeviationBps: MAX_DEVIATION_BPS
            }),
            legs
        );

        BasketVault.Leg[] memory read = vault.legs();
        assertEq(read.length, 2);
        assertEq(read[1].fee, 1500, "mainnet WHBAR/USDC pool is the 0.15% tier");

        // hbarUsd() reverts on a stale or non-positive answer, so this also proves the feed is fresh at the fork block.
        uint256 oracle = vault.hbarUsd();

        // With guardLeg = 1, deposits and rebalances require the USDC pool's implied HBAR/USD within
        // MAX_DEVIATION_BPS of Chainlink. Same formula as _checkPriceGuard: testnet pools fail it, mainnet must pass.
        (uint160 sqrtPrice,,,,,,) = IPool(WHBAR_USDC_POOL).slot0();
        uint256 q96 = 2 ** 96;
        uint256 whbarPerUsd = IPool(WHBAR_USDC_POOL).token0() == USDC
            ? (1e6 * uint256(sqrtPrice) / q96) * uint256(sqrtPrice) / q96
            : (1e6 * q96 / uint256(sqrtPrice)) * q96 / uint256(sqrtPrice);
        uint256 implied = 1e16 / whbarPerUsd;
        uint256 diff = implied > oracle ? implied - oracle : oracle - implied;
        emit log_named_uint("pool implied HBAR/USD e8", implied);
        emit log_named_uint("Chainlink HBAR/USD e8", oracle);
        assertLe(diff * 10_000, oracle * MAX_DEVIATION_BPS, "mainnet USDC pool within 3% of Chainlink");
    }
}
