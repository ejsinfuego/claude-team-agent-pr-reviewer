#!/usr/bin/env bash
# Reviewer Script: performs one Review end-to-end for a single PR.
# Posts inline comments only (no summary body); if Claude finds nothing
# worth flagging, no Review is posted at all.
# Usage: review-pr.sh <owner/repo> <pr-number> <head-sha>
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <owner/repo> <pr-number> <head-sha>" >&2
  exit 1
fi

REPO="$1"
PR_NUMBER="$2"
HEAD_SHA="$3"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

DIFF_FILE="$WORKDIR/diff.patch"
LINES_FILE="$WORKDIR/lines.tsv"
ANNOTATED_FILE="$WORKDIR/annotated.txt"
VALID_LINES_FILE="$WORKDIR/valid_lines.tsv"
PROMPT_FILE="$WORKDIR/prompt.txt"
RAW_RESPONSE_FILE="$WORKDIR/response.txt"
FILTERED_FILE="$WORKDIR/filtered_comments.jsonl"

# Files that are essentially never worth a code-review comment (lockfiles,
# generated/minified/vendored output, binary assets) but can be huge — excluded
# from the diff entirely so they don't burn tokens for no benefit.
IGNORED_DIFF_PATTERNS=(
  "package-lock.json" "npm-shrinkwrap.json" "yarn.lock" "pnpm-lock.yaml"
  "composer.lock" "Gemfile.lock" "Cargo.lock" "poetry.lock"
  "*.min.js" "*.min.css" "*.map"
  "dist/*" "dist/**" "build/*" "build/**" "vendor/*" "vendor/**"
  "*.svg" "*.png" "*.jpg" "*.jpeg" "*.gif" "*.ico"
  "*.woff" "*.woff2" "*.ttf" "*.eot"
)
EXCLUDE_FLAGS=()
for pattern in "${IGNORED_DIFF_PATTERNS[@]}"; do
  EXCLUDE_FLAGS+=(--exclude "$pattern")
done

gh pr diff "$PR_NUMBER" --repo "$REPO" "${EXCLUDE_FLAGS[@]}" > "$DIFF_FILE"

# Annotate the diff with new-file (RIGHT-side) line numbers, so Claude only
# has to copy a line number rather than compute one (removed lines are
# omitted entirely, so there's nothing to hallucinate a number for).
# Emits "path\tline\tmarker\tcontent" per commentable line.
awk '
  /^\+\+\+ / {
    path = $2
    sub(/^b\//, "", path)
    next
  }
  /^@@ / {
    match($0, /\+[0-9]+/)
    newLine = substr($0, RSTART + 1, RLENGTH - 1) + 0
    next
  }
  /^\+/ {
    print path "\t" newLine "\t+\t" substr($0, 2)
    newLine++
    next
  }
  /^-/ { next }
  /^ / {
    print path "\t" newLine "\t \t" substr($0, 2)
    newLine++
    next
  }
' "$DIFF_FILE" > "$LINES_FILE"

cut -f1,2 "$LINES_FILE" > "$VALID_LINES_FILE"
awk -F'\t' '{ printf "%s:%s: [%s] %s\n", $1, $2, $3, $4 }' "$LINES_FILE" > "$ANNOTATED_FILE"

VIEW_JSON=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json title,body,comments)
TITLE=$(jq -r '.title' <<< "$VIEW_JSON")
BODY=$(jq -r '.body // "(no description)"' <<< "$VIEW_JSON")

# Capped to the most recent DISCUSSION_LIMIT so a long-running back-and-forth
# (or CI bot noise) doesn't grow this section's token cost unbounded over a
# long-lived PR's lifetime — same issue the past-review-comments cap fixes below.
DISCUSSION_LIMIT=20
DISCUSSION_TOTAL=$(jq '(.comments // []) | length' <<< "$VIEW_JSON")
if [[ "$DISCUSSION_TOTAL" -gt "$DISCUSSION_LIMIT" ]]; then
  echo "Only including the most recent $DISCUSSION_LIMIT of $DISCUSSION_TOTAL PR comments for $REPO#$PR_NUMBER" >&2
fi
COMMENTS=$(jq -r --argjson limit "$DISCUSSION_LIMIT" '
  (.comments // []) |
  if length == 0 then "(none)"
  else (.[-$limit:] | map("- " + .author.login + ": " + .body) | join("\n"))
  end
' <<< "$VIEW_JSON")

# Inline comments from earlier reviews on this PR (across all past Head SHAs),
# so Claude doesn't re-flag an issue it already raised last time. Capped to
# the most recent PAST_COMMENTS_LIMIT so token cost doesn't grow unbounded
# over a long-lived PR's lifetime, and suggestion blocks are stripped since
# only the point being made (not the old suggested code) matters for dedup.
PAST_COMMENTS_LIMIT=50
PAST_REVIEW_COMMENTS_JSON=$(gh api "repos/$REPO/pulls/$PR_NUMBER/comments" --paginate)
PAST_COMMENTS_TOTAL=$(jq 'length' <<< "$PAST_REVIEW_COMMENTS_JSON")
if [[ "$PAST_COMMENTS_TOTAL" -gt "$PAST_COMMENTS_LIMIT" ]]; then
  echo "Only including the most recent $PAST_COMMENTS_LIMIT of $PAST_COMMENTS_TOTAL past review comments for $REPO#$PR_NUMBER" >&2
fi
PAST_REVIEW_COMMENTS=$(jq -r --argjson limit "$PAST_COMMENTS_LIMIT" '
  if length == 0 then "(none)"
  else (
    sort_by(.id) | .[-$limit:] |
    map(
      "- " + .path + ":" + ((.line // .original_line) | tostring) + ": " +
      (.body | sub("\n\n```suggestion.*"; ""; "m"))
    ) | join("\n")
  )
  end
' <<< "$PAST_REVIEW_COMMENTS_JSON")

{
  echo "You are reviewing GitHub pull request #$PR_NUMBER in $REPO."
  echo "Respond with ONLY a JSON array (no markdown fences, no prose) of inline review comments."
  echo 'Each element must look exactly like: {"path": "<file path>", "line": <line number>, "body": "<comment>", "suggestion": "<replacement line, or omit this field>"}'
  echo 'The "line" value MUST be copied exactly from one of the "path:line:" annotations shown below — never compute or guess a line number yourself.'
  echo 'Include "suggestion" ONLY when you have a concrete, literal one-line code replacement for that exact line — the exact code that should replace it, with no diff markers, no line number, and no markdown fences. Omit "suggestion" entirely for feedback that is not a direct line replacement (structural concerns, missing tests, design questions, multi-line fixes).'
  echo "Only comment on lines you have a specific, concrete concern about (bugs, risks, correctness issues, meaningful improvements). Do not repeat points already made in the existing discussion or already flagged in a previous review below, even if the underlying issue is still present in the diff. Do not leave nitpicks or praise."
  echo "If there is nothing worth flagging, respond with exactly: []"
  echo
  echo "## Title"
  echo "$TITLE"
  echo
  echo "## Description"
  echo "$BODY"
  echo
  echo "## Existing discussion"
  echo "$COMMENTS"
  echo
  echo "## Already flagged in a previous review (do not repeat these)"
  echo "$PAST_REVIEW_COMMENTS"
  echo
  echo "## Diff (annotated with new-file line numbers)"
  echo '```'
  cat "$ANNOTATED_FILE"
  echo '```'
} > "$PROMPT_FILE"

claude -p --model haiku --allowedTools "" < "$PROMPT_FILE" > "$RAW_RESPONSE_FILE"

# Strip stray markdown fences in case the model added them despite instructions.
sed -e '/^```/d' "$RAW_RESPONSE_FILE" > "$WORKDIR/comments.json"

if ! jq -e 'type == "array"' "$WORKDIR/comments.json" > /dev/null 2>&1; then
  echo "claude did not return a JSON array for $REPO#$PR_NUMBER:" >&2
  cat "$RAW_RESPONSE_FILE" >&2
  exit 1
fi

: > "$FILTERED_FILE"
jq -c '.[]' "$WORKDIR/comments.json" | while IFS= read -r comment; do
  path=$(jq -r '.path' <<< "$comment")
  line=$(jq -r '.line' <<< "$comment")
  if grep -qxF -- "$(printf '%s\t%s' "$path" "$line")" "$VALID_LINES_FILE"; then
    # Fold "suggestion" (if present) into a GitHub suggestion block so it
    # renders with an Apply/commit button, same as a human or Copilot review.
    jq -c '
      {
        path: .path,
        line: .line,
        body: (
          "🤖 **Claude**: " + .body +
          (
            if ((.suggestion // "") | length) > 0
            then "\n\n```suggestion\n" + .suggestion + "\n```"
            else ""
            end
          )
        )
      }
    ' <<< "$comment" >> "$FILTERED_FILE"
  else
    echo "Dropping comment on non-diff line $path:$line for $REPO#$PR_NUMBER" >&2
  fi
done

if [[ ! -s "$FILTERED_FILE" ]]; then
  echo "No inline comments to post for $REPO#$PR_NUMBER; skipping review."
  exit 0
fi

jq -n \
  --arg commit_id "$HEAD_SHA" \
  --argjson comments "$(jq -s '.' "$FILTERED_FILE")" \
  '{commit_id: $commit_id, event: "COMMENT", comments: $comments}' \
  | gh api --method POST "repos/$REPO/pulls/$PR_NUMBER/reviews" --input -
