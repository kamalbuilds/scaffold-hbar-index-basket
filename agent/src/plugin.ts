import type { Context, Plugin } from "@hashgraph/hedera-agent-kit";
import type { Tool } from "@hashgraph/hedera-agent-kit";
import { type ChainReader, VaultChain } from "./chain";
import { type VaultConfig, configFromEnv } from "./config";
import { BookNextRun, DepositHbar, GetBasketState, PreviewDeposit, RebalanceNow, RedeemShares, TOOL_NAMES } from "./tools";

/**
 * The Index Basket plugin for the Hedera Agent Kit. `chain` is injectable so tests can run the tools
 * without a network; by default every tool reads the vault in `config` over JSON-RPC and the mirror node.
 */
export function createIndexBasketPlugin(config: VaultConfig = configFromEnv(), chain: ChainReader = new VaultChain(config)): Plugin {
  return {
    name: "index-basket",
    version: "1.0.0",
    description:
      "Operate the Index Basket fund on Hedera: read NAV, weights and automation state, preview and make deposits, redeem in kind, rearm the scheduled rebalances, and rebalance as owner.",
    tools: (_context: Context): Tool[] => [
      new GetBasketState(chain),
      new PreviewDeposit(chain),
      new DepositHbar(chain),
      new RedeemShares(chain),
      new BookNextRun(chain),
      new RebalanceNow(chain),
    ],
  };
}

export const indexBasketToolNames = TOOL_NAMES;
