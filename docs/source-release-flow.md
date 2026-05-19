# Source Change Release Flow

Use this flow when changing Sub2API application behavior, not just deployment configuration.

## Repositories

```text
C:\Users\Administrator\Desktop\code\sub2api-wrap\sub2api
```

Ops repository:

```text
git@github.com:zeroliao/zero007-sub2api-ops.git
```

Tracks deployment scripts and the production compose baseline.

```text
C:\Users\Administrator\Desktop\code\sub2api-wrap\sub2api-src
```

Source repository:

```text
git@github.com:zeroliao/sub2api.git
```

Tracks Sub2API source changes.

## Release Sequence

1. Create a feature branch in `sub2api-src`.
2. Modify backend/frontend code.
3. Run targeted tests for the touched area.
4. Build a Docker image from the source repository.
5. Push the image to a registry.
6. Update `deploy/docker-compose.yml` in the ops repository to use the new immutable image tag.
7. If the release includes new SQL migrations, copy them to the server migration scan directory or set `SUB2API_MIGRATIONS_DIR` to the source migration directory.
8. Run `diff-server` to confirm the server compose still matches the ops baseline.
9. Commit and push both repositories.
10. Run `validate-candidate`; the server fetches the ops repository and checks out the same pushed commit.
11. Run `backup`.
12. Run `bluegreen-deploy` for application releases, or `deploy` for traditional all-in-place deployment.
13. Verify health and logs.

Deployment actions fail if the local ops worktree has uncommitted changes or if local `HEAD` does not match the configured remote branch. `SUB2API_ALLOW_DIRTY_DEPLOY=true` is available only for explicit emergency local uploads.

## Image Tags

Prefer immutable tags:

```text
ghcr.io/zeroliao/sub2api:<yyyyMMdd-HHmm>-<short-sha>
```

Avoid deploying mutable tags for custom code:

```text
latest
main
dev
```

## Rollback

Rollback is handled from the ops repository by restoring the previous compose backup and running:

```powershell
.\scripts\sub2api-ops.cmd rollback
```

The server keeps backups under:

```text
/opt/sub2api-deploy/backups/
```

Rollback restores config files and restarts containers. It does not automatically restore `postgres.sql`; database restores must be performed manually from the selected backup.
