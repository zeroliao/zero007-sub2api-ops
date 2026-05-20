# 源代码变更发布流程

当变更 Sub2API 应用行为，而不仅是部署配置时，使用这套流程。本文是源码变更的快捷说明；完整版本、分支、状态和检查点以 `docs/version-management.md` 为准。

## 仓库

Ops 仓库：

```text
C:\Users\Administrator\Desktop\code\sub2api-wrap\sub2api
git@github.com:zeroliao/zero007-sub2api-ops.git
```

跟踪部署脚本、生产 compose 基线和版本流程文档。

Source 仓库：

```text
C:\Users\Administrator\Desktop\code\sub2api-wrap\sub2api-src
git@github.com:zeroliao/sub2api.git
```

跟踪 Sub2API 源代码、GitHub Actions 和镜像构建输入。

## 发布顺序

1. 分配下一个版本号，两个仓库使用同一个版本号。
2. 在需要改动的仓库创建 `dev/<version>`；未改动仓库记录当前 `main` commit 或上一个成功 tag。
3. 在 `sub2api-src/dev/<version>` 完成源码改动；如需同步 upstream，必须由用户主动提出并纳入该版本内容。
4. 针对受影响区域运行后端、前端或静态检查。
5. 将 `sub2api-src/dev/<version>` 同步到 `sub2api-src/release/<version>`。
6. 推送 `sub2api-src/release/<version>`，由 `GHCR Image` workflow 构建候选镜像并推送到 GHCR。
7. 等待 `GHCR Image` workflow 成功，从 Summary 复制 immutable image digest 并写入版本记录。
8. 在 `sub2api/release/<version>` 更新 `deploy/docker-compose.yml`，使用同一个 digest。
9. 提交并推送两个仓库的 `release/<version>` 分支。
10. 在有 Docker 的机器上拉取同一个 source release commit、ops compose commit 和 image digest，完成本地 Docker 验证。
11. 本地 Docker 验证通过后，将版本状态改为 `已提测`。
12. 运行 `diff-server`，确认服务器 compose 与 ops 基线差异可控。
13. 运行 `validate-candidate`；服务器会拉取 ops 仓库并检出同一个已推送 commit。
14. 运行 `backup`。
15. 应用发布优先运行 `start-bluegreen-deploy` 或 `bluegreen-deploy`；如明确选择传统全量原地部署，则运行 `deploy`。
16. 验证健康状态、日志、活跃槽位和本版本核心功能。
17. 部署成功后，将受影响仓库的 `release/<version>` 合入 `main`。
18. 两个仓库都创建 `v<version>` tag，未改动仓库的 tag 指向本次部署实际使用的 `main` commit。
19. `sub2api-src` 的 `release.yml` 只做 GitHub Release 和二进制归档，不重新构建 Docker 镜像。
20. 如需要镜像版本 tag，手动运行 `Promote Verified Image` workflow，将已验证 digest 提升为 `v<version>` / `<version>` tag。
21. 将最新 `main` 同步到所有仍处于 `开发中`、`已提测` 状态的版本分支；已提测版本同步后必须重新验证。

如果本地 ops 工作区有未提交改动，或本地 `HEAD` 与配置的远程分支不一致，部署动作会失败。`SUB2API_ALLOW_DIRTY_DEPLOY=true` 仅用于明确批准的紧急本地上传。

## 节点交接

- `GHCR Image` workflow 成功后，Summary 会输出候选镜像 digest 和下一步清单；没有这个 digest，不进入 ops compose 更新。
- ops `release/<version>` 推送后，有 Docker 的电脑才能拉取同一个 compose commit 做本地验证。
- 本地 Docker 验证结果必须写入版本记录；没有通过记录，不进入 `validate-candidate`。
- `validate-candidate` 成功后才执行 `backup`；备份成功后才执行蓝绿部署。
- 部署成功后才合入 `main`、打 `v<version>` tag、运行发布归档和可选的 `Promote Verified Image`。

## 镜像规则

- 生产候选镜像只能从 `sub2api-src/release/<version>` 构建。
- `main` push 不作为生产候选镜像入口。
- 生产 compose 必须使用 `ghcr.io/...@sha256:<digest>`。
- 避免为生产部署使用可变 tag，例如：

```text
latest
main
dev
release
```

- `v<version>` tag 和镜像版本 tag 是部署成功后的归档或引用便利，不能替代已经完成本地 Docker 和服务器验证的 digest。

## 回滚

回滚由 ops 仓库处理：恢复上一个 compose 备份并运行：

```powershell
.\scripts\sub2api-ops.cmd rollback
```

服务器备份保存在：

```text
/opt/sub2api-deploy/backups/
```

回滚会恢复配置文件并重启容器。它不会自动恢复 `postgres.sql`；数据库恢复必须从选定备份中手动执行。
