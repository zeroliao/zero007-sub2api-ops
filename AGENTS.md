# `zero007-sub2api-ops` Codex 指南

`zero007-sub2api-ops` 是 Sub2API 的生产运维仓库，负责部署脚本、生产 Compose 基线、Caddy 蓝绿路由、备份保留、回滚行为和部署门禁。

应用源代码位于 `../sub2api`。

## 优先阅读

- `README.md`：运维命令和当前部署模型。
- `docs/source-release-flow.md`：源代码发布流程。
- `docs/server-prep.md`：服务器目录和密钥要求。
- `../sub2api/AGENTS.md`：仅在部署依赖应用源代码变更时阅读。

## 生产模型

- 远程部署目录：`/opt/sub2api-deploy`。
- 服务器密钥保存在 `/opt/sub2api-deploy/.env`。
- 不要编辑或打印真实的 `.env.ops` 或服务器 `.env` 密钥。
- Compose 基线：`deploy/docker-compose.yml`。
- 远程部署脚本：`remote/sub2api-remote-ops.sh`。
- 本地入口：`scripts/sub2api-ops.cmd` / `scripts/sub2api-ops.ps1`。
- Caddy 将流量路由到当前活跃的蓝/绿应用槽位。
- PostgreSQL 和 Redis 在蓝绿槽位之间共享。
- 备份位于 `/opt/sub2api-deploy/backups/`，默认保留 3 个备份目录。

## Git 驱动部署

部署动作默认由 Git 驱动：

- `validate-candidate`
- `deploy`
- `bluegreen-deploy`

这些动作只有满足以下条件才会继续：

- 本地工作区干净；
- 本地 `HEAD` 与 `SUB2API_OPS_REMOTE/SUB2API_OPS_BRANCH` 一致；
- 服务器能使用 `SUB2API_REMOTE_GIT_SSH_KEY` 拉取 `SUB2API_OPS_REPO`；
- 服务器在使用 compose/scripts 前检出同一个 commit。

紧急本地上传模式存在，但默认应保持关闭：

```text
SUB2API_ALLOW_DIRTY_DEPLOY=true
```

只有得到明确批准时才使用。

## 常规部署命令

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

常用只读/状态命令：

```powershell
.\scripts\sub2api-ops.cmd doctor
.\scripts\sub2api-ops.cmd active-slot
.\scripts\sub2api-ops.cmd logs
.\scripts\sub2api-ops.cmd audit-allowlist
.\scripts\sub2api-ops.cmd validate-allowlist
```

当 Codex/API 控制通道可能经由同一服务转发时，生产变更优先使用 `start-bluegreen-deploy`。它会在 `/opt/sub2api-deploy/.ops/deploy-runs/` 写入持久化运行日志；重连后使用 `run-status` 和 `run-logs` 查看进度。

## 用户确认流程

当用户提出需求但没有明确要求立即执行时，先给出方案和简短步骤计划，等待用户确认后再行动。

- 这适用于仓库写入、commit、push、pull、reset、stash、依赖变更、服务变更、部署，以及其它会改变本地或远程状态的操作。
- 为制定方案而执行只读检查是允许的，但在请求确认前要说明检查了什么。
- 如果界面支持可点击或悬浮确认选项，优先使用这种确认方式，而不是要求用户自由输入。
- 将“直接执行”“继续”“应用这个改动”“进行修改”或同等含义的中英文表达视为对已描述动作的确认。

## 共享仓库规则

新增或修改非项目专属的协作规则时，需要同时更新两个仓库的指南文件：

- `../sub2api/AGENTS.md`
- `../sub2api-src/AGENTS.md`

在不降低正确性、工具兼容性或项目功能的前提下，尽量使用中文。这包括解释、计划、commit 信息和面向用户的协作说明。代码标识符、命令、协议名、环境变量以及已有英文项目术语，如果翻译会误导或造成损害，应保持原样。

如果同一份 Markdown 文档存在多语言版本，例如 `README.md`、`README_CN.md`、`README_JA.md`，只修改中文版本，其它语言版本保持不动。

## Git 管理流程

Commit 应表示一个完整意图，而不是一次对话。多次相关对话如果属于同一个逻辑变更，并且可以一起审查或回滚，可以合并为一个 commit。

- 除非用户明确要求 commit，或确认了提交计划，否则不要创建 commit。
- 提交前检查 `git status` 和 `git diff`，按主题归类改动，并说明建议使用一个还是多个 commit。
- Commit message 必须使用中文，并清楚描述改动内容、动机和影响。
- 推荐格式：`类型：简短说明`，正文用要点说明改了什么以及为什么改。
- 无关事项应拆成不同 commit，尤其是文档、部署行为、安全门禁、镜像更新和源代码改动。
- Commit 后不要默认 push，除非用户明确要求或确认 push。
- Push 前说明目标 remote/branch，以及本地历史相对远程是 ahead、behind 还是 diverged。

## 部署确认规则

除非用户在同一请求中明确要求部署，或在被询问后确认部署，否则不要运行生产部署命令。

- 当用户说出“改完并部署”“直接部署”“自动部署”“部署到服务器”或同等含义表达时，可视为直接部署授权。
- 如果用户只是要求实现、修复、优化、commit 或准备变更，本地验证后停止，并在部署前询问。
- `validate-candidate`、`doctor`、`status`、`active-slot`、`run-status`、`run-logs` 和 `logs` 可作为检查命令执行。
- `deploy`、`bluegreen-deploy`、`start-deploy` 和 `start-bluegreen-deploy` 需要明确部署意图或确认。

## 部署门禁

远程脚本会对以下高风险设置 fail closed：

- 缺少 `POSTGRES_PASSWORD`、`REDIS_PASSWORD`、`JWT_SECRET` 或 `TOTP_ENCRYPTION_KEY`。
- Redis 密码仍是占位值。
- `SERVER_PORT` 不是数字。
- `BIND_HOST=0.0.0.0`，且没有设置 `SUB2API_ALLOW_PUBLIC_BIND=true`。
- 首次部署时 `postgres_data` 为空且没有 `ADMIN_PASSWORD`。
- 服务镜像没有使用 `@sha256:` digest 固定。
- 可能存在破坏性迁移，但没有设置确认变量和说明。

## 回滚和备份

- 部署前会执行备份；当 PostgreSQL 正在运行时，同时保存配置和 PostgreSQL dump。
- 后台部署运行会在 `/opt/sub2api-deploy/.ops/deploy-runs/` 保存状态、PID、退出码、时间戳和日志。
- 回滚会恢复 `.env`、`docker-compose.yml`、可选的 `config.yaml`、Caddy 配置、活跃槽位文件和容器启动状态。
- 回滚不会自动恢复数据库 dump。
- 从 `postgres.sql` 恢复数据库是手动操作，必须在破坏性迁移前规划好。

## 编辑规则

- 不要提交 `.env.ops`。
- 不要打印本地 `.env.ops` 或远程 `/opt/sub2api-deploy/.env` 中的密钥。
- 镜像引用必须保持不可变，并使用 digest 固定。
- 使用 registry 工具解析新镜像 digest，不要猜测。
- 应用发布使用 `bluegreen-deploy`，除非明确选择传统 `deploy`。
