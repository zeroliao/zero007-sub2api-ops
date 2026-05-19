# sub2api Ops Automation

This repository is an operations workspace for managing a remote Sub2API deployment from Codex.

The workflow is intentionally conservative:

1. Upload the approved compose/config templates.
2. Validate Docker Compose and required environment variables on the server.
3. Create a deployment lock so two local machines cannot deploy at the same time.
4. Back up current config and database before changing anything.
5. Deploy with Docker Compose.
6. Run health checks and inspect recent logs.
7. Roll back automatically if verification fails.

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
SUB2API_REMOTE_DIR=/srv/sub2api-deploy
SUB2API_HEALTH_URL=https://api.zero007.chat/health
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
.\scripts\sub2api-ops.cmd status
.\scripts\sub2api-ops.cmd logs
.\scripts\sub2api-ops.cmd rollback
```

## Server Files

The remote server should keep secrets in:

```text
/srv/sub2api-deploy/.env
```

The automation will not replace `.env` unless you explicitly change the script to do so.

## Keeping GitHub and Server in Sync

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
JWT_SECRET=...
TOTP_ENCRYPTION_KEY=...
ADMIN_EMAIL=...
SERVER_PORT=8080
TZ=Asia/Shanghai
```

## Safety Notes

Use a dedicated Linux user such as `sub2api-ops`; avoid direct `root` automation where possible.

The script creates backups under:

```text
/srv/sub2api-deploy/backups/
```

Database backups use `pg_dump` from the running PostgreSQL container when available. If PostgreSQL is not running yet, the script still backs up configuration files and local directories.

Before every source-code deployment, check whether the new image contains database migrations. If migrations include potentially irreversible operations such as `DROP TABLE`, `DROP COLUMN`, destructive `DELETE`, lossy type changes, or data backfills that cannot be recomputed, pause and warn the operator before deployment. The deployment note must include the affected migration files, expected impact, backup location, and a concrete rollback plan. Do not rely on container rollback alone for irreversible database changes.

## TODO

- Add single-server blue-green deployment with Caddy traffic switching, so application releases can start the new container, pass health checks, then switch traffic with near-zero user impact.
