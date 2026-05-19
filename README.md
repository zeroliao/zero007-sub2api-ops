# sub2api Ops Automation

This repository is an operations workspace for managing a remote Sub2API deployment from Codex.

AI/Codex contributors should read [`AGENTS.md`](AGENTS.md) first for repository context, Git-backed deployment rules, and production safety boundaries.

The workflow is intentionally conservative:

1. Require deployment changes to be committed and pushed to GitHub.
2. Fetch the ops repository on the server and check out the same commit.
3. Validate Docker Compose and required environment variables on the server.
4. Create a deployment lock so two local machines cannot deploy at the same time.
5. Back up current config and database before changing anything.
6. Deploy with Docker Compose.
7. Run health checks and inspect recent logs.
8. Roll back automatically if verification fails.

## Quick Start

Copy the local configuration template:

```powershell
Copy-Item .env.ops.example .env.ops
```

Edit `.env.ops` with the server connection details:

```text
SUB2API_SSH_HOST=api.zero007.chat
SUB2API_SSH_USER=your_ssh_user
SUB2API_SSH_PORT=22
SUB2API_REMOTE_DIR=/opt/sub2api-deploy
SUB2API_HEALTH_URL=https://api.zero007.chat/health
SUB2API_OPS_REPO=git@github.com:zeroliao/zero007-sub2api-ops.git
SUB2API_OPS_BRANCH=main
SUB2API_REMOTE_OPS_DIR=/home/your_ssh_user/zero007-sub2api-ops
SUB2API_REMOTE_GIT_SSH_KEY=/home/your_ssh_user/.ssh/zero007_sub2api_ops_deploy
```

Then ask Codex to run one of these:

```powershell
.\scripts\sub2api-ops.cmd doctor
.\scripts\sub2api-ops.cmd inspect
.\scripts\sub2api-ops.cmd diff-server
.\scripts\sub2api-ops.cmd sync-from-server
.\scripts\sub2api-ops.cmd audit-allowlist
.\scripts\sub2api-ops.cmd validate-allowlist
.\scripts\sub2api-ops.cmd validate-candidate
.\scripts\sub2api-ops.cmd deploy
.\scripts\sub2api-ops.cmd bluegreen-deploy
.\scripts\sub2api-ops.cmd active-slot
.\scripts\sub2api-ops.cmd switch-slot
.\scripts\sub2api-ops.cmd status
.\scripts\sub2api-ops.cmd logs
.\scripts\sub2api-ops.cmd rollback
```

## Server Files

The remote server should keep secrets in:

```text
/opt/sub2api-deploy/.env
```

The automation will not replace `.env` unless you explicitly change the script to do so.

## Keeping GitHub and Server in Sync

Deployment actions (`validate-candidate`, `deploy`, and `bluegreen-deploy`) are Git-backed by default. They fail unless:

- the local ops worktree is clean,
- local `HEAD` matches `SUB2API_OPS_REMOTE/SUB2API_OPS_BRANCH`,
- and the server can fetch `SUB2API_OPS_REPO` with `SUB2API_REMOTE_GIT_SSH_KEY`.

Normal release sequence:

```powershell
git status
git add .
git commit -m "feat: update deployment"
git push
.\scripts\sub2api-ops.cmd validate-candidate
.\scripts\sub2api-ops.cmd bluegreen-deploy
```

For an emergency local upload only, set `SUB2API_ALLOW_DIRTY_DEPLOY=true` in `.env.ops`. Leave it `false` for normal production deployments.

Before deployment, compare the GitHub-tracked compose template with the live server compose file:

```powershell
.\scripts\sub2api-ops.cmd diff-server
```

For first-time adoption, make the server's current compose file the GitHub baseline:

```powershell
.\scripts\sub2api-ops.cmd sync-from-server
```

After syncing, commit and push the changed `deploy/docker-compose.yml`.

## URL Allowlist Audit

Before enabling `SECURITY_URL_ALLOWLIST_ENABLED=true`, audit the hosts currently used by accounts, proxies, settings, and default pricing/upstream integrations:

```powershell
.\scripts\sub2api-ops.cmd audit-allowlist
```

Then run the read-only preflight against the candidate `SECURITY_URL_ALLOWLIST_*` values from the server `.env`:

```powershell
.\scripts\sub2api-ops.cmd validate-allowlist
```

Do not enable the allowlist until both commands pass and every required upstream host has been reviewed.

Required remote `.env` values:

```text
POSTGRES_PASSWORD=...
REDIS_PASSWORD=...
JWT_SECRET=...
TOTP_ENCRYPTION_KEY=...
ADMIN_EMAIL=...
SERVER_PORT=8080
TZ=Asia/Shanghai
```

These are placeholders only. Keep the real values in the server `.env`, and do not overwrite existing production secrets with values from this README or `.env.ops.example`.

## Deployment Gates

`doctor`, `validate`, `validate-candidate`, and `deploy` fail closed on risky settings:

- `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `JWT_SECRET`, and `TOTP_ENCRYPTION_KEY` must be non-empty.
- First-time deployments with an empty `postgres_data` directory must set `ADMIN_PASSWORD`.
- `SERVER_PORT` must be numeric.
- `BIND_HOST=0.0.0.0` requires `SUB2API_ALLOW_PUBLIC_BIND=true`; otherwise the compose default binds to `127.0.0.1`.
- The `sub2api`, `postgres`, and `redis` images must be pinned with `@sha256:` digests.

When updating pinned images, resolve the current digest with Docker's registry tools before editing `deploy/docker-compose.yml`:

```powershell
docker buildx imagetools inspect postgres:18-alpine
docker buildx imagetools inspect redis:8-alpine
```

For application releases, keep using an immutable Sub2API image digest. Avoid mutable tags such as `latest`, `main`, or `dev`.

## Destructive Migration Confirmation

The deployment script scans unapplied SQL migrations for potentially irreversible statements such as `DROP TABLE`, `DROP COLUMN`, destructive `DELETE`, and lossy type changes. By default it scans:

```text
/opt/sub2api-deploy/.ops/migrations
```

Set `SUB2API_MIGRATIONS_DIR` in the server `.env` if the migration SQL files live elsewhere. If a risky unapplied migration is intentional, deployment requires both:

```text
SUB2API_DESTRUCTIVE_MIGRATION_CONFIRMED=true
SUB2API_DESTRUCTIVE_MIGRATION_NOTE='affected files, impact, backup location, restore plan'
```

## Safety Notes

Use a dedicated Linux user such as `sub2api-ops`; avoid direct `root` automation where possible.

The script creates backups under:

```text
/opt/sub2api-deploy/backups/
```

Only the latest three backup directories are kept by default. Override with `SUB2API_BACKUP_RETENTION=<count>` in the server `.env` if needed.

Database backups use `pg_dump` from the running PostgreSQL container when available. If PostgreSQL is not running yet, the script still backs up configuration files and local directories.

Rollback restores `.env`, `docker-compose.yml`, optional `config.yaml`, and restarts containers from the latest config backup. It does not automatically restore the database dump. If a database restore is needed, restore `postgres.sql` from the selected backup manually after stopping the application.

Before every source-code deployment, check whether the new image contains database migrations. If migrations include potentially irreversible operations such as `DROP TABLE`, `DROP COLUMN`, destructive `DELETE`, lossy type changes, or data backfills that cannot be recomputed, pause and warn the operator before deployment. The deployment note must include the affected migration files, expected impact, backup location, and a concrete rollback plan. Do not rely on container rollback alone for irreversible database changes.

## Blue-Green Deployment

`bluegreen-deploy` runs a single-server blue-green rollout:

1. Keep PostgreSQL and Redis shared.
2. Start the inactive application slot (`sub2api-blue` or `sub2api-green`).
3. Verify the inactive slot health and recent logs.
4. Reload Caddy to switch traffic to the healthy slot.
5. Stop the previous slot after cutover to avoid duplicate background jobs.

Caddy is the only service bound to `${BIND_HOST}:${SERVER_PORT}`. The current slot is tracked in:

```text
/opt/sub2api-deploy/.ops/active-slot
```

Use `switch-slot` for a manual traffic switch and `active-slot` to print the current slot.
