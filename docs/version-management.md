# 版本与分支管理

本文档是两个仓库的版本流程权威说明：

- `sub2api`：运维与部署仓库。
- `sub2api-src`：应用源码 fork 仓库。

## 分支与版本模型

两个仓库使用同一个版本号。版本可以只改一个仓库，也可以同时改两个仓库。

```text
main
dev/<version>
release/<version>
v<version>
```

- `main`：只保存已成功部署到生产的稳定代码。
- `dev/<version>`：版本开发分支。
- `release/<version>`：提测、验证和部署候选分支。
- `v<version>`：版本成功部署后创建的 tag。

`main` 不作为生产候选镜像构建入口。生产候选镜像只能来自 `sub2api-src/release/<version>`，并且必须以 immutable digest 形式进入运维仓库 compose。

版本状态只使用以下 5 种：

```text
开发中
已提测
成功
失败
取消
```

每次新建版本时，版本号从当前最大版本号递增，例如 `001`、`002`、`003`。

## 上游同步规则

`sub2api-src` 是 fork 仓库，但不能直接把 upstream 代码同步到 `main`。上游代码变动也必须纳入一个版本。

- 只有用户主动提出“同步上游代码”时，才允许 fetch/merge upstream。
- 上游代码只能进入某个 `dev/<version>`，不能绕过版本直接进入 `main`。
- 可以把上游同步纳入已有版本，也可以新建一个专门版本。
- 包含上游同步的版本必须通过本地 Docker 验证和生产部署验证。
- 如果上游代码导致问题，可回滚到上一个成功 tag，或 revert 该版本引入的上游同步提交。

## 版本流程

1. 创建版本：
   - 分配下一个版本号。
   - 确认版本类型：源码 / 运维 / 混合 / 上游同步。
   - 只为需要改动的仓库创建 `dev/<version>`。
   - 未改动仓库记录当前 `main` commit 或上一个成功 tag。

2. 开发：
   - 业务改动进入对应仓库的 `dev/<version>`。
   - 上游同步必须由用户主动提出，并作为版本内容进入 `dev/<version>`。
   - Commit message 使用中文，说明改动内容、原因和影响。

3. 提测：
   - 将对应仓库的 `dev/<version>` 同步到 `release/<version>`。
   - 推送 `sub2api-src/release/<version>` 后，由 GitHub Actions 构建候选镜像并推送到 registry。
   - 记录 GitHub Actions 输出的 immutable image digest。
   - 运维仓库 `release/<version>` 的 compose 使用同一个 digest。
   - 本地 Docker 使用同一个 release commit、compose commit 和 image digest 验证。
   - 验证通过后，版本状态改为 `已提测`。

4. 部署：
   - 服务器部署必须使用同一个 `release/<version>` commit、compose commit 和 image digest。
   - 先执行服务器侧验证，再执行备份、蓝绿部署、健康检查和日志检查。

5. 成功：
   - 版本状态改为 `成功`。
   - 受影响仓库的 `release/<version>` 合入 `main`。
   - 两个仓库都打 `v<version>` tag。
   - 未改动仓库的 tag 指向本次部署实际使用的 `main` commit。
   - `v<version>` 是部署成功后的归档点；不得用 tag 触发的新镜像替换已经本地和服务器验证通过的 digest。
   - 将最新 `main` 同步到所有 `开发中`、`已提测` 状态版本的 dev/release 分支。

6. 失败：
   - 版本状态改为 `失败`。
   - 生产回滚到上一个成功 tag 或蓝绿旧槽位。
   - 保留 `release/<version>` 分支用于排查。
   - 不合入 `main`。

7. 取消：
   - 版本状态改为 `取消`。
   - 不合入 `main`。
   - 保留版本记录，写明取消原因。

## 本地 Docker 验证一致性

本地 Docker 和服务器环境可能不同，因此本地验证不能替代服务器验证。为降低差异，必须保证以下内容一致：

- 本地验证和服务器部署使用同一个 `release/<version>` commit。
- 本地验证和服务器部署使用同一个 compose commit。
- 本地验证和服务器部署使用同一个 immutable image digest。
- 本地验证和服务器部署使用同一组关键环境变量开关；真实密钥值可以不同。

如果当前开发电脑没有 Docker，可以先提交并推送代码，由有 Docker 的机器拉取同一个 `release/<version>` commit、运维仓库同一个 compose commit 和同一个镜像 digest 继续验证。验证结果必须写入版本记录。

## 节点交接信号

每个节点完成后，必须留下可检查的完成信号，下一节点只根据这些信号继续：

| 节点 | 完成信号 | 下一步 |
| --- | --- | --- |
| 创建版本 | 版本号、涉及仓库、初始 commit/tag 已写入版本记录 | 创建对应 `dev/<version>` |
| 开发完成 | `dev/<version>` 工作区干净，commit 已完成，测试结果已记录 | 同步到 `release/<version>` |
| 源码 release 推送 | `sub2api-src/release/<version>` 已推送到 GitHub | 等待 `GHCR Image` workflow 完成 |
| 候选镜像构建 | GitHub Actions `GHCR Image` 成功，Summary 输出 `ghcr.io/...@sha256:<digest>` | 将 digest 写入版本记录并更新 ops compose |
| ops release 推送 | `sub2api/release/<version>` 已推送，compose 使用同一 digest | 有 Docker 的机器开始本地 Docker 验证 |
| 本地 Docker 验证 | 版本记录写明验证机器、source commit、ops commit、digest 和验证结果 | 状态改为 `已提测`，执行服务器侧 `validate-candidate` |
| 服务器候选验证 | `validate-candidate` 成功 | 执行 `backup` |
| 备份 | 备份路径和时间写入版本记录 | 执行蓝绿部署 |
| 部署 | 健康检查、日志检查、核心路径验证通过 | 状态改为 `成功`，合入 `main` 并打 tag |
| 发布归档 | `release.yml` 成功，GitHub Release 已创建 | 如需要，运行 `Promote Verified Image` |
| 镜像 tag 提升 | `Promote Verified Image` 成功，Summary 显示同一 digest 的版本 tag | 记录 tag，继续同步其它未完成版本 |

如果任一节点失败，停止进入下一节点；先把失败原因写入版本记录，并根据影响选择修复、重试、取消或失败回滚。

## 发版复盘固化规则

涉及创建版本、发版、部署或回滚时，必须先阅读本文档，再执行任何分支、镜像、compose 或生产操作。

每次发版前必须显式完成以下检查：

- 确认当前不在 Plan Mode 或只规划状态；用户明确要求执行后，按版本节点连续推进。
- 先运行 `diff-server`，把服务器已有服务、挂载目录、sidecar 和环境差异纳入 release compose 基线，避免部署时误删生产已有组件。
- 生产候选镜像只能使用 `release/<version>` 构建出的 immutable digest；不得用 tag 或 main 构建结果替代已验证 digest。
- 本地 Docker 拉取 fixed digest 失败时，先排查 Docker Hub registry mirror、OCI referrers 或 attestation 兼容问题；必要时用 `registry-1.docker.io/library/...@sha256:...` 拉取同一 digest 交叉验证，不得因此改动生产 compose 的 digest 语义。
- 版本记录必须使用 UTF-8 保存，并记录 source commit、ops commit、image digest、本地验证结果、服务器验证结果、备份路径、部署 run id、活跃槽位和回滚目标。
- 生产已有 `sing-box`、`mihomo`、`xray` 等 sidecar 只要仍被服务器使用，必须保留或明确迁移；不得在未确认影响前从 compose 中移除。
- 部署成功后，先确认健康检查、迁移和核心路径，再合入 `main`、打 `v<version>` tag 和归档版本记录。

## 镜像构建与发布规则

- 生产候选镜像由 `sub2api-src/.github/workflows/ghcr-image.yml` 构建。
- 自动触发条件是推送 `sub2api-src/release/<version>`；手动触发时也必须选择 `release/<version>`。
- 候选镜像 tag 使用 `release-<version>-<short_sha>` 和 `sha-<commit>`；生产部署只能使用 `ghcr.io/...@sha256:<digest>`。
- 候选镜像构建通过 build arg 注入版本号；如果需要更新 `backend/cmd/server/VERSION`，必须作为版本内容进入 `dev/<version>` / `release/<version>`，不能由发布归档流程在部署后向 `main` 追加 commit。
- `main` push 不作为生产候选镜像来源，避免把尚未走版本验证的代码误用于部署。
- 只修改运维仓库、不修改源码仓库的版本，不需要构建新应用镜像；继续使用版本记录中确认的既有 digest。
- 部署成功后创建 `v<version>` tag；`sub2api-src/.github/workflows/release.yml` 只负责 GitHub Release 和二进制归档，不重新构建或推送 Docker 镜像。
- 如需给已验证镜像追加版本 tag，手动运行 `sub2api-src/.github/workflows/promote-image.yml`，输入已验证 digest 和版本号。该流程只给既有 digest 打 tag，不重新 build。
- GitHub Release、GoReleaser 归档产物或镜像版本 tag 都不能替代已验证 digest，也不能让生产 compose 切换到未经本地 Docker 和服务器验证的新镜像。

本地 Docker 验证至少覆盖：

- `docker compose config` 通过。
- PostgreSQL、Redis、Sub2API 容器能启动。
- 数据库迁移能执行。
- 健康检查通过。
- 最近日志无 fatal/error 级别异常。
- 涉及本版本的核心路径完成最小功能验证。

## 关键检查点

### 检查点 0：创建版本前

- 已确认版本号为当前最大版本号 + 1。
- 已确认版本类型：源码 / 运维 / 混合 / 上游同步。
- 已确认是否只改一个仓库。
- 已确认 upstream 同步是否由用户主动要求。
- 已记录未改动仓库当前 `main` commit 或上一个成功 tag。

### 检查点 1：开发完成前

- `dev/<version>` 工作区干净。
- Commit message 使用中文，并说明改动原因和影响。
- 多仓库版本使用同一个版本号。
- 未改动仓库已在版本记录中标注“不改动”及参与部署 commit/tag。

### 检查点 2：提测前

- `dev/<version>` 已同步到 `release/<version>`。
- `release/<version>` 只包含本版本候选内容。
- 上游同步（如有）已明确记录来源和 commit。
- 如涉及源码仓库，已确认推送 `sub2api-src/release/<version>` 会触发候选镜像构建。
- 版本状态仍为 `开发中`；待本地 Docker 验证通过后再改为 `已提测`。

### 检查点 3：本地 Docker 验证

- 镜像由 `sub2api-src/release/<version>` 的 GitHub Actions 构建。
- 镜像已 push 到 registry，并记录 immutable digest。
- `sub2api/release/<version>` compose 使用同一 digest。
- 本地 Docker 使用同一 compose commit 和同一 digest。
- 健康检查、日志检查和核心功能验证通过。
- 版本状态改为 `已提测`。

### 检查点 4：生产部署前

- 服务器验证使用同一 release commit、compose commit 和 image digest。
- 已执行 `validate-candidate`。
- 已确认备份策略和回滚目标 tag。
- 未发现破坏性迁移风险；如存在风险，已由用户明确确认。

### 检查点 5：部署成功后

- `release/<version>` 已合入受影响仓库的 `main`。
- 两个仓库都已创建 `v<version>` tag。
- 版本状态改为 `成功`。
- 已记录生产部署结果、最终 commit、compose commit 和 image digest。
- 已确认发布归档 workflow 没有向默认分支追加未经验证的 VERSION commit。
- 已确认未用 tag 触发的新构建镜像替换已经验证通过的 digest。
- 如需要镜像版本 tag，已使用 `Promote Verified Image` workflow 提升同一个已验证 digest。

### 检查点 6：同步其它未完成版本

- 最新 `main` 已同步到所有 `开发中`、`已提测` 版本的 `dev/<version>`。
- `已提测` 版本的 `release/<version>` 已重新由对应 dev 分支同步。
- 同步后的 `已提测` 版本必须重新执行本地 Docker 验证。

### 检查点 7：失败或取消时

- 失败版本状态改为 `失败`，取消版本状态改为 `取消`。
- 失败时已回滚到上一个成功 tag 或蓝绿旧槽位。
- `release/<version>` 分支已保留用于排查。
- 版本未合入 `main`。

## 版本记录模板

建议在 `docs/releases/<version>.md` 记录版本：

```text
版本：
状态：开发中 / 已提测 / 成功 / 失败 / 取消
类型：源码 / 运维 / 混合 / 上游同步
是否包含 upstream 同步：是 / 否
触发人：
涉及仓库：
sub2api-src commit：
sub2api commit：
镜像 digest：
compose commit：
本地 Docker 验证：
服务器验证：
部署结果：
回滚目标：
备注：
```
