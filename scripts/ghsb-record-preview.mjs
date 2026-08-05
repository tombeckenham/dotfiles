#!/usr/bin/env node
/**
 * Record a Playwright walkthrough video of a PR preview / dev URL.
 *
 * Usage:
 *   node ghsb-record-preview.mjs --url <preview-url> --out <dir> [--name walkthrough]
 *   node ghsb-record-preview.mjs --url <url> --out <dir> --paths /,/settings,/login
 *
 * Requires: playwright (npx playwright install chromium on first use)
 */

import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";

function parseArgs(argv) {
  const out = { url: "", outDir: "", name: "walkthrough", paths: ["/"], width: 1280, height: 720 };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--url") out.url = argv[++i];
    else if (a === "--out") out.outDir = argv[++i];
    else if (a === "--name") out.name = argv[++i];
    else if (a === "--paths") out.paths = argv[++i].split(",").map((p) => p.trim()).filter(Boolean);
    else if (a === "--width") out.width = Number(argv[++i]);
    else if (a === "--height") out.height = Number(argv[++i]);
    else if (a === "-h" || a === "--help") {
      console.log(`Usage: ghsb-record-preview.mjs --url <url> --out <dir> [--paths /,/a] [--name walkthrough]`);
      process.exit(0);
    }
  }
  if (!out.url || !out.outDir) {
    console.error("Required: --url and --out");
    process.exit(2);
  }
  return out;
}

async function ensurePlaywright() {
  try {
    await import("playwright");
    return;
  } catch {
    console.error("playwright not found; installing via npx...");
  }
  const r = spawnSync("npm", ["install", "--no-save", "playwright"], {
    stdio: "inherit",
    cwd: process.cwd(),
  });
  if (r.status !== 0) {
    console.error("Failed to install playwright. Run: npm i -D playwright && npx playwright install chromium");
    process.exit(1);
  }
  spawnSync("npx", ["playwright", "install", "chromium"], { stdio: "inherit" });
}

async function main() {
  const opts = parseArgs(process.argv);
  await ensurePlaywright();
  const { chromium } = await import("playwright");

  await mkdir(opts.outDir, { recursive: true });
  const videoDir = join(opts.outDir, "video-raw");
  await mkdir(videoDir, { recursive: true });

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    recordVideo: { dir: videoDir, size: { width: opts.width, height: opts.height } },
    viewport: { width: opts.width, height: opts.height },
  });
  const page = await context.newPage();

  const base = opts.url.replace(/\/$/, "");
  const visited = [];
  const errors = [];

  page.on("pageerror", (err) => errors.push(`pageerror: ${err.message}`));
  page.on("console", (msg) => {
    if (msg.type() === "error") errors.push(`console: ${msg.text()}`);
  });

  for (const p of opts.paths) {
    const path = p.startsWith("http") ? p : `${base}${p.startsWith("/") ? p : `/${p}`}`;
    try {
      console.error(`→ ${path}`);
      await page.goto(path, { waitUntil: "networkidle", timeout: 60_000 });
      await page.waitForTimeout(1500);
      // light scroll so sticky headers / lazy content show up
      await page.evaluate(async () => {
        const step = Math.max(200, Math.floor(window.innerHeight * 0.6));
        for (let y = 0; y < document.body.scrollHeight; y += step) {
          window.scrollTo(0, y);
          await new Promise((r) => setTimeout(r, 200));
        }
        window.scrollTo(0, 0);
      });
      await page.waitForTimeout(800);
      visited.push(path);
    } catch (e) {
      errors.push(`goto ${path}: ${e.message}`);
      console.error(`  failed: ${e.message}`);
    }
  }

  await context.close();
  await browser.close();

  // Playwright writes webm into videoDir; move/rename to stable path
  const { readdir, rename, copyFile } = await import("node:fs/promises");
  const files = (await readdir(videoDir)).filter((f) => f.endsWith(".webm"));
  const destVideo = join(opts.outDir, `${opts.name}.webm`);
  if (files.length > 0) {
    await rename(join(videoDir, files[0]), destVideo);
  }

  const manifest = {
    url: opts.url,
    paths: opts.paths,
    visited,
    errors,
    video: files.length ? destVideo : null,
    recordedAt: new Date().toISOString(),
  };
  await writeFile(join(opts.outDir, `${opts.name}.json`), JSON.stringify(manifest, null, 2));

  if (!manifest.video) {
    console.error("No video file produced");
    process.exit(1);
  }
  console.log(destVideo);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
