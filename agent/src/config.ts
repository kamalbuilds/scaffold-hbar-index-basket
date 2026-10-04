import type { Address } from "viem";

/** Vault C on Hedera testnet: the canonical, Sourcify-verified deployment (docs/testnet-evidence.md). */
export const VAULT_C: Address = "0xe72FbF68536D29d3A9e0D897C2aE813B7B279058";

export type VaultConfig = {
  vault: Address;
  rpcUrl: string;
  mirrorUrl: string;
  hashscanUrl: string;
};

const pick = (value: string | undefined, fallback: string) => (value && value.trim() !== "" ? value.trim() : fallback);

/** Environment overrides: BASKET_VAULT, HEDERA_RPC_URL, HEDERA_MIRROR_URL. Blank values fall back to testnet. */
export function configFromEnv(env: Record<string, string | undefined> = process.env): VaultConfig {
  const vault = pick(env.BASKET_VAULT, VAULT_C);
  if (!/^0x[0-9a-fA-F]{40}$/.test(vault)) throw new Error(`BASKET_VAULT is not an EVM address: ${vault}`);
  return {
    vault: vault as Address,
    rpcUrl: pick(env.HEDERA_RPC_URL, "https://testnet.hashio.io/api"),
    mirrorUrl: pick(env.HEDERA_MIRROR_URL, "https://testnet.mirrornode.hedera.com").replace(/\/$/, ""),
    hashscanUrl: "https://hashscan.io/testnet",
  };
}
