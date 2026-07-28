# PR Reviewer

Polls configured GitHub repositories and has Claude review new/updated pull requests. See [CONTEXT.md](./CONTEXT.md) for terminology and [docs/adr/](./docs/adr/) for design decisions.

## Prerequisites

- Node.js
- [`gh`](https://cli.github.com/) (GitHub CLI)
- [`claude`](https://claude.com/claude-code) (Claude Code CLI), logged in
- `jq`

## Setup

1. `npm install`
2. `cp config.example.json config.json` and list the repos to watch (`owner/repo` format) and a poll interval in milliseconds.
3. Export a GitHub token with `repo` scope (used by both the Poller and the Reviewer Script):
   ```
   export GH_TOKEN=ghp_...
   ```
4. Make sure `claude` is authenticated (`claude` will prompt to log in on first interactive run if not).

## Run

```
npm start
```

The Poller reads `config.json`, checks each watched repo for open, non-draft PRs, and reviews any that haven't been reviewed at their current Head SHA. The first time a repo is seen, its existing open PRs are Baselined (marked as already reviewed) rather than reviewed immediately — see [ADR-0001](./docs/adr/0001-baseline-new-repos-instead-of-backfilling.md).

Reviewed state is tracked in a SQLite database at `./data/tracking.db` (override with `DB_PATH`). Config path can be overridden with `CONFIG_PATH`.

## Reviewing a single PR manually

The Reviewer Script can be run directly, outside the Poller:

```
bin/review-pr.sh owner/repo 123
```
