# PowerShell, SSH, and SQL Notes

This project is often operated from Windows PowerShell while targeting a Linux
server. Commands can cross three parsers at once: PowerShell, SSH remote shell,
and the final command such as `psql`. These notes capture the patterns that have
been reliable in practice.

## What Went Wrong

- PowerShell expands or breaks characters such as `*`, `$`, `(`, `)`, quotes,
  and pipes before SSH receives them.
- Remote Bash then parses the command again.
- Tools such as `psql -c "select ..."` parse the SQL after both shells have
  already had a chance to alter it.

Symptoms include:

```text
unexpected EOF while looking for matching `"`
syntax error near unexpected token `('
psql: warning: extra command-line argument "from" ignored
```

## Preferred Patterns

Set the current PowerShell session to UTF-8 before reading Chinese files or
capturing remote output:

```powershell
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
chcp 65001
Get-Content -Encoding utf8 .\path\to\file.md
```

If text looks like mojibake in the terminal, first verify the file with
`Get-Content -Encoding utf8` before editing it. In several cases the file was
correct UTF-8 and only the PowerShell display path was wrong.

For simple read-only SSH commands, use one command per execution and keep quoting
minimal:

```powershell
ssh ubuntu@host "hostname && date"
```

For Docker commands that require privileges, prefer `sudo docker ...` directly:

```powershell
ssh ubuntu@host "sudo docker ps --format 'table {{.Names}}\t{{.Status}}'"
```

For SQL, avoid embedding complex SQL directly in `ssh "... psql -c \"...\""` from
PowerShell. Base64 the SQL locally and decode it remotely:

```powershell
$Sql = @'
select status, selected, count(*) as cnt
from proxy_subscription_nodes
where source_id = 3 and deleted_at is null
group by status, selected
order by status, selected;
'@
$B64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Sql))
ssh ubuntu@host "echo $B64 | base64 -d | sudo docker exec -i sub2api-postgres psql -U sub2api -d sub2api"
```

This keeps SQL intact across PowerShell, SSH, Bash, and `psql`.

## Safety Rules

- Do not echo secrets such as API keys in logs or chat.
- Prefer environment variables for production secrets.
- Do not commit `key.md`, `.env`, private keys, or server-only credentials.
- If using `grep`, avoid queries that print secret values. Mask values with
  `sed -E 's/=.*/=<set>/'` when checking environment variables.
