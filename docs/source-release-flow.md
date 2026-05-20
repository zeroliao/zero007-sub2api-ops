# 源代码变更发布流程

当变更 Sub2API 应用行为，而不仅是部署配置时，使用这套流程。

## 仓库

```text
C:\Users\Administrator\Desktop\code\sub2api-wrap\sub2api
```

Ops 仓库：

```text
git@github.com:zeroliao/zero007-sub2api-ops.git
```

跟踪部署脚本和生产 compose 基线。

```text
C:\Users\Administrator\Desktop\code\sub2api-wrap\sub2api-src
```

Source 仓库：

```text
git@github.com:zeroliao/sub2api.git
```

跟踪 Sub2API 源代码变更。

## 发布顺序

1. 在 `sub2api-src` 创建功能分支。
2. 修改后端/前端代码。
3. 针对受影响区域运行测试。
4. 从源代码仓库构建 Docker 镜像。
5. 将镜像推送到 registry。
6. 更新 ops 仓库中的 `deploy/docker-compose.yml`，使用新的不可变镜像 tag。
7. 如果发布包含新的 SQL 迁移，将它们复制到服务器迁移扫描目录，或将 `SUB2API_MIGRATIONS_DIR` 设置为源代码迁移目录。
8. 运行 `diff-server`，确认服务器 compose 仍与 ops 基线一致。
9. 提交并推送两个仓库。
10. 运行 `validate-candidate`；服务器会拉取 ops 仓库并检出同一个已推送 commit。
11. 运行 `backup`。
12. 应用发布运行 `bluegreen-deploy`；如明确选择传统全量原地部署，则运行 `deploy`。
13. 验证健康状态和日志。

如果本地 ops 工作区有未提交改动，或本地 `HEAD` 与配置的远程分支不一致，部署动作会失败。`SUB2API_ALLOW_DIRTY_DEPLOY=true` 仅用于明确批准的紧急本地上传。

## 镜像 Tag

优先使用不可变 tag：

```text
ghcr.io/zeroliao/sub2api:<yyyyMMdd-HHmm>-<short-sha>
```

避免为自定义代码部署可变 tag：

```text
latest
main
dev
```

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
