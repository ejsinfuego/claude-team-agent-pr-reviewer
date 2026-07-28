# PR Reviewer

Polls configured GitHub repositories and has Claude review new/updated pull requests. See [CONTEXT.md](./CONTEXT.md) for terminology and [docs/adr/](./docs/adr/) for design decisions.

## Prerequisites

- Node.js
- [`gh`](https://cli.github.com/) (GitHub CLI)
- [`claude`](https://claude.com/claude-code) (Claude Code CLI), logged in
- `jq`

## Setup

1. `npm install`
2. `cp config.example.json config.json` and set the repos to watch (`owner/repo` format), a poll interval in milliseconds, and the target base branch PRs must open against (e.g. `develop`).
3. Export a GitHub token with `repo` scope (used by both the Poller and the Reviewer Script):
   ```
   export GH_TOKEN=ghp_...
   ```
4. Make sure `claude` is authenticated (`claude` will prompt to log in on first interactive run if not).

## Run

```
npm start
```

The Poller reads `config.json`, checks each watched repo for open, non-draft PRs targeting `targetBranch`, and reviews any that haven't been reviewed at their current Head SHA. The first time a repo is seen, its existing open PRs are Baselined (marked as already reviewed) rather than reviewed immediately — see [ADR-0001](./docs/adr/0001-baseline-new-repos-instead-of-backfilling.md).

Reviews are posted as inline comments only, anchored to specific diff lines — there's no summary body, and if Claude finds nothing worth flagging, no review is posted at all.

Reviewed state is tracked in a SQLite database at `./data/tracking.db` (override with `DB_PATH`). Config path can be overridden with `CONFIG_PATH`.

## Reviewing a single PR manually

The Reviewer Script can be run directly, outside the Poller. It needs the PR's head commit SHA as a third argument:

```
gh pr view 123 --repo owner/repo --json headRefOid -q .headRefOid
bin/review-pr.sh owner/repo 123 <head-sha>
```
