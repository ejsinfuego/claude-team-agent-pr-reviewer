# Baseline new repos instead of backfilling their existing PRs

When a Watched Repository is added to `config.json`, it may already have many open PRs. We decided the Poller should Baseline it — mark all currently-open PRs as already having Reviewed State without generating a Review — rather than reviewing every pre-existing PR immediately. This avoids a burst of reviews (and `claude -p` invocations) triggered purely by adding a repo to the config; the cost is that pre-existing PRs only get reviewed once they receive new commits.
