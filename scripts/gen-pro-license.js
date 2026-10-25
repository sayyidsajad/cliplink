#!/usr/bin/env node
/**
 * Mint a ClipLink Pro license key (one-time purchase — no subscription).
 *
 * Usage:
 *   node scripts/gen-pro-license.js <serial>          # uses backend/.dev.vars or $LICENSE_KEY_SEED
 *
 * <serial> is any stable string you keep with the sale (e.g. "0001",
 * "buyer@example.com", "2026-10-25#1"). Two different serials produce two
 * different valid keys; the same serial always produces the same key.
 *
 * NEVER share LICENSE_KEY_SEED and never run this with the prod seed on a
 * shared machine — anyone with the seed can mint unlimited valid keys.
 */
import { readFile } from "node:fs/promises";
import { generateLicenseKey } from "../backend/src/license.js";

const serial = process.argv[2];
if (!serial) {
  console.error("usage: node scripts/gen-pro-license.js <serial>");
  process.exit(2);
}

let seed = process.env.LICENSE_KEY_SEED || "";
if (!seed) {
  try {
    const vars = await readFile(new URL("../backend/.dev.vars", import.meta.url), "utf8");
    for (const line of vars.split("\n")) {
      const m = line.match(/^LICENSE_KEY_SEED="?([^"\n]+)"?\s*$/);
      if (m) seed = m[1].trim();
    }
  } catch { /* no .dev.vars */ }
}

if (!seed) {
  console.error("LICENSE_KEY_SEED not set (env or backend/.dev.vars)");
  process.exit(1);
}

const key = await generateLicenseKey({ LICENSE_KEY_SEED: seed }, serial);
console.log(key);
