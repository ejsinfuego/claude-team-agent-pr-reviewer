import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

const SCHEMA = `
CREATE TABLE IF NOT EXISTS watched_repos (
  repo TEXT PRIMARY KEY,
  baselined_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS reviewed_prs (
  repo TEXT NOT NULL,
  pr_number INTEGER NOT NULL,
  head_sha TEXT NOT NULL,
  reviewed_at TEXT NOT NULL,
  PRIMARY KEY (repo, pr_number, head_sha)
);
`;

export class TrackingStore {
  constructor(dbPath) {
    mkdirSync(dirname(dbPath), { recursive: true });
    this.db = new Database(dbPath);
    this.db.pragma("journal_mode = WAL");
    this.db.exec(SCHEMA);

    this.isBaselinedStmt = this.db.prepare(
      "SELECT 1 FROM watched_repos WHERE repo = ?"
    );
    this.baselineRepoStmt = this.db.prepare(
      "INSERT OR IGNORE INTO watched_repos (repo, baselined_at) VALUES (?, ?)"
    );
    this.isReviewedStmt = this.db.prepare(
      "SELECT 1 FROM reviewed_prs WHERE repo = ? AND pr_number = ? AND head_sha = ?"
    );
    this.markReviewedStmt = this.db.prepare(
      "INSERT OR IGNORE INTO reviewed_prs (repo, pr_number, head_sha, reviewed_at) VALUES (?, ?, ?, ?)"
    );
  }

  isBaselined(repo) {
    return this.isBaselinedStmt.get(repo) !== undefined;
  }

  // Marks a repo as baselined and records every currently-open PR as already
  // reviewed, without generating a Review for any of them. See ADR-0001.
  baseline(repo, openPrs) {
    const now = new Date().toISOString();
    const tx = this.db.transaction(() => {
      for (const pr of openPrs) {
        this.markReviewedStmt.run(repo, pr.number, pr.headSha, now);
      }
      this.baselineRepoStmt.run(repo, now);
    });
    tx();
  }

  isReviewed(repo, prNumber, headSha) {
    return this.isReviewedStmt.get(repo, prNumber, headSha) !== undefined;
  }

  markReviewed(repo, prNumber, headSha) {
    this.markReviewedStmt.run(repo, prNumber, headSha, new Date().toISOString());
  }

  close() {
    this.db.close();
  }
}
