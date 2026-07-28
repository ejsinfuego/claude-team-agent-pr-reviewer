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

gh pr diff "$PR_NUMBER" --repo "$REPO" > "$DIFF_FILE"

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
COMMENTS=$(jq -r '
  (.comments // []) |
  if length == 0 then "(none)"
  else (map("- " + .author.login + ": " + .body) | join("\n"))
  end
' <<< "$VIEW_JSON")

{
  echo "You are reviewing GitHub pull request #$PR_NUMBER in $REPO."
  echo "Respond with ONLY a JSON array (no markdown fences, no prose) of inline review comments."
  echo 'Each element must look exactly like: {"path": "<file path>", "line": <line number>, "body": "<comment>", "suggestion": "<replacement line, or omit this field>"}'
  echo 'The "line" value MUST be copied exactly from one of the "path:line:" annotations shown below — never compute or guess a line number yourself.'
  echo 'Include "suggestion" ONLY when you have a concrete, literal one-line code replacement for that exact line — the exact code that should replace it, with no diff markers, no line number, and no markdown fences. Omit "suggestion" entirely for feedback that is not a direct line replacement (structural concerns, missing tests, design questions, multi-line fixes).'
  echo "Only comment on lines you have a specific, concrete concern about (bugs, risks, correctness issues, meaningful improvements). Do not repeat points already made in the existing discussion below. Do not leave nitpicks or praise."
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
  echo "## Diff (annotated with new-file line numbers)"
  echo '```'
  cat "$ANNOTATED_FILE"
  echo '```'
} > "$PROMPT_FILE"

claude -p --allowedTools "" < "$PROMPT_FILE" > "$RAW_RESPONSE_FILE"

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
