# ci-workflows

Shared GitHub Actions reusable workflows for the Synchain-oss and DLsnows repositories.
Each repository keeps only thin caller files; models, limits, timeouts, pinned versions
and the review prompt skeleton live here, so a fix lands everywhere at once.

| Workflow | What it does | Trigger in callers |
|---|---|---|
| `pr-agent.yml` | [pr-agent](https://github.com/The-PR-Agent/pr-agent) describe / review / improve. Provider `opencode-go` (DeepSeek V4.1 Flash via OpenCode Go), `deepseek-api` (DeepSeek's own API) or `anthropic` (Claude Haiku 5.5 on API credit). | `pull_request` |
| `claude-review.yml` | Claude Code review on the owner's Claude subscription, no shell, inline comments + one tracking comment. | `pull_request` |
| `deepseek-review.yml` | The same review on a DeepSeek model, for when the Claude quota is used up. | `workflow_dispatch` only |
| `bump-pr-agent.yml` | Weekly: proposes a PR when a new pr-agent image is released (provenance-verified). | this repo only |

## Policy (defaults)

- **PR into `dev`**: pr-agent (`opencode-go`) + claude-review.
- **Any other PR** (feature branches, aggregation PRs, ...): claude-review.
- **Promotion PRs** (`dev`/`stage`/`staging` into `stage`/`staging`/`prod`/`main`): no AI review.
- Repos that also run the Claude-credit pr-agent (`provider: anthropic`, all bases) mark
  `dev` as `secondary_on_bases`: there it skips `/describe` and posts review/improve as
  new comments, because two pr-agents on one PR share one comment identity and would
  overwrite each other's description and persistent comments. Their `opencode-go`
  pr-agent sets `persistent_comments: false`: in persistent mode it edits the newest
  comment carrying pr-agent's marker, which may be the Claude-credit run's.
- Draft, fork, bot-authored PRs and bot pushes are skipped.

pr-agent cost guards (do not loosen without reading the comments in `pr-agent.yml`):
one model and no fallback (`fallback_models: []`), `ai_timeout` 900 s with no retry on
timeout, explicit `max_output_tokens`, image pinned by digest. The input budget
`max_model_tokens` is counted with pr-agent's own (OpenAI) tokenizer, which undercounts
Claude tokens, so `provider: anthropic` defaults to 500000 and the others to 800000.

## Caller examples

`.github/workflows/pr-agent.yml`

```yaml
name: PR Agent Code Review
on:
  pull_request:
    branches: [dev]
    types: [opened, reopened, ready_for_review, synchronize]
permissions: {}
jobs:
  pr-agent:
    permissions: { contents: read, issues: write, pull-requests: write }
    uses: Synchain-oss/ci-workflows/.github/workflows/pr-agent.yml@v1
    with:
      provider: opencode-go
      ignore_globs: '["package-lock.json", "**/package-lock.json"]'
    secrets:
      api_key: ${{ secrets.OPENCODE_GO_API_KEY_FOR_REVIEW }}
```

`.github/workflows/claude-review.yml`

```yaml
name: Claude PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
permissions: {}
jobs:
  claude-pr-review:
    permissions: { contents: read, pull-requests: write, issues: write, actions: read }
    uses: Synchain-oss/ci-workflows/.github/workflows/claude-review.yml@v1
    with:
      focus: |
        - 正确性与回归风险
        - 安全问题(鉴权、密钥、注入、数据处理)
    secrets:
      claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

`.github/workflows/deepseek-review.yml` (manual only)

```yaml
name: DeepSeek PR Review
on:
  workflow_dispatch:
    inputs:
      pr_number: { description: PR number, required: true, type: string }
permissions: {}
jobs:
  deepseek-pr-review:
    permissions: { contents: read, pull-requests: write, issues: write }
    uses: Synchain-oss/ci-workflows/.github/workflows/deepseek-review.yml@v1
    with:
      pr_number: ${{ inputs.pr_number }}
      provider: opencode-go
      focus: |
        - 正确性与回归风险
    secrets:
      api_key: ${{ secrets.OPENCODE_GO_API_KEY_FOR_REVIEW }}
```

Notes for callers:

- The caller job must grant the permissions shown; a called workflow cannot exceed them.
- Pass secrets explicitly. `secrets: inherit` does not cross owners (DLsnows -> Synchain-oss).
- Check names become `<caller job> / <called job>` (e.g. `claude-pr-review / review`).
  Update required status checks when switching a repo over.
- Repos whose Actions policy is "selected actions" must allow
  `Synchain-oss/ci-workflows/.github/workflows/*@*` and `anthropics/claude-code-action@*`.
  pr-agent runs through `docker run`, so no image needs allowing.
- A repo `.pr_agent.toml` is still read by pr-agent and can override these settings.
  Keep `[config]` model / fallback / token keys out of it.
- `extra_prompt` is the last part of the claude-review / deepseek-review prompt, so a
  repo can end it with its untrusted-data declaration.
- pr-agent `describe: false` never rewrites the PR body (for repos whose rules fix the
  body, e.g. a sign-off as its last line); `review_labels: false` stops /review from
  adding "Review effort" / "Possible security concern" labels.

## Versioning

Callers use `@v1`, or, where repo rules forbid movable refs, `@<40-hex sha> # v1.N.M`.
Every release gets an immutable `v1.N.M` tag (lets Dependabot propose SHA bumps), and
`v1` moves to it after the change has been checked on a pilot PR:

```sh
git tag -a v1.N.M -m v1.N.M <commit> && git push origin v1.N.M
git tag -f -a v1 -m v1 <commit> && git push -f origin v1
```

Tags `v*` can only be created, moved or deleted by organization admins (ruleset).

The pr-agent and claude-review step summaries record `job.workflow_sha`, so a caller on
`@v1` can tell which version ran. For a ref that is an annotated tag (`@v1`, `@v1.N.M`)
GitHub reports the tag object's SHA, not the commit; `git rev-parse <sha>^{commit}` in a
clone (or `gh api repos/Synchain-oss/ci-workflows/git/tags/<sha> --jq .object.sha`) gives
the commit. A caller pinned to a commit SHA sees that commit.

## Pinning rule

Every third-party reference in this repo must be immutable, because a moved tag would
reach every caller at once: `uses:` refs are `owner/repo@<40-hex commit SHA> # vX.Y.Z`
(local `./` paths are fine), and container images are pinned by `@sha256:<digest>`.
`pin-check.yml` runs `.github/scripts/check-pins.sh` on every PR touching `.github/**`
and fails otherwise; a SHA pin without a trailing `# vX` comment only warns. It also
runs the checker against `.github/pin-check-fixtures/` (bad refs must fail, good refs
must pass), so removing the guard turns the check red. Run it locally with
`bash .github/scripts/check-pins.sh`.
