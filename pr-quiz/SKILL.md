---
name: pr-quiz
description: >
  Add comprehension quiz questions to GitHub pull requests to ensure engineers understand
  AI-generated code before merging. Use this skill whenever the user mentions "pr quiz",
  "PR quiz", "quiz a PR", "review quiz", "add quiz questions to a PR", or wants to verify
  an engineer understands changes in a pull request. Also trigger when the user wants to
  "grade PR answers", "check quiz responses", or "resolve quiz comments". This skill works
  with GitHub PRs via the `gh` CLI.
---

# PR Quiz Skill

Add inline quiz questions to a GitHub PR so that a human engineer must demonstrate
understanding of the changes before the PR can merge. Questions are posted as review
comments prefixed with `QUIZ:`. When the engineer replies, this skill grades their
answer — resolving the thread if correct, or posting a hint if not.

## Prerequisites

- The `gh` CLI must be authenticated (`gh auth status`).
- The working directory should be inside the target git repo, or the user must provide the repo and PR number.

## Workflow

### Step 1 — Identify the PR

Determine the PR to quiz. The user will typically give you one of:
- A PR number (e.g. `#42`)
- A PR URL (e.g. `https://github.com/org/repo/pull/42`)
- "the current PR" or "my PR" — use `gh pr view --json number,url` to find it

Extract the owner/repo and PR number. Confirm with the user if ambiguous.

### Step 2 — Check for existing QUIZ comments

Run the helper script to fetch existing review comments:

```bash
bash /path/to/pr-quiz/scripts/pr-quiz.sh list-quizzes <owner/repo> <pr-number>
```

This returns JSON with all review comments whose body starts with `QUIZ:`.

**If no QUIZ comments exist → go to Step 3 (Generate Questions).**
**If QUIZ comments exist → go to Step 4 (Grade Answers).**

### Step 3 — Generate Quiz Questions

Fetch the full diff:

```bash
gh api repos/<owner/repo>/pulls/<pr-number> --header "Accept: application/vnd.github.v3.diff"
```

Analyze the diff and generate 2–4 quiz questions. Focus on:

- **Intent & purpose** — "What problem does this change solve?" or "Why was this approach chosen over X?"
- **Edge cases & failure modes** — "What happens if this input is null/empty/very large?"
- **Interactions with existing code** — "How does this change affect the existing caching/auth/error-handling?"
- **Subtle logic** — Non-obvious conditionals, off-by-one risks, concurrency concerns

Do NOT ask:
- Trivial syntax questions ("What does `const` mean?")
- Questions answerable by reading a single obvious line
- Questions about boilerplate or auto-generated code

Each question must be tied to a specific file and line in the diff. Pick lines that are
central to the logic, not just the first line of a function.

Post each question as an inline review comment using the helper script:

```bash
bash /path/to/pr-quiz/scripts/pr-quiz.sh add-quiz <owner/repo> <pr-number> <path> <line> <side> "<question_text>"
```

- `path`: file path relative to repo root
- `line`: the diff line number to attach the comment to
- `side`: `RIGHT` for added lines (most common), `LEFT` for removed lines
- `question_text`: the full question, which will be prefixed with `QUIZ: ` automatically

After posting, summarize what you asked and which files/lines the questions target.

### Step 4 — Grade Answers

For each QUIZ comment that has replies:

1. Read the original question and the engineer's reply.
2. Re-read the relevant section of the diff for context.
3. Evaluate the answer:

**Grading criteria — be generous:**
- The engineer demonstrates they understand the *concept* and *intent*, even if wording is informal or imprecise.
- They don't need to use exact terminology.
- Partial understanding with the right direction counts as passing.
- "I think it's because X" where X is roughly correct → pass.

**Pass → Resolve the thread:**
```bash
bash /path/to/pr-quiz/scripts/pr-quiz.sh resolve-quiz <owner/repo> <pr-number> <thread-id> "<short_praise>"
```

The script will post a short reply (e.g. "Correct! ...") and then resolve the conversation thread via the GraphQL API.

**Fail → Post a hint:**
```bash
bash /path/to/pr-quiz/scripts/pr-quiz.sh hint-quiz <owner/repo> <pr-number> <comment-id> "<hint_text>"
```

Hints should:
- NOT give the full answer
- Point toward the right area of the code or concept
- Be encouraging ("Good thinking, but consider what happens when...")
- Get progressively more specific if the engineer has already received a prior hint

After grading, report a summary: which questions passed, which need another try.

### Step 5 — Check completion

If all QUIZ threads are resolved, congratulate the engineer and note the PR is ready
for merge (from a quiz perspective). If some remain, list the outstanding questions.

## Important notes

- **Never resolve a thread without the engineer replying.** The whole point is comprehension.
- **Don't grade your own questions.** If the quiz was generated in this same session, wait for the engineer to reply in GitHub before grading.
- **Respect existing non-quiz comments.** Only interact with comments prefixed `QUIZ:`.
- **Commit SHA matters.** When posting inline comments, use the latest commit SHA on the PR head. The helper script handles this.
- **If the diff is trivial** (e.g., a one-line typo fix), tell the user a quiz isn't warranted and skip it.
