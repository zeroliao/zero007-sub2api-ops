# sub2api 运维自动化

这个仓库是用于从 Codex 管理远程 Sub2API 部署的运维工作区。

AI/Codex 贡献者应先阅读 [`AGENTS.md`](AGENTS.md)，了解仓库上下文、Git 驱动部署规则和生产安全边界。

当前工作流刻意保持保守：

1. 部署变更必须先提交并推送到 GitHub。
2. 服务器拉取 ops 仓库，并检出同一个 commit。
3. 在服务器上验证 Docker Compose 和必需环境变量。
4. 创建部署锁，防止两台本地机器同时部署。
5. 在修改任何内容前备份当前配置和数据库。
6. 使用 Docker Compose 部署。
7. 执行健康检查并查看最近日志。
8. 如果验证失败，自动回滚。

## 快速开始

复制本地配置模板：

```powershell
Copy-Item .env.ops.example .env.ops
```

编辑 `.env.ops`，填写服务器连接信息：

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

然后让 Codex 运行以下命令之一：

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
.\scripts\sub2api-ops.cmd start-bluegreen-deploy
.\scripts\sub2api-ops.cmd run-status
.\scripts\sub2api-ops.cmd run-logs
.\scripts\sub2api-ops.cmd active-slot
.\scripts\sub2api-ops.cmd switch-slot
.\scripts\sub2api-ops.cmd status
.\scripts\sub2api-ops.cmd logs
.\scripts\sub2api-ops.cmd rollback
```

## 服务器文件

远程服务器应将密钥保存在：

```text
/opt/sub2api-deploy/.env
```

自动化脚本不会替换 `.env`，除非你明确修改脚本让它这么做。

## 保持 GitHub 与服务器同步

部署动作（`validate-candidate`、`deploy` 和 `bluegreen-deploy`）默认由 Git 驱动。以下条件不满足时会失败：

- 本地 ops 工作区是干净的；
- 本地 `HEAD` 与 `SUB2API_OPS_REMOTE/SUB2API_OPS_BRANCH` 一致；
- 服务器能使用 `SUB2API_REMOTE_GIT_SSH_KEY` 拉取 `SUB2API_OPS_REPO`。

常规发布顺序：

```powershell
git status
git add .
git commit -m "feat: update deployment"
git push
.\scripts\sub2api-ops.cmd validate-candidate
.\scripts\sub2api-ops.cmd start-bluegreen-deploy
.\scripts\sub2api-ops.cmd run-status
.\scripts\sub2api-ops.cmd run-logs
```

只有紧急本地上传时，才在 `.env.ops` 中设置 `SUB2API_ALLOW_DIRTY_DEPLOY=true`。正常生产部署应保持为 `false`。

生产部署命令需要明确的用户意图。如果请求只是实现、修复、优化、commit 或准备变更，运行 `deploy`、`bluegreen-deploy`、`start-deploy` 或 `start-bluegreen-deploy` 前必须先确认。`validate-candidate`、`status`、`run-status` 和 `run-logs` 等只读检查可以在没有部署确认时运行。

部署前，比较 GitHub 跟踪的 compose 模板和服务器上的 live compose 文件：

```powershell
.\scripts\sub2api-ops.cmd diff-server
```

首次接入时，可以将服务器当前 compose 文件同步为 GitHub 基线：

```powershell
.\scripts\sub2api-ops.cmd sync-from-server
```

同步后，提交并推送变更后的 `deploy/docker-compose.yml`。

## URL Allowlist 审计

启用 `SECURITY_URL_ALLOWLIST_ENABLED=true` 前，先审计账号、代理、设置项以及默认 pricing/upstream 集成当前使用的 host：

```powershell
.\scripts\sub2api-ops.cmd audit-allowlist
```

然后用服务器 `.env` 中候选的 `SECURITY_URL_ALLOWLIST_*` 值执行只读预检：

```powershell
.\scripts\sub2api-ops.cmd validate-allowlist
```

只有两个命令都通过，并且所有必需 upstream host 都已审查后，才能启用 allowlist。

远程 `.env` 必需值：

```text
POSTGRES_PASSWORD=...
REDIS_PASSWORD=...
JWT_SECRET=...
TOTP_ENCRYPTION_KEY=...
ADMIN_EMAIL=...
SERVER_PORT=8080
TZ=Asia/Shanghai
```

这些只是占位示例。真实值应保存在服务器 `.env` 中，不要用 README 或 `.env.ops.example` 中的值覆盖现有生产密钥。

## 部署门禁

`doctor`、`validate`、`validate-candidate` 和 `deploy` 会对高风险设置 fail closed：

- `POSTGRES_PASSWORD`、`REDIS_PASSWORD`、`JWT_SECRET` 和 `TOTP_ENCRYPTION_KEY` 不能为空。
- 首次部署且 `postgres_data` 目录为空时，必须设置 `ADMIN_PASSWORD`。
- `SERVER_PORT` 必须是数字。
- `BIND_HOST=0.0.0.0` 需要设置 `SUB2API_ALLOW_PUBLIC_BIND=true`；否则 compose 默认绑定到 `127.0.0.1`。
- `sub2api`、`postgres` 和 `redis` 镜像必须使用 `@sha256:` digest 固定。

更新固定镜像时，先用 Docker registry 工具解析当前 digest，再编辑 `deploy/docker-compose.yml`：

```powershell
docker buildx imagetools inspect postgres:18-alpine
docker buildx imagetools inspect redis:8-alpine
```

应用发布应继续使用不可变的 Sub2API 镜像 digest。避免部署 `latest`、`main` 或 `dev` 这类可变 tag。

## 破坏性迁移确认

部署脚本会扫描尚未应用的 SQL 迁移，查找可能不可逆的语句，例如 `DROP TABLE`、`DROP COLUMN`、破坏性 `DELETE` 和有损类型变更。默认扫描：

```text
/opt/sub2api-deploy/.ops/migrations
```

如果迁移 SQL 文件位于其它目录，在服务器 `.env` 中设置 `SUB2API_MIGRATIONS_DIR`。如果高风险迁移是预期行为，部署需要同时设置：

```text
SUB2API_DESTRUCTIVE_MIGRATION_CONFIRMED=true
SUB2API_DESTRUCTIVE_MIGRATION_NOTE='affected files, impact, backup location, restore plan'
```

## 安全说明

使用专用 Linux 用户，例如 `sub2api-ops`；尽量避免直接用 `root` 做自动化。

脚本会在以下目录创建备份：

```text
/opt/sub2api-deploy/backups/
```

默认只保留最近 3 个备份目录。如需调整，在服务器 `.env` 中设置 `SUB2API_BACKUP_RETENTION=<count>`。

如果 PostgreSQL 容器正在运行，数据库备份会使用 `pg_dump`。如果 PostgreSQL 尚未运行，脚本仍会备份配置文件和本地目录。

回滚会恢复 `.env`、`docker-compose.yml`、可选的 `config.yaml`，并从最新配置备份重启容器。它不会自动恢复数据库 dump。如需恢复数据库，请在停止应用后，从选定备份中手动恢复 `postgres.sql`。

每次源代码部署前，都要检查新镜像是否包含数据库迁移。如果迁移包含可能不可逆的操作，例如 `DROP TABLE`、`DROP COLUMN`、破坏性 `DELETE`、有损类型变更或无法重算的数据回填，应暂停并在部署前提醒操作者。部署说明必须包含受影响的迁移文件、预期影响、备份位置和具体回滚计划。不要只依赖容器回滚来处理不可逆数据库变更。

## 蓝绿部署

`bluegreen-deploy` 执行单机蓝绿发布：

1. PostgreSQL 和 Redis 保持共享。
2. 启动非活跃应用槽位（`sub2api-blue` 或 `sub2api-green`）。
3. 验证非活跃槽位健康状态和最近日志。
4. 重新加载 Caddy，将流量切到健康槽位。
5. 切换完成后停止旧槽位，避免重复后台任务。

Caddy 是唯一绑定到 `${BIND_HOST}:${SERVER_PORT}` 的服务。当前槽位记录在：

```text
/opt/sub2api-deploy/.ops/active-slot
```

使用 `switch-slot` 手动切换流量，使用 `active-slot` 打印当前槽位。

## 后台部署运行

当生产部署的控制通道可能依赖同一服务时，使用 `start-bluegreen-deploy`。它会在远程后台启动部署，在服务器写入持久化日志，并在流量切换前返回 run id。

```powershell
.\scripts\sub2api-ops.cmd validate-candidate
.\scripts\sub2api-ops.cmd start-bluegreen-deploy
.\scripts\sub2api-ops.cmd run-status
.\scripts\sub2api-ops.cmd run-logs
```

运行数据保存在服务器：

```text
/opt/sub2api-deploy/.ops/deploy-runs/
```

`run-status` 和 `run-logs` 默认读取最新运行。要查看历史运行，在 `.env.ops` 中设置 `SUB2API_RUN_ID=<run-id>`。服务器默认保留最近 20 次运行；可在服务器 `.env` 中设置 `SUB2API_RUN_RETENTION=<count>` 调整。
