import type { MirrorLog } from "../mirror";
import logsJson from "./vault-logs.json";

/**
 * Captured once from the live Hedera testnet mirror node:
 * GET /api/v1/contracts/0xe72FbF68536D29d3A9e0D897C2aE813B7B279058/results/logs?limit=15
 * The vault's 15 newest logs at capture time, trimmed to the fields the decoder reads.
 */
export const LIVE_LOGS = logsJson.logs as MirrorLog[];

export const VAULT = "0xe72FbF68536D29d3A9e0D897C2aE813B7B279058" as const;

export const jsonResponse = (body: unknown, status = 200) =>
  ({ ok: status >= 200 && status < 300, status, json: async () => body }) as Response;
