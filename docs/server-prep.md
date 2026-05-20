# 服务器准备

以下步骤通常每台服务器只需执行一次。你提供 SSH 访问后，Codex 可以协助执行。

## 推荐账号

创建专用 Linux 用户：

```bash
sudo adduser sub2api-ops
sudo usermod -aG docker sub2api-ops
```

该用户需要有权限在部署目录中运行 Docker Compose。

## 部署目录

推荐路径：

```text
/opt/sub2api-deploy
```

服务器应包含：

```text
/opt/sub2api-deploy/.env
/opt/sub2api-deploy/docker-compose.yml
/opt/sub2api-deploy/data/
/opt/sub2api-deploy/postgres_data/
/opt/sub2api-deploy/redis_data/
```

## 必需密钥

这些值只保存在服务器上，不要提交到 Git：

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

上面的值只是示例。`/opt/sub2api-deploy/.env` 中现有生产值才是真实来源；只生成或更新缺失的密钥。

在 Linux 上可以用以下命令生成密钥：

```bash
openssl rand -hex 32
```

## 验证内容

自动化会检查：

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
