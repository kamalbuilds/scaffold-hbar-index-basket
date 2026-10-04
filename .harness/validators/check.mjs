#!/usr/bin/env node
// Deterministic checks for the "add a third basket leg" recipe. Run from the repo root:
//   node .harness/validators/check.mjs <check>
// Every check prints one line per violation to stderr and exits 1 if there is any, 0 otherwise.
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";

const DEPLOY = "packages/foundry/script/Deploy.s.sol";
const LIVE = "packages/foundry/script/live-testnet.sh";
const THIRD_LEG_TEST = "test/BasketVaultThirdLeg.t.sol";
const ADDR = "0x[0-9a-fA-F]{40}";
const problems = [];
const fail = msg => problems.push(msg);
const read = file => readFileSync(file, "utf8");
const pct = bps => String(bps / 100);

function parseDeploy() {
  const raw = read(DEPLOY);
  const code = raw.replace(/\/\/[^\n]*/g, "");
  const declared = code.match(/LegConfig\[\]\s+memory\s+\w+\s*=\s*new\s+BasketVault\.LegConfig\[\]\((\d+)\)/);
  const legRe = new RegExp(
    `LegConfig\\(\\{\\s*token:\\s*(${ADDR})\\s*,\\s*pool:\\s*(${ADDR})\\s*,\\s*weightBps:\\s*(\\d+)\\s*\\}\\)`,
    "g",
  );
  const legs = [...code.matchAll(legRe)].map(m => {
    const comment = raw.match(new RegExp(`${m[1]}\\s*,\\s*//\\s*([A-Za-z0-9]+)`));
    return { token: m[1].toLowerCase(), pool: m[2], weightBps: Number(m[3]), symbol: comment?.[1] };
  });
  return {
    raw,
    declared: declared ? Number(declared[1]) : undefined,
    legs,
    factory: code.match(new RegExp(`factory:\\s*(${ADDR})`))?.[1],
    whbar: code.match(new RegExp(`whbar:\\s*(${ADDR})`))?.[1],
  };
}

function cast(...args) {
  const rpc = process.env.HEDERA_RPC_URL || "https://testnet.hashio.io/api";
  let last;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      return execFileSync("cast", [...args, "--rpc-url", rpc], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
    } catch (e) {
      last = e;
    }
  }
  throw new Error(`cast ${args[0]} failed 3 times: ${String(last.stderr || last.message).trim().split("\n")[0]}`);
}

function forgeResults(matchPath) {
  const args = ["test", "--json", ...(matchPath ? ["--match-path", matchPath] : [])];
  let out;
  try {
    out = execFileSync("forge", args, {
      cwd: "packages/foundry",
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
      env: { ...process.env, FOUNDRY_DISABLE_NIGHTLY_WARNING: "1" },
    });
  } catch (e) {
    // forge exits non-zero when a test fails but still prints the results; a compile error prints none.
    if (!String(e.stdout).includes("{")) throw e;
    out = e.stdout;
  }
  const suites = JSON.parse(out.slice(out.indexOf("{")));
  const tests = [];
  for (const [suite, body] of Object.entries(suites)) {
    for (const [name, r] of Object.entries(body.test_results)) tests.push({ suite, name, status: r.status });
  }
  return tests;
}

const checks = {
  // Deploy.s.sol declares at least three token legs, keeps the old two, and its weights leave WHBAR a share.
  "deploy-legs": () => {
    const d = parseDeploy();
    if (d.legs.length === 0) return fail(`${DEPLOY}: no LegConfig({...}) entries parsed`);
    if (d.declared !== d.legs.length) fail(`${DEPLOY}: array declared with ${d.declared} slots but ${d.legs.length} legs are configured`);
    if (d.legs.length < 3) fail(`${DEPLOY}: ${d.legs.length} token legs configured, the recipe needs at least 3`);
    const sum = d.legs.reduce((a, l) => a + l.weightBps, 0);
    if (sum >= 10000) fail(`${DEPLOY}: leg weights sum to ${sum} bps, they must stay under 10000 so WHBAR keeps a share`);
    for (const l of d.legs) if (l.weightBps === 0) fail(`${DEPLOY}: leg ${l.token} has zero weight`);
    if (new Set(d.legs.map(l => l.token)).size !== d.legs.length) fail(`${DEPLOY}: duplicate leg token`);
    if (new Set(d.legs.map(l => l.pool.toLowerCase())).size !== d.legs.length) fail(`${DEPLOY}: duplicate leg pool`);
    for (const keep of ["0x0000000000000000000000000000000000120f46", "0x0000000000000000000000000000000000001549"]) {
      if (!d.legs.some(l => l.token === keep)) fail(`${DEPLOY}: existing leg ${keep} was removed`);
    }
    // The NatSpec header describes the basket in percent; it must describe this one.
    const notice = d.raw.split("\n").find(l => l.includes("@notice")) ?? "";
    const want = [`${pct(10000 - sum)}% HBAR`, ...d.legs.map(l => `${pct(l.weightBps)}% ${l.symbol}`)];
    for (const w of want) if (!notice.includes(w)) fail(`${DEPLOY}: @notice line is missing "${w}" (it reads: ${notice.trim()})`);
  },

  // Every leg pool is the SaucerSwap V2 factory's own pool for (token, WHBAR, fee). Read from the RPC, not trusted from a comment.
  "factory-pool": () => {
    const d = parseDeploy();
    if (!d.factory || !d.whbar || d.legs.length === 0) return fail(`${DEPLOY}: cannot read factory, whbar and legs`);
    for (const l of d.legs) {
      try {
        const fee = cast("call", l.pool, "fee()(uint24)").split(" ")[0];
        const fromFactory = cast("call", d.factory, "getPool(address,address,uint24)(address)", l.token, d.whbar, fee);
        if (fromFactory.toLowerCase() !== l.pool.toLowerCase()) fail(`${l.symbol ?? l.token}: factory.getPool returns ${fromFactory}, Deploy.s.sol uses ${l.pool}`);
        const pair = [cast("call", l.pool, "token0()(address)"), cast("call", l.pool, "token1()(address)")].map(a => a.toLowerCase());
        if (!(pair.includes(l.token) && pair.includes(d.whbar.toLowerCase()))) fail(`${l.symbol ?? l.token}: pool ${l.pool} does not pair the token with WHBAR`);
        if (BigInt(cast("call", l.pool, "liquidity()(uint128)").split(" ")[0]) === 0n) fail(`${l.symbol ?? l.token}: pool ${l.pool} has no liquidity`);
      } catch (e) {
        fail(`${l.symbol ?? l.token}: ${e.message}`);
      }
    }
  },

  // live-testnet.sh associates every leg token before redeeming.
  "live-script": () => {
    const d = parseDeploy();
    const sh = read(LIVE);
    const names = new Map([...sh.matchAll(new RegExp(`^(\\w+)=(${ADDR})`, "gm"))].map(m => [m[2].toLowerCase(), m[1]]));
    for (const l of d.legs) {
      const name = names.get(l.token);
      if (!name) fail(`${LIVE}: no NAME=${l.token} line for ${l.symbol ?? "a leg token"}`);
      else if (!new RegExp(`^associate\\s+${name}\\s`, "m").test(sh)) fail(`${LIVE}: ${name} is never passed to associate`);
    }
  },

  // The third-leg test file runs, passes, and exercises both deposit and redeem. forge exits 0 when nothing matches, so count.
  "third-leg-test": () => {
    if (!existsSync(path.join("packages/foundry", THIRD_LEG_TEST))) return fail(`packages/foundry/${THIRD_LEG_TEST} does not exist`);
    const tests = forgeResults(THIRD_LEG_TEST);
    if (tests.length < 2) fail(`${THIRD_LEG_TEST}: ${tests.length} tests ran, need at least 2`);
    for (const t of tests) if (t.status !== "Success") fail(`${t.name}: ${t.status}`);
    for (const word of ["deposit", "redeem"]) {
      if (!tests.some(t => t.status === "Success" && t.name.toLowerCase().includes(word))) fail(`no passing test name mentions "${word}"`);
    }
  },

  // The totals README.md and AGENTS.md print are the totals forge reports.
  "docs-counts": () => {
    const tests = forgeResults();
    const passed = tests.filter(t => t.status === "Success");
    const suites = new Set(passed.map(t => t.suite)).size;
    if (tests.some(t => t.status === "Failure")) fail("forge test has failures");
    for (const [file, re] of [["README.md", /(\d+) tests across (\d+) suites/], ["AGENTS.md", /(\d+) unit tests across (\d+) suites/]]) {
      const m = read(file).match(re);
      if (!m) fail(`${file}: no "N tests across M suites" line`);
      else if (Number(m[1]) !== passed.length || Number(m[2]) !== suites) fail(`${file} says ${m[1]} tests across ${m[2]} suites, forge ran ${passed.length} across ${suites}`);
    }
    const intro = read("README.md").match(/(\d+) Foundry tests/);
    if (!intro) fail('README.md: no "N Foundry tests" phrase');
    else if (Number(intro[1]) !== passed.length) fail(`README.md intro says ${intro[1]} Foundry tests, forge ran ${passed.length}`);
  },

  // The fund UI renders whatever holdings() returns: no leg token, symbol or count is written into it.
  "ui-generic": () => {
    const d = parseDeploy();
    const banned = [
      ...new Set(["SAUCE", "USDC", ...d.legs.map(l => l.symbol).filter(Boolean)]),
    ].map(s => [new RegExp(`\\b${s}\\b`), `hard-coded token symbol ${s}`]);
    for (const l of d.legs) banned.push([new RegExp(`${l.token.slice(2)}|${l.pool.slice(2)}`, "i"), `hard-coded leg address ${l.token}`]);
    banned.push(
      [/\b(tokens|holdings|legs|rows)\[[1-9]\d*\]/, "fixed leg index"],
      [/\b(tokens|holdings|legs|rows)\.slice\(\s*0?\s*,\s*\d+\s*\)/, "list cut to a fixed length"],
      [/\b(tokens|holdings|legs|rows)\.length\s*(===?|!==?|<=?|>=?)\s*[2-9]\b/, "fixed leg count"],
    );
    const roots = ["packages/nextjs/app", "packages/nextjs/components/basket", "packages/nextjs/hooks/basket", "packages/nextjs/utils/basket"];
    let scanned = 0;
    const walk = dir => {
      for (const name of readdirSync(dir)) {
        const p = path.join(dir, name);
        if (statSync(p).isDirectory()) walk(p);
        else if (/\.(tsx?|css)$/.test(name) && !p.endsWith("deployedContracts.ts")) {
          scanned++;
          read(p).split("\n").forEach((line, i) => {
            for (const [re, why] of banned) if (re.test(line)) fail(`${p}:${i + 1} ${why}: ${line.trim()}`);
          });
        }
      }
    };
    roots.filter(existsSync).forEach(walk);
    if (scanned < 10) fail(`only ${scanned} UI files scanned, the roots moved`);
  },

  // The contract and the existing tests are not edited; new files are fine.
  "protected-paths": () => {
    const git = (...a) => execFileSync("git", a, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
    let base = "HEAD";
    for (const b of ["main", "master"]) {
      try {
        base = git("merge-base", "HEAD", b);
        break;
      } catch {}
    }
    const out = git("diff", "--name-status", base, "--", "packages/foundry/contracts", "packages/foundry/test");
    for (const line of out.split("\n").filter(Boolean)) if (!line.startsWith("A")) fail(`edited or removed since ${base.slice(0, 7)}: ${line}`);
  },
};

const name = process.argv[2];
if (!checks[name]) {
  console.error(`usage: check.mjs <${Object.keys(checks).join("|")}>`);
  process.exit(2);
}
try {
  checks[name]();
} catch (e) {
  const tail = String(e.stderr || e.stdout || "").trim().split("\n").slice(-8).join("\n");
  fail(`${name} crashed: ${e.message}${tail ? `\n${tail}` : ""}`);
}
if (problems.length) {
  console.error(problems.join("\n"));
  process.exit(1);
}
console.log(`${name}: ok`);
