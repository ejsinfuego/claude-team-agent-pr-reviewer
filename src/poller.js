import { readFileSync } from "node:fs";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { TrackingStore } from "./db.js";
import { createGithubClient } from "./github.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REVIEW_SCRIPT = path.join(__dirname, "..", "bin", "review-pr.sh");

function loadConfig(configPath) {
  const raw = JSON.parse(readFileSync(configPath, "utf8"));
  if (!Array.isArray(raw.repos) || raw.repos.length === 0) {
    throw new Error("config.json must list at least one repo in `repos`");
  }
  if (!Number.isFinite(raw.pollIntervalMs) || raw.pollIntervalMs <= 0) {
    throw new Error("config.json must set a positive `pollIntervalMs`");
  }
  return raw;
}

function runReviewScript(repo, prNumber) {
  return new Promise((resolve) => {
    const child = spawn(REVIEW_SCRIPT, [repo, String(prNumber)], {
      stdio: "inherit",
      env: process.env,
    });
    child.on("exit", (code) => resolve(code === 0));
    child.on("error", (err) => {
      console.error(`Failed to start review script for ${repo}#${prNumber}:`, err);
      resolve(false);
    });
  });
}

// Serial Review Queue: one review at a time, in the order discovered.
async function processQueue(queue, store) {
  for (const job of queue) {
    console.log(`Reviewing ${job.repo}#${job.number} @ ${job.headSha}`);
    const ok = await runReviewScript(job.repo, job.number);
    if (ok) {
      store.markReviewed(job.repo, job.number, job.headSha);
      console.log(`Reviewed ${job.repo}#${job.number}`);
    } else {
      console.error(`Review failed for ${job.repo}#${job.number}; will retry next poll`);
    }
  }
}

async function pollOnce(config, github, store) {
  const queue = [];

  for (const repo of config.repos) {
    let openPrs;
    try {
      openPrs = await github.listOpenPrs(repo);
    } catch (err) {
      console.error(`Failed to list PRs for ${repo}:`, err.message);
      continue;
    }

    if (!store.isBaselined(repo)) {
      store.baseline(repo, openPrs);
      console.log(
        `Baselined ${repo}: ${openPrs.length} existing open PR(s) marked reviewed (see ADR-0001)`
      );
      continue;
    }

    for (const pr of openPrs) {
      if (!store.isReviewed(repo, pr.number, pr.headSha)) {
        queue.push({ repo, number: pr.number, headSha: pr.headSha });
      }
    }
  }

  await processQueue(queue, store);
}

async function main() {
  const configPath = process.env.CONFIG_PATH || "./config.json";
  const dbPath = process.env.DB_PATH || "./data/tracking.db";
  const token = process.env.GH_TOKEN;

  if (!token) {
    throw new Error("GH_TOKEN environment variable is required");
  }

  const config = loadConfig(configPath);
  const github = createGithubClient(token);
  const store = new TrackingStore(dbPath);

  const tick = async () => {
    try {
      await pollOnce(config, github, store);
    } catch (err) {
      console.error("Poll cycle failed:", err);
    } finally {
      setTimeout(tick, config.pollIntervalMs);
    }
  };

  console.log(
    `Starting Poller: watching ${config.repos.join(", ")} every ${config.pollIntervalMs}ms`
  );
  await tick();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
