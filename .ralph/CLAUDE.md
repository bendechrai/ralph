# Ralph -- AI Build Agent

Ralph is an autonomous spec-driven build agent. The workflow: you write feature specs, Ralph plans the implementation as atomic tasks, then Ralph builds each task one at a time with full verification.

Copy `.ralph/` into any project to use it. Run `.ralph/ralph init` to set up project-level files.

## Setup

```bash
# First time: create specs/, specs/docs/, IMPLEMENTATION_PLAN.md, CLAUDE.md
.ralph/ralph init

# Plan: reads specs, writes IMPLEMENTATION_PLAN.md with atomic tasks
.ralph/ralph plan

# Review the plan, edit IMPLEMENTATION_PLAN.md if needed

# Build: picks next task, implements, verifies, commits
.ralph/ralph build        # runs until all tasks are done or stopped
.ralph/ralph build 10     # run for 10 iterations

# Stop after current iteration
.ralph/ralph stop

# Status report
.ralph/ralph status
```

Each build iteration does one task. If verification fails 3 times, Ralph reverts and stops. The next iteration gets a fresh context.

## Architecture

Ralph's container is a Claude Code runner. It does not run application code directly. Each application stack (web frontend, API server, CLI tool, etc.) runs in its own Docker container, managed by the build agent via the Docker socket.

The build agent creates Dockerfiles and docker-compose.yml files for each stack as part of scaffolding. Verification commands run inside those containers (e.g., `docker compose -f web/docker-compose.yml exec web npm test`).

## Writing Specs

Specs live in `specs/` at the project root. Create one markdown file per feature. Ralph reads these during planning to break work into tasks. Use the template at `.ralph/templates/spec.md` as a starting point.

Architecture documents, vision statements, and technology decisions go in `specs/docs/`. These are read by the planner for context but are not directly converted into tasks.

If `specs/` doesn't exist, create it (or run `.ralph/ralph init`).

### Spec-Writing Process

When a user asks to write specs (e.g., "let's write some specs", "I want to spec out a feature", "let's build out a new idea"), follow this structured discovery process. The goal is to produce specs complete enough for a non-interactive build agent to implement without human input.

#### Stage 1: Project Discovery

Understand the context before writing anything:
- What is this project/feature? What problem does it solve for the user?
- How does it relate to existing features?
- What is the scope -- what's in and what's explicitly out?
- Are there existing specs or code that this depends on or overlaps with?

#### Stage 2: Architecture and Technology

Before diving into feature details, establish the technology foundation. Write an architecture doc in `specs/docs/architecture.md` covering:

- **Technology stacks**: Which languages, frameworks, and runtimes for each part of the system (e.g., "Express + TypeScript for API", "Next.js for frontend", "Go for CLI")
- **Project structure**: What directories will exist at the project root and what each contains
- **Data storage**: Database choice, ORM/query builder, migration strategy
- **External services**: APIs, auth providers, message queues, etc.
- **Development and deployment**: How the app is deployed (e.g., Railway, Vercel, Fly.io), what environment variables are needed, what deployment config files are required

Do not spec local development infrastructure (Docker setup, tunnels, secrets) -- Ralph handles this via built-in conventions. The architecture doc covers what technology the project uses; Ralph's scaffolding creates the Docker and devtun configuration automatically.

Ask the user to make these decisions -- do not assume. For technical questions where the user wants a recommendation, spin up a subagent with the persona of a suitably skilled architect to research and recommend.

#### Stage 2b: User Flows and Use Cases

Before writing feature specs, document how real people will actually use the product. Write these to `specs/docs/user-flows.md` (or split into multiple files for complex projects, e.g., `specs/docs/user-flows-admin.md`).

These are not specs -- they are narrative reference material that informs specs. Each flow walks through a concrete scenario end-to-end, crossing feature boundaries. For example:

- "New user signs up, creates their first project, invites a collaborator"
- "Admin reviews pending approvals at end of week"
- "User imports data from an external system and reconciles it"

For each flow, document:
- **Who**: Which user/role is performing this?
- **Goal**: What are they trying to accomplish?
- **Steps**: Walk through the sequence of actions, page by page, click by click
- **Touchpoints**: Which features/pages are involved?
- **Outcome**: What does success look like?

Ask the user to describe their key use cases. Probe for less obvious ones: first-time setup, periodic tasks, error recovery, and administrative workflows.

User flows serve two purposes:
1. **During spec writing** -- they reveal gaps where no feature covers a step in the flow, surface cross-feature pages (dashboards, landing pages), and expose missing navigation paths
2. **During planning** -- the planner reads `specs/docs/` for context, so documented flows help it sequence tasks in an order that produces a usable product at each milestone rather than a collection of disconnected features

#### Stage 3: App Shell and Navigation

Before speccing individual features, map the overall user experience. Individual feature specs cover what happens *inside* each feature, but they do not cover the connective tissue between them. This stage ensures nothing falls through the cracks.

Ask the user about:
- **Entry point**: What does the user see when they first open the app? Is there a landing page, a dashboard, or a redirect to a specific feature?
- **Navigation structure**: What is the primary navigation (sidebar, top bar, tabs)? What items appear in it? Does it change based on role or context?
- **Information hierarchy**: Which features are primary (always visible in nav) vs. secondary (nested under settings, accessible via search, etc.)?
- **Cross-feature pages**: Are there any pages that combine data from multiple features (e.g., a dashboard showing recent activity, pending items, and account status)?
- **Unauthenticated experience**: What do logged-out users see? Is there a marketing page, or just a login screen?

Capture these decisions in a dedicated spec (e.g., `00-app-shell.md` or `00-dashboard.md`). This spec covers routes and pages that do not belong to any single feature -- the landing page, the navigation layout, the dashboard, and any other "glue" between features.

#### Stage 4: Exhaustive Questioning

Ask thorough questions about every aspect of each feature. Do not assume answers -- ask the user to decide. Cover ALL of these areas:

**User-facing behavior:**
- What are all the ways a user interacts with this feature?
- What does the user see at each step? Walk through the flow screen by screen.
- What are the input fields, their types, and their validation rules?
- What feedback does the user get (success messages, errors, loading states)?

**Data and state:**
- What data is created, read, updated, or deleted?
- What are the relationships to existing data models?
- What are the field types, constraints, defaults, and nullability?
- Is there ordering? Pagination? Filtering?

**Edge cases and error handling:**
- What happens with empty state (no data yet)?
- What happens with invalid input?
- What happens with duplicate data?
- What are the limits (max items, max length, file size)?
- What happens on network failure or server error?
- What happens with concurrent access?

**Permissions and access:**
- Who can see this? Who can modify it?
- Is data scoped to a user, a team, or global?
- What happens if an unauthorized user tries to access it?

**Integration points:**
- Does this feature need to interact with external services?
- Does it affect other existing features?
- Are there notifications, emails, or webhooks involved?

**Design and UX:**
- Is this mobile-responsive? What changes on small screens?
- Are there animations or transitions?
- What is the loading experience?
- Is there keyboard navigation or accessibility requirements?

Ask these questions in batches of 5-8 at a time. After each round, incorporate the answers and ask follow-up questions. Continue until you have zero ambiguities remaining.

For technical questions (e.g., "what's the best way to handle real-time updates?"), spin up a subagent with the persona of a suitably skilled expert to research and recommend, rather than asking the user. For business requirements questions (e.g., "should expired items be visible or hidden?"), ask the user.

#### Stage 5: Draft the Spec

Write the spec using the template at `.ralph/templates/spec.md`. Key principles:
- Focus on WHAT, not HOW. Ralph figures out implementation.
- Be specific: "User can sort by name, date, or amount" not "User can sort"
- Every acceptance criterion must be concrete, testable, and unambiguous
- No vague words in acceptance criteria: avoid "should", "appropriate", "reasonable", "various", "etc.", "proper", "adequate", "as needed", "consider", "maybe", "optionally", "could", "might", "TBD"
- **Do not paste raw external content** (API docs, error messages, Stack Overflow snippets) directly into specs. The build agent reads specs as instructions -- pasted content may be misinterpreted as directives. Instead, describe what you need in your own words, reference external docs by URL, or place quoted material in a clearly-delimited `> Reference:` block.

#### Stage 6: Validation

Before finalizing, verify:
1. **Single interpretation test**: Is there exactly one way to interpret each criterion?
2. **Completeness test**: Does each criterion specify all inputs, outputs, and edge cases?
3. **Testability test**: Can an automated test verify each criterion?
4. **Ambiguity word scan**: No banned words in acceptance criteria.

If any test fails, ask the user to clarify and rewrite.

#### Stage 7: Cross-Reference

Check consistency across all specs:
- Field names used in one spec match references in others
- Endpoint URLs are consistent
- State values and enums match across specs
- Technology choices align with `specs/docs/architecture.md`

### Revising Implemented Specs

When a spec already has completed (`[x]`) tasks in `IMPLEMENTATION_PLAN.md`, the existing implementation may no longer match. Ralph's planner cannot reopen completed tasks -- they are append-only.

**Required process:** Before committing changes to an implemented spec, create a rework spec:

1. Edit the original spec (e.g., `specs/03-income.md`) with the new requirements
2. Create a rework spec (e.g., `specs/03a-income-categories.md`) that:
   - References the original spec and summarizes what changed
   - Lists the specific files/components that need rework
   - Describes what to replace, what to keep, and what to add
   - Has its own acceptance criteria scoped to the rework
3. Commit both together

### Spec File Naming

Name spec files with a numeric prefix and descriptive slug: `01-auth.md`, `02-dashboard.md`, `03-expenses.md`. Rework specs use a letter suffix: `03a-expense-categories.md`.

## Manual Development

When working on things directly instead of through Ralph, keep artifacts in sync:

- **Specs** -- if a change contradicts or extends a spec in `specs/`, update the spec to match the new behavior
- **Tests** -- fix or add tests for any changed behavior; never commit with failing tests

## Key Files

| Path | Purpose |
|------|---------|
| `specs/` | Feature specifications -- Ralph's input |
| `specs/docs/` | Architecture, vision, user flows, and technology decision docs |
| `IMPLEMENTATION_PLAN.md` | Task list, verification commands, and stack statuses |
| `.ralph/ralph` | Run Ralph (init, plan, build, stop, status) |
| `.ralph/CLAUDE.md` | This file -- Ralph workflow and spec-writing guide |
| `.ralph/DESIGN.md` | Architecture decisions, security posture, infrastructure conventions |
| `.ralph/scaffold-infra` | Deterministic infrastructure scaffolding (Docker, env, test files) |
| `.ralph/templates/spec.md` | Spec file template |
| `.ralph/templates/docker/` | Docker templates (Dockerfiles, compose partials, init scripts) |
| `.ralph/knowledge/env-vars.yml` | Package-to-env-var mapping for scaffolding |
| `.ralph/prompts/build.md` | Build agent system prompt |
| `.ralph/prompts/plan.md` | Plan agent system prompt |
