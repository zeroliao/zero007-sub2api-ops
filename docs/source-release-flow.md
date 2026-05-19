# Source Change Release Flow

Use this flow when changing Sub2API application behavior, not just deployment configuration.

## Repositories

```text
C:\Users\Administrator\Desktop\code\sub2api
```

Ops repository:

```text
git@github.com:zeroliao/zero007-sub2api-ops.git
```

Tracks deployment scripts and the production compose baseline.

```text
C:\Users\Administrator\Desktop\code\sub2api-src
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
7. Run `diff-server` to confirm the server compose still matches the ops baseline.
8. Run `backup`.
9. Run `deploy`.
10. Verify health and logs.
11. Commit and push both repositories.

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

