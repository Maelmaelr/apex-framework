# {Project Name} Project Context

<!-- SECTION: system-overview -->
## System Overview

{User-provided description or "TODO: Add project description."}
{Detected tech stack summary: frameworks, languages, key dependencies.}
{If monorepo: list workspace packages and their roles.}

<!-- SECTION: what-do-you-need -->
## What Do You Need?

### Add or Modify Code

- **New feature** -> Check relevant docs in `docs/` and existing patterns
- **New API endpoint** -> TODO: document controller/route patterns
- **Shared type change** -> TODO: document cross-package update flow

### Understand the System

- **Architecture** -> TODO: `docs/architecture.md`
- **Auth & security** -> TODO: `docs/auth-flow.md`

### Operate & Debug

- **Troubleshooting** -> TODO: `docs/operations/`

### Understanding Features

- **All features** -> [features/index.md](./features/index.md)

<!-- SECTION: config-surface -->
## Config Surface

Parallel files that MUST move together when an env var or config key is added, removed, or renamed. List every place the same key appears so a slice that changes one updates them all in one pass.

- Runtime env: TODO (e.g., `apps/api/src/config.ts`, `internal/config/config.go`)
- Env templates: TODO (e.g., `.env.example`, `.env.sample`)
- Local compose: TODO (e.g., `docker-compose.yml`)
- Prod / staging compose or deploy: TODO (e.g., `docker-compose.prod.yml`, `deploy/render.yaml`, `k8s/values.prod.yaml`, `terraform/vars.tf`)
- CI secrets surface: TODO (e.g., `.github/workflows/*.yml` env blocks, repository secret names)

Curate this list as the project grows. The apex executor re-reads this section whenever a slice adds / removes / renames an env var (see `~/.claude/agents/executor.md` "Architecture context").

<!-- SECTION: modification-checklist -->
## Modification Checklist

When modifying a feature:

- [ ] Read the relevant feature document
- [ ] Check architecture docs for patterns
- [ ] Update all affected layers
- [ ] Add/update tests
- [ ] If the slice touches an env var or config key, update every file listed in "Config Surface" above

<!-- SECTION: security -->
## Security

TODO: Document auth flow, threat model, security-sensitive files.

<!-- SECTION: operations -->
## Operations

TODO: Add runbooks and operational docs.

<!-- SECTION: ci-cd -->
## CI/CD

TODO: Document CI/CD pipeline and deployment process.
