# Ralph -- Design Considerations

This document captures the architectural decisions, security posture, and deferred concerns for Ralph. It exists so that future reviews have the full context of what was considered, what was addressed, what was deliberately left alone, and why.

## Architecture: batch loop, not agent framework

Ralph is a bash loop that calls `claude -p` with a static prompt per iteration. Each iteration gets a fresh context window. This is deliberate:

- Long-running Claude Code sessions degrade as context fills up. Fresh context per task avoids this entirely.
- A failed iteration can revert cleanly without corrupting state from previous iterations.
- The loop is debuggable with standard unix tools (grep the log, check git log, read the journal).
- There is no hidden state between iterations. The only shared state is the git repo and `IMPLEMENTATION_PLAN.md`.

This is simpler than multi-turn agent frameworks with tool registries, memory systems, and orchestration layers. That simplicity is a feature -- fewer moving parts means fewer failure modes for an autonomous system.

## Implementation plan: single file by design

The implementation plan is one markdown file (`IMPLEMENTATION_PLAN.md`) rather than a directory of task files or a database. This was evaluated against alternatives:

**Why one file works better for the planner:**
- The planner reads all specs, scans the codebase, and produces/updates the task list in a single Claude session. Having the full plan in one read lets it reason about task ordering, dependencies, and gaps across all specs at once.
- With separate task files, the planner would need to read every file, cross-reference them, and coordinate additions/removals across files. This increases the chance of the planner missing existing tasks or creating duplicates.
- The plan is the planner's primary output. Keeping it as a single coherent document makes the planner's job closer to "edit a document" than "manage a filesystem," which is a task LLMs handle more reliably.

**Why not a database:**
- Ralph runs inside a Docker container with a mounted project directory. Adding SQLite or similar introduces a dependency and a binary file that can't be diffed, reviewed in PRs, or manually edited.
- The plan is small (hundreds of lines even for large projects). The scaling concern is theoretical at current project sizes.
- If the plan outgrows a single file, migrating to structured storage (SQLite, YAML, JSONL) is straightforward. The loop and prompts are the only consumers. This is a deferred concern, not a design flaw.

**Mechanical integrity checks compensate for the format:**
- The loop counts `[x]` lines before and after planning and rejects plans that drop completed tasks.
- HTML comments (`<!-- spec:NN -->`) provide greppable metadata without changing the format.
- The `Files:` field on each task enables post-commit diff validation by the loop script.

## Security posture

### Container runs as non-root user `ralph`

The Dockerfile creates a `ralph` user and switches to it before running. Combined with `--dangerously-skip-permissions`, this means:

- Claude Code can read/write files in the mounted project directory (owned by the mount, typically the host user).
- Claude Code **cannot** `apt install`, modify system files, or escalate privileges inside the container.
- The `--dangerously-skip-permissions` flag skips Claude Code's interactive permission prompts. It does not grant additional OS-level permissions. The `ralph` user's filesystem and process permissions are the actual security boundary.

### Docker socket access

The Docker socket (`/var/run/docker.sock`) is mounted into the Ralph container so the build agent can manage application stack containers (e.g., `docker compose exec web npm test`). This is required -- Ralph's architecture separates the build agent from the application stacks, and the socket is how it orchestrates them.

**Known risk:** the Docker socket grants unrestricted Docker API access. Code running inside the Ralph container could `docker run --privileged -v /:/host alpine` and access the host filesystem as root. The non-root `ralph` user provides zero additional security here -- the Docker daemon runs as root on the host and honors any command from a socket client regardless of the client's UID.

The realistic threat is hallucinated destructive commands (e.g., `docker system prune -af`, `docker compose down -v`), not deliberate exploitation. The build agent has no incentive to escalate privileges, but it can hallucinate plausible-looking Docker commands that happen to be destructive.

**Mitigation options evaluated:**

1. **Tecnativa/docker-socket-proxy** -- a container that sits between Ralph and the Docker socket, allowlisting specific Docker API endpoints (e.g., `/containers/create`, `/exec`, `/build`). Setup is roughly 10 lines in docker-compose.yml. However, the allowlist operates at the endpoint level, not the flag level. Allowing `/containers/create` (required for `docker compose up`) also allows `--privileged` and arbitrary volume mounts on that endpoint. This limits the blast radius (can't call `/system/prune`, `/volumes/prune`, etc.) but does not eliminate the privilege escalation path.

2. **Wrapper script** -- a shell wrapper around `docker` that pattern-matches and blocks dangerous flags (`--privileged`, `-v /:/`, `system prune`, `--rm -it`). This is simpler to deploy (bind-mount the script, alias `docker` to it) and catches the hallucinated-command threat directly. The downside is that it's a denylist -- new dangerous patterns require updating the wrapper.

3. **Both** -- the proxy blocks unexpected API endpoints; the wrapper blocks dangerous flags on allowed endpoints.

**Decision:** for local single-user development, neither is required -- the risk is acceptable and the build prompt constrains behavior. For shared or CI environments, the socket proxy is mandatory and a wrapper script is recommended. The wrapper script alone is a reasonable middle ground for cautious local use.

### Network access

The build agent has full network access. This is required:

- Scaffolding tasks run `npm install`, `go mod download`, etc.
- The build prompt instructs the agent to research idiomatic patterns via web search and documentation when no codebase precedent exists.
- Package managers need to reach registries.

**Known risk:** a compromised npm/pip/go package with a postinstall script could exfiltrate environment variables (including the auth token). This is a general supply chain risk, not specific to Ralph.

**Decision:** not addressed. Network isolation (`network_mode: none`) would break the core workflow. The mitigation is the same as any development environment: use lockfiles, audit dependencies, don't install packages from untrusted sources. The build prompt doesn't instruct the agent to install arbitrary packages -- it follows the architecture doc's technology choices.

### Environment variables

Only `CLAUDE_CODE_OAUTH_TOKEN` is passed for authentication. `ANTHROPIC_API_KEY` was removed from docker-compose.yml to reduce the credential surface.

Git identity variables (`GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL`) are passed because git refuses to commit without them inside the container. These are not secrets.

Ralph configuration variables (`RALPH_MODE`, `RALPH_MAX_ITERATIONS`, `RALPH_MODEL`) are operational, not sensitive.

## Verification philosophy

### Stack-level verification, not task-level

After each task, the build agent runs verification commands for ALL existing stacks, not just the one it touched. This is intentional:

- Cross-stack breakage is a real failure mode. A backend change can break frontend type imports. A migration can break API tests.
- Running all stacks catches these immediately rather than letting them accumulate across iterations.
- Verification time scales with the number of stacks, not the project size. Most projects have 2-4 stacks. This is acceptable.

### Tests validate behavior, not coverage

The build prompt requires tests that exercise real behavior through actual code paths. The rules are:

- No mocking of the system under test
- No trivial assertions
- Integration tests over unit tests for API and database operations
- Every test must fail if the feature it tests is removed

The loop script includes a post-commit check that warns if no test files or test functions were added in an iteration. This is currently a warning, not a hard gate.

**100% code coverage was considered and rejected.** A coverage percentage target creates perverse incentives for an LLM. Claude will write garbage tests to hit the number (testing constants, testing imports, asserting that `true === true`). The specific behavioral rules above are more effective at ensuring test quality than a coverage metric.

## Post-commit validation

The loop script runs two mechanical checks after each build iteration:

### Diff validation

Compares `git diff --name-only HEAD~1` against the task's declared `Files:` field. Files not in the declared list trigger a warning. Auto-allowlisted patterns: lock files, migration files, test files, `IMPLEMENTATION_PLAN.md`, journal entries.

This catches the "Claude decided to improve an unrelated file" problem without blocking legitimate side effects (lock file updates, generated migrations).

Currently warning-only. Can be promoted to a hard gate (revert on undeclared changes) once the allowlist is proven stable.

### Test existence check

Checks that the diff includes new test files or new test functions (matched by `it(`, `test(`, `describe(`, `func Test`, `#[test]`). Warns if neither is found.

This is a blunt check -- it doesn't verify test quality, only existence. The test quality rules in the build prompt handle the substance; this check handles the "forgot to write tests entirely" failure mode.

## Observability

### Iteration journals

Each build iteration writes a journal entry to `.ralph/logs/journal-iteration-N.md` with: task attempted, result, files changed, failure details (if any), and notes for future iterations.

This provides a human-readable audit trail without parsing raw stream-json logs. The journal is written by the build agent as its last action, so it includes the agent's own assessment of what happened.

### Token tracking

The loop extracts token usage from stream-json logs after each iteration and appends to `.ralph/logs/token-usage.csv`. The `ralph status` command reads this file and reports totals, per-iteration averages, and estimated cost.

Token costs use the Opus pricing model ($15/M input, $75/M output). This is a rough estimate -- actual billing depends on the model used and any pricing changes.

## Improvement priorities

Ordered by impact. Items at the top should be addressed first.

### P1: Docker wrapper script (security)

**What:** Add a shell wrapper around `docker` that blocks dangerous flags (`--privileged`, `-v /:/`, `system prune`, `-v /var/run/docker.sock`). Bind-mount the wrapper into the container and alias `docker` to it. Roughly 20 lines of bash.

**Why:** The Docker socket analysis in this document correctly identifies the privilege escalation risk but frames the threat as "hallucinated destructive commands." The more serious threat is prompt injection through dependencies. A malicious or compromised package can write files containing adversarial content. When the build agent reads those files in a subsequent iteration, injected instructions could direct it to run `docker run --privileged -v /:/host alpine sh -c "..."`. With `--dangerously-skip-permissions` and unrestricted socket access, that's full host root. The wrapper script breaks this escalation chain -- it doesn't prevent prompt injection, but it prevents prompt injection from becoming host compromise.

**Status:** Not started. Should not remain deferred -- this is a default-on mitigation for local dev, not just shared/CI environments.

### P2: Move dirty-tree check into the build loop (data loss prevention)

**What:** The `loop` script checks for uncommitted changes once at startup (line 179) and then runs `git checkout -- . && git clean -fd` at the top of each iteration (lines 262-263). If a human edits files in the project directory while Ralph is running mid-loop, those changes are silently destroyed. Move the dirty-tree check inside the loop, before the clean. If unexpected dirty files appear mid-run that were not produced by the previous iteration, stop and surface the issue rather than nuking them.

**Why:** The warning on lines 250-259 goes to stdout of a Docker container that might not be watched. Silent data loss in a tool that runs unattended is the worst kind of bug.

### P3: Hash-based plan preservation (correctness)

**What:** The completed-task preservation check counts `[x]` lines before and after planning. This catches task deletion but not task mutation. The planner could rewrite every completed task description (changing "Add GET /api/posts route" to "Add POST /api/posts route") and the count-based check would pass. Fix: hash the completed `[x]` lines before planning and compare the hash after. Reject the plan if any completed task's content changed.

**Why:** Completed tasks are the source of truth for what has been built. If the planner silently rewrites them, the plan diverges from reality. This is a mechanical check that can be added to the existing before/after comparison in the loop.

### P4: Capture diagnostics before bail-out revert (observability)

**What:** The build prompt's bail-out procedure (build.md lines 93-98) instructs the agent to revert all changes first, then write a note to the plan describing what went wrong. After the revert, the agent no longer has the diff, error output, or failing test results in its working tree. The diagnostic note will be hallucinated from memory. Fix: reorder the bail-out steps -- write the iteration journal (with failure details, last test output, diff summary) before reverting, not after.

**Why:** Unreliable failure diagnostics make debugging harder and waste future iterations that retry the same task without understanding what actually failed.

### P5: OAuth token exposure (security)

**What:** `CLAUDE_CODE_OAUTH_TOKEN` is passed as an environment variable and is readable by every process in the container -- npm scripts, test runners, build tools, anything. Combined with network access, any process can exfiltrate it. There is no clean fix without changes to Claude Code's auth model, but the risk should be documented and a partial mitigation explored (e.g., unsetting the env var after Claude Code reads it at startup, if that's supported).

**Why:** The token authenticates as the user to Claude's API with billing implications. Removing `ANTHROPIC_API_KEY` reduced the credential surface, but the OAuth token is arguably the more dangerous credential.

### P6: Token tracking robustness (correctness)

**What:** `track_tokens` greps for `"usage"` anywhere in the stream-json log and parses with sed. If Claude's output contains the string `"usage"` in a code block or discussion, this will parse garbage. Fix: use `jq` to parse the JSON properly, or match the full key structure rather than a bare substring.

**Why:** Wrong token data is worse than no token data -- it leads to incorrect cost estimates and hides context bloat trends.

## Infrastructure conventions

Ralph is opinionated about local development infrastructure. Every project uses the same stack:

- **Docker** for all application and service containers
- **devtun** (npmjs.com/package/devtun) for public HTTPS URLs via Cloudflare Tunnels + Traefik
- **nfi** for populating secret environment variables without exposing them to AI context

No ports are mapped to the host. All HTTP access goes through devtun (Cloudflare -> Traefik -> container on the Docker network). Database operations run via `docker compose exec`. Containers communicate using Docker compose service names (e.g., `db:5432`, `minio:9000`).

### How it works

Each application stack lives in its own directory (e.g., `app/`, `api/`) with its own Dockerfile, docker-compose.yml, and env files.

Infrastructure scaffolding is deterministic, not LLM-driven. The planner generates `.ralph/.stack-manifest.yml` (listing stacks, languages, and services) and `.ralph/.env-vars-needed` (listing required env vars). Before the first build, the host-side `ralph` script runs `.ralph/scaffold-infra`, which reads the manifest and stamps out all infrastructure files from templates. No LLM token cost, no risk of malformed YAML, no wasted iteration.

After scaffolding, the host script runs the activation sequence:
1. `devtun add {hostname}` -- registers the project for HTTPS tunneling
2. Replaces `__DEVTUN_URL__` placeholders in stack env files with the actual devtun URL (e.g., `https://project.devtun.dev`)
3. `docker compose up -d --wait` -- starts and waits for healthy application containers
4. `nfi` -- populates secret values in stack `.env` files

After activation, the host script creates `.ralph/.activated` and launches the build loop. The first iteration starts with containers running and ready.

### Why no port mapping

With devtun handling all HTTP access via Cloudflare Tunnels + Traefik:
- The app URL is a real HTTPS domain (e.g., `https://expenses.devtun.dev`), which is required for OAuth callbacks and mobile device access
- No host port conflicts between projects -- each project's containers live on their own Docker network
- `NEXTAUTH_URL` (and similar) must be the devtun domain, not `localhost`, for auth flows to work from any device

### Why opinionated

Attempting to support arbitrary infrastructure setups (Vagrant, nix, bare-metal, cloud dev environments) adds complexity that the build agent would need to handle. By standardizing on Docker + devtun, the scaffolding is deterministic and the build agent can focus on application code.

### Template files

Docker templates live in `.ralph/templates/docker/`. The `scaffold-infra` script uses these to generate per-stack infrastructure files:

- `node.Dockerfile`, `go.Dockerfile`, `python.Dockerfile` -- app container Dockerfiles
- `compose.partial.postgres.yml`, `compose.partial.minio.yml`, `compose.partial.redis.yml` -- service partials
- `init-test-db.sh` -- creates the test database alongside the main database

### Environment files

Each stack has two env files:
- **Gitignored** (e.g., `app/.env`): actual values, secrets populated by nfi
- **Committed** (e.g., `app/.env.example`): placeholder values, documents what vars are needed

The naming convention is stack-idiomatic: `.env`/`.env.example` for Node.js and Python, `appsettings.json`/`appsettings.json.example` for .NET, etc.

`.ralph/.env` holds `CLAUDE_CODE_OAUTH_TOKEN` for Ralph's own container. This file is gitignored and lives outside the project source tree.

### URL placeholder convention

Any env var whose value should be the project's public URL uses the literal placeholder `__DEVTUN_URL__` in the scaffolded `.env` file. The activation script replaces all occurrences with the actual devtun URL (e.g., `https://myproject.devtun.dev`). This is framework-agnostic -- it works for `NEXTAUTH_URL`, `APP_URL`, `ALLOWED_HOSTS`, or any other var. The `env-vars.yml` knowledge base uses this placeholder in its defaults.

### Environment variable knowledge base

`.ralph/knowledge/env-vars.yml` maps common npm packages to their required environment variables. The plan agent uses this to generate `.ralph/.env-vars-needed`, which the build agent uses to create each stack's env files.

### Test conventions

- `test.sh` at the project root is the single entry point for running all tests
- Tests run against a separate `{project}_test` database created by `init-test-db.sh`
- Tests create their own data -- no shared fixtures or reliance on seeds
- All logging is structured JSON to stdout so Ralph can read `docker logs` for diagnostics

## Deferred concerns

### Docker socket proxy
**What:** route Docker socket through a proxy that whitelists specific API calls.
**Why deferred:** adds operational complexity. The wrapper script (P1 above) addresses the most critical escalation paths. The proxy adds defense-in-depth by blocking unexpected API endpoints entirely, but is less urgent once the wrapper is in place. Revisit if Ralph runs in shared/CI environments. See "Docker socket access" section above for full analysis -- the proxy alone can't prevent `--privileged` on allowed endpoints.

### Structured task storage
**What:** migrate from single markdown file to SQLite, JSONL, or directory of task files.
**Why deferred:** the single file works at current scale. Mechanical checks (completed task preservation, HTML comment metadata, diff validation) compensate for the informal format. Migrate when the plan file exceeds what fits comfortably in Claude's context alongside specs and code.

### Hard-gate diff validation
**What:** promote undeclared-file-change warnings to a hard gate that reverts the commit.
**Why deferred:** the allowlist needs real-world tuning first. Running as warning-only lets us observe false positive rates before making it a blocker.

### Prompt injection via specs
**What:** a malicious or accidentally adversarial spec could instruct the planner/builder to take unintended actions.
**Why deferred:** Ralph is a single-user tool running locally. The specs are written by the same person who runs Ralph. In a multi-user or CI context, spec validation (or a restricted prompt sandbox) would be worth considering. Note: prompt injection through *dependencies* (not specs) is the more realistic attack vector -- see P1 above.

## Evaluating Ralph

How to assess whether Ralph is working well, and where to look when it isn't.

### What to check

- **Prompt effectiveness:** Are tasks being completed in one iteration, or do they frequently bail out and retry? Check `git log --oneline` for patterns of reverted-then-reattempted work. More than one bail-out per 5 tasks suggests the prompt or specs need clarification.
- **Security boundaries:** Review recent commits for unexpected file changes outside declared scope. The post-commit diff validation warnings in the loop output flag these. Check that no commits include credential files, `.env`, or modifications to `.ralph/` internals.
- **Failure handling:** When verification fails, does the agent revert cleanly or leave partial state? Check `git status` and `git stash list` after a failed run. The iteration journals document what went wrong and what was tried.
- **Context usage:** As the plan grows, watch for signs of context overflow -- the agent skipping tasks, misreading the plan, or producing shorter/lower-quality output. The slim plan feature (`.ralph/.build-plan.md`) mitigates this by stripping completed task metadata.

### Where to find evidence

| Source | What it tells you |
|--------|-------------------|
| `.ralph/logs/journal-iteration-N.md` | Per-iteration narrative: what was attempted, result, files changed, failure details |
| `.ralph/logs/token-usage.csv` | Token consumption per iteration -- rising input tokens suggest context bloat |
| `git log --oneline` | Commit history shows task completion rate and revert patterns |
| `git diff HEAD~N` | Actual code changes vs declared scope |
| `.ralph/logs/*-build-*.log` | Raw Claude output for debugging prompt issues |

### Health indicators

- **Healthy:** 1 iteration per task, rising `[x]` count, stable token usage, clean `git status` between runs
- **Degrading:** multiple iterations per task, increasing token usage over time, frequent bail-outs, undeclared file change warnings
- **Broken:** agent modifying `.ralph/` internals, ignoring the plan, producing empty commits, token usage hitting model limits
