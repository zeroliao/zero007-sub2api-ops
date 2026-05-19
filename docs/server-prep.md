# Server Preparation

Use these steps once per server. Codex can run them after you provide SSH access.

## Recommended Account

Create a dedicated Linux user:

```bash
sudo adduser sub2api-ops
sudo usermod -aG docker sub2api-ops
```

The user needs permission to run Docker Compose in the deployment directory.

## Deployment Directory

Recommended path:

```text
/opt/sub2api-deploy
```

The server should contain:

```text
/opt/sub2api-deploy/.env
/opt/sub2api-deploy/docker-compose.yml
/opt/sub2api-deploy/data/
/opt/sub2api-deploy/postgres_data/
/opt/sub2api-deploy/redis_data/
```

## Required Secrets

Keep these only on the server, not in Git:

```text
POSTGRES_PASSWORD=<secure random string>
REDIS_PASSWORD=<secure random string>
JWT_SECRET=<secure random string>
TOTP_ENCRYPTION_KEY=<secure random string>
ADMIN_EMAIL=<admin email>
ADMIN_PASSWORD=<optional, only needed for first setup>
SERVER_PORT=8080
TZ=Asia/Shanghai
```

The values above are examples. Existing production values in `/opt/sub2api-deploy/.env` are the source of truth; generate or update only missing secrets.

Generate secrets on Linux with:

```bash
openssl rand -hex 32
```

## Verification

The automation checks:

```text
docker compose config
required .env variables
PostgreSQL dump backup if database is running
container startup
https://api.zero007.chat/health
recent sub2api logs for fatal patterns
digest-pinned compose images
destructive unapplied SQL migrations
```
