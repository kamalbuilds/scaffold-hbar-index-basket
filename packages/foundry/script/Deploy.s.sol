//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ScaffoldETHDeploy } from "./DeployHelpers.s.sol";
import { BasketVault } from "../contracts/BasketVault.sol";

/// @notice Deploys a BasketVault for a 40% HBAR / 30% SAUCE / 30% USDC basket.
/// @dev Addresses are SaucerSwap V2 and Chainlink on Hedera testnet; swap them for mainnet.
/// DRIFT_BPS (env, default 500) sets how far a leg may drift from its weight before a rebalance trades.
/// MAX_TRADE_BPS (env, default 2000) caps one rebalance swap at that share of NAV. The constructor checks every
/// leg's pool against the factory, so a pool the factory does not know cannot be deployed.
contract DeployScript is ScaffoldETHDeploy {
    function run() external ScaffoldEthDeployerRunner {
        BasketVault.LegConfig[] memory legs = new BasketVault.LegConfig[](2);
        legs[0] = BasketVault.LegConfig({
            token: 0x0000000000000000000000000000000000120f46, // SAUCE 0.0.1183558
            pool: 0x37814eDc1ae88cf27c0C346648721FB04e7E0AE7, // WHBAR/SAUCE 0.30%
            weightBps: 3000
        });
        legs[1] = BasketVault.LegConfig({
            token: 0x0000000000000000000000000000000000001549, // USDC 0.0.5449
            pool: 0x914B98992d7eD602D1f5d9084ECe8160Fc0e741a, // WHBAR/USDC 0.30%
            weightBps: 3000
        });

        BasketVault vault = new BasketVault(
            BasketVault.Config({
                router: 0x0000000000000000000000000000000000159398, // SwapRouter 0.0.1414040
                factory: 0x00000000000000000000000000000000001243eE, // SaucerSwapV2Factory 0.0.1192942
                whbarHelper: 0x000000000000000000000000000000000050a8a7, // WhbarHelper 0.0.5286055
                whbar: 0x0000000000000000000000000000000000003aD2, // WHBAR 0.0.15058
                hbarUsdFeed: 0x59bC155EB6c6C415fE43255aF66EcF0523c92B4a, // Chainlink HBAR/USD
                maxOracleAge: 1 days + 1 hours,
                driftBps: vm.envOr("DRIFT_BPS", uint256(500)),
                slippageBps: 300,
                maxTradeBps: vm.envOr("MAX_TRADE_BPS", uint256(2000)),
                scheduledGas: 4_000_000,
                guardLeg: type(uint256).max,
                maxDeviationBps: 0
            }),
            legs
        );
        deployments.push(Deployment({ name: "BasketVault", addr: address(vault) }));
    }
}
