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
/srv/sub2api-deploy
```

The server should contain:

```text
/srv/sub2api-deploy/.env
/srv/sub2api-deploy/docker-compose.yml
/srv/sub2api-deploy/data/
/srv/sub2api-deploy/postgres_data/
/srv/sub2api-deploy/redis_data/
```

## Required Secrets

Keep these only on the server, not in Git:

```text
POSTGRES_PASSWORD=<secure random string>
JWT_SECRET=<secure random string>
TOTP_ENCRYPTION_KEY=<secure random string>
ADMIN_EMAIL=<admin email>
ADMIN_PASSWORD=<optional, only needed for first setup>
SERVER_PORT=8080
TZ=Asia/Shanghai
```

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
```

