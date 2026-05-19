# Codex Guide for `zero007-sub2api-ops`

`zero007-sub2api-ops` is the production operations repository for Sub2API. It controls deployment scripts, the production compose baseline, Caddy blue-green routing, backup retention, rollback behavior, and deployment gates.

Application source code lives in `../sub2api`.

## Read First

- `README.md`: operator commands and current deployment model.
- `docs/source-release-flow.md`: source-code release sequence.
- `docs/server-prep.md`: server directory and secret expectations.
- `../sub2api/AGENTS.md`: only when a deployment depends on application source changes.

## Production Model

- Remote deployment directory: `/opt/sub2api-deploy`.
- Server secrets live in `/opt/sub2api-deploy/.env`.
- Do not edit or print real `.env.ops` or server `.env` secrets.
- Compose baseline: `deploy/docker-compose.yml`.
- Remote deployment script: `remote/sub2api-remote-ops.sh`.
- Local entrypoint: `scripts/sub2api-ops.cmd` / `scripts/sub2api-ops.ps1`.
- Caddy routes traffic to the active blue/green app slot.
- PostgreSQL and Redis are shared across slots.
- Backups are under `/opt/sub2api-deploy/backups/` and default retention is 3 backup directories.

## Git-Backed Deployments

Deploy actions are Git-backed by default:

- `validate-candidate`
- `deploy`
- `bluegreen-deploy`

These actions fail unless:

- local worktree is clean,
- local `HEAD` matches `SUB2API_OPS_REMOTE/SUB2API_OPS_BRANCH`,
- server can fetch `SUB2API_OPS_REPO` with `SUB2API_REMOTE_GIT_SSH_KEY`,
- server checks out the same commit before using compose/scripts.

Emergency local upload mode exists but should stay off:

```text
SUB2API_ALLOW_DIRTY_DEPLOY=true
```

Use it only when explicitly approved.

## Normal Deployment Commands

```powershell
git status
git add .
git commit -m "feat: update ops"
git push
.\scripts\sub2api-ops.cmd diff-server
.\scripts\sub2api-ops.cmd validate-candidate
.\scripts\sub2api-ops.cmd backup
.\scripts\sub2api-ops.cmd start-bluegreen-deploy
.\scripts\sub2api-ops.cmd run-status
.\scripts\sub2api-ops.cmd run-logs
.\scripts\sub2api-ops.cmd status
```

Useful read-only/status commands:

```powershell
.\scripts\sub2api-ops.cmd doctor
.\scripts\sub2api-ops.cmd active-slot
.\scripts\sub2api-ops.cmd logs
.\scripts\sub2api-ops.cmd audit-allowlist
.\scripts\sub2api-ops.cmd validate-allowlist
```

Prefer `start-bluegreen-deploy` for production changes when the Codex/API control channel may be routed through the same service. It writes durable run logs under `/opt/sub2api-deploy/.ops/deploy-runs/`; use `run-status` and `run-logs` after reconnecting.

## Deployment Consent Rule

Do not run production deployment commands unless the user explicitly asked for deployment in the same request or confirmed it after being asked.

- Direct deploy is allowed when the user says things like "改完并部署", "直接部署", "自动部署", "部署到服务器", or equivalent.
- If the user only asks to implement, fix, optimize, commit, or prepare a change, stop after local verification and ask before deployment.
- `validate-candidate`, `doctor`, `status`, `active-slot`, `run-status`, `run-logs`, and `logs` are allowed as checks.
- `deploy`, `bluegreen-deploy`, `start-deploy`, and `start-bluegreen-deploy` require explicit deploy intent or confirmation.

## Deployment Gates

The remote script fails closed for risky settings:

- Missing `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `JWT_SECRET`, or `TOTP_ENCRYPTION_KEY`.
- Placeholder Redis password.
- Non-numeric `SERVER_PORT`.
- `BIND_HOST=0.0.0.0` unless `SUB2API_ALLOW_PUBLIC_BIND=true`.
- First deployment with empty `postgres_data` and no `ADMIN_PASSWORD`.
- Service images not pinned with `@sha256:`.
- Potential destructive migrations unless confirmation variables are set with a note.

## Rollback and Backups

- Backup runs before deploy and stores config plus PostgreSQL dump when PostgreSQL is running.
- Background deployment runs store status, PID, exit code, timestamps, and logs under `/opt/sub2api-deploy/.ops/deploy-runs/`.
- Rollback restores `.env`, `docker-compose.yml`, optional `config.yaml`, Caddy config, active slot file, and container startup state.
- Rollback does not automatically restore the database dump.
- Database restore from `postgres.sql` is manual and must be planned before destructive migrations.

## Editing Rules

- Do not commit `.env.ops`.
- Do not print secrets from local `.env.ops` or remote `/opt/sub2api-deploy/.env`.
- Keep image references immutable and digest-pinned.
- Resolve new image digests with registry tooling, not guesswork.
- Use `bluegreen-deploy` for application releases unless explicitly choosing traditional `deploy`.
