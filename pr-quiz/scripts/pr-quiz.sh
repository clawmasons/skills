#!/usr/bin/env bash
# pr-quiz.sh — Helper script for the pr-quiz skill
# Wraps GitHub CLI / API calls for managing QUIZ review comments on PRs.
#
# Usage:
#   pr-quiz.sh list-quizzes <owner/repo> <pr-number>
#   pr-quiz.sh add-quiz <owner/repo> <pr-number> <path> <line> <side> "<question>"
#   pr-quiz.sh resolve-quiz <owner/repo> <pr-number> <thread-id> "<praise_message>"
#   pr-quiz.sh hint-quiz <owner/repo> <pr-number> <comment-id> "<hint>"
#   pr-quiz.sh get-replies <owner/repo> <pr-number>

set -euo pipefail

COMMAND="${1:?Usage: pr-quiz.sh <command> ...}"
REPO="${2:?Missing owner/repo}"
PR_NUMBER="${3:?Missing PR number}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

get_head_sha() {
  gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.head.sha'
}

get_review_comments() {
  # Fetches all review comments on the PR, paginated
  gh api --paginate "repos/${REPO}/pulls/${PR_NUMBER}/comments" \
    --jq '.[] | {id: .id, node_id: .node_id, path: .path, line: .line, side: .side, body: .body, in_reply_to_id: .in_reply_to_id, user: .user.login, created_at: .created_at, url: .html_url}'
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

case "$COMMAND" in

  list-quizzes)
    # Return all QUIZ: comments and their reply threads
    echo "Fetching review comments for ${REPO}#${PR_NUMBER}..." >&2

    ALL_COMMENTS=$(gh api --paginate "repos/${REPO}/pulls/${PR_NUMBER}/comments")

    echo "$ALL_COMMENTS" | jq '
      . as $all |
      [.[] | select(.in_reply_to_id == null and (.body | startswith("QUIZ:")))] |
      map(
        . as $q |
        {
          id: $q.id,
          node_id: $q.node_id,
          path: $q.path,
          line: $q.line,
          body: $q.body,
          user: $q.user.login,
          created_at: $q.created_at,
          replies: [
            $all[] |
            select(.in_reply_to_id == $q.id) |
            {
              id: .id,
              body: .body,
              user: .user.login,
              created_at: .created_at
            }
          ]
        }
      )'
    ;;

  add-quiz)
    PATH_IN_REPO="${4:?Missing file path}"
    LINE="${5:?Missing line number}"
    SIDE="${6:?Missing side (LEFT or RIGHT)}"
    QUESTION="${7:?Missing question text}"

    COMMIT_SHA=$(get_head_sha)

    BODY="QUIZ: ${QUESTION}"

    # Post as a pull request review comment (single comment, not part of a review)
    gh api "repos/${REPO}/pulls/${PR_NUMBER}/comments" \
      --method POST \
      --field "body=${BODY}" \
      --field "commit_id=${COMMIT_SHA}" \
      --field "path=${PATH_IN_REPO}" \
      --field "line=${LINE}" \
      --field "side=${SIDE}" \
      --jq '{id: .id, node_id: .node_id, path: .path, line: .line, body: .body, html_url: .html_url}'

    echo "Quiz question posted on ${PATH_IN_REPO}:${LINE}"
    ;;

  resolve-quiz)
    THREAD_NODE_ID="${4:?Missing thread node_id}"
    PRAISE="${5:?Missing praise message}"

    # First, reply with praise
    # We need the comment ID (numeric) to reply. The thread_node_id is the GraphQL node_id.
    # Find the numeric id from the node_id by querying comments
    QUIZ_COMMENT_ID=$(gh api --paginate "repos/${REPO}/pulls/${PR_NUMBER}/comments" \
      --jq ".[] | select(.node_id == \"${THREAD_NODE_ID}\") | .id")

    if [ -z "$QUIZ_COMMENT_ID" ]; then
      echo "Error: Could not find comment with node_id ${THREAD_NODE_ID}"
      exit 1
    fi

    # Post the praise as a reply
    gh api "repos/${REPO}/pulls/${PR_NUMBER}/comments" \
      --method POST \
      --field "body=✅ ${PRAISE}" \
      --field "in_reply_to=${QUIZ_COMMENT_ID}" \
      --jq '{id: .id, body: .body}' || true

    # Resolve the thread using GraphQL
    # First, find the thread ID (the review thread, not the comment)
    # We need to use GraphQL to resolve the thread
    QUERY='
    query($owner: String!, $repo: String!, $pr: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr) {
          reviewThreads(first: 100) {
            nodes {
              id
              isResolved
              comments(first: 1) {
                nodes {
                  id
                  databaseId
                }
              }
            }
          }
        }
      }
    }'

    OWNER=$(echo "$REPO" | cut -d'/' -f1)
    REPO_NAME=$(echo "$REPO" | cut -d'/' -f2)

    THREAD_GQL_ID=$(gh api graphql \
      -f query="$QUERY" \
      -f owner="$OWNER" \
      -f repo="$REPO_NAME" \
      -F pr="$PR_NUMBER" \
      --jq ".data.repository.pullRequest.reviewThreads.nodes[] |
            select(.comments.nodes[0].databaseId == ${QUIZ_COMMENT_ID}) | .id")

    if [ -z "$THREAD_GQL_ID" ]; then
      echo "Warning: Could not find GraphQL thread ID. The praise was posted but the thread was not auto-resolved."
      echo "The engineer or a reviewer can manually resolve it."
      exit 0
    fi

    # Resolve the thread
    RESOLVE_MUTATION='
    mutation($threadId: ID!) {
      resolveReviewThread(input: {threadId: $threadId}) {
        thread {
          id
          isResolved
        }
      }
    }'

    gh api graphql \
      -f query="$RESOLVE_MUTATION" \
      -f threadId="$THREAD_GQL_ID" \
      --jq '.data.resolveReviewThread.thread | {id, isResolved}'

    echo "Thread resolved for quiz comment ${QUIZ_COMMENT_ID}"
    ;;

  hint-quiz)
    COMMENT_ID="${4:?Missing comment ID to reply to}"
    HINT="${5:?Missing hint text}"

    # Post the hint as a reply to the quiz comment
    gh api "repos/${REPO}/pulls/${PR_NUMBER}/comments" \
      --method POST \
      --field "body=💡 Not quite — ${HINT}" \
      --field "in_reply_to=${COMMENT_ID}" \
      --jq '{id: .id, body: .body, html_url: .html_url}'

    echo "Hint posted as reply to comment ${COMMENT_ID}"
    ;;

  get-replies)
    # Get all quiz comments with their replies, useful for grading
    ALL_COMMENTS=$(gh api --paginate "repos/${REPO}/pulls/${PR_NUMBER}/comments")

    echo "$ALL_COMMENTS" | jq '
      . as $all |
      [.[] | select(.in_reply_to_id == null and (.body | startswith("QUIZ:")))] |
      map(
        . as $q |
        {
          quiz_id: $q.id,
          node_id: $q.node_id,
          path: $q.path,
          line: $q.line,
          question: $q.body,
          replies: [
            $all[] |
            select(.in_reply_to_id == $q.id) |
            select((.body | startswith("QUIZ:")) | not) |
            select((.body | startswith("✅")) | not) |
            select((.body | startswith("💡")) | not) |
            {
              id: .id,
              body: .body,
              user: .user.login,
              created_at: .created_at
            }
          ]
        }
      )'
    ;;

  *)
    echo "Unknown command: $COMMAND"
    echo "Usage:"
    echo "  pr-quiz.sh list-quizzes <owner/repo> <pr-number>"
    echo "  pr-quiz.sh add-quiz <owner/repo> <pr-number> <path> <line> <side> <question>"
    echo "  pr-quiz.sh resolve-quiz <owner/repo> <pr-number> <thread-node-id> <praise>"
    echo "  pr-quiz.sh hint-quiz <owner/repo> <pr-number> <comment-id> <hint>"
    echo "  pr-quiz.sh get-replies <owner/repo> <pr-number>"
    exit 1
    ;;
esac
