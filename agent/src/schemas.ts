import { z } from "zod";

/** A decimal with at most 8 places, given as a string or a number (models send either). Zero is refused. */
const decimal8 = (what: string) =>
  z
    .union([z.string(), z.number()])
    .transform((v) => (typeof v === "number" ? v.toLocaleString("en-US", { useGrouping: false, maximumFractionDigits: 8 }) : v.trim()))
    .pipe(
      z
        .string()
        .regex(/^\d+(\.\d{1,8})?$/, `${what} must be a plain decimal with at most 8 places, for example "1.5"`)
        .refine((v) => /[1-9]/.test(v), `${what} must be above zero`),
    );

const slippage = z
  .number()
  .int()
  .min(1)
  .max(1000)
  .default(300)
  .describe("Allowed shortfall against the estimate, in basis points (300 = 3%). The deposit reverts below it.");

const account = z
  .string()
  .regex(/^(0\.0\.\d+|0x[0-9a-fA-F]{40})$/, "account must be 0.0.N or a 0x EVM address")
  .describe("Hedera account id (0.0.N) or EVM address");

export const getBasketStateSchema = z.object({
  account: account.optional().describe("Also report this account's share position. Defaults to the agent's own account when it has one."),
});

export const previewDepositSchema = z.object({
  hbar: decimal8("hbar").describe('HBAR to deposit, as a decimal string, for example "1.5"'),
  slippageBps: slippage,
  account: account.optional().describe("Who deposits. Defaults to the agent's own account."),
});

export const depositHbarSchema = z.object({
  hbar: decimal8("hbar").describe('HBAR to deposit, as a decimal string, for example "1.5"'),
  slippageBps: slippage,
});

export const redeemSharesSchema = z.object({
  shares: z
    .union([z.literal("all"), decimal8("shares")])
    .describe('Share tokens to redeem as a decimal string (8 places), or "all" for the agent\'s whole balance'),
  skipLegs: z
    .array(z.union([z.string().min(1), z.number().int().min(0)]))
    .max(16)
    .default([])
    .describe(
      "Basket legs to leave out of the payout, by symbol or leg index (see get_basket_state). Use it when a token's issuer froze the vault or the redeemer: the skipped slice stays in the vault.",
    ),
});

export const bookNextRunSchema = z.object({});

export const rebalanceNowSchema = z.object({
  force: z.boolean().default(false).describe("Rebalance even when no leg is outside the drift band (the call is then a no-op that still costs gas)."),
});

export type DepositHbarParams = z.infer<typeof depositHbarSchema>;
export type RedeemSharesParams = z.infer<typeof redeemSharesSchema>;
