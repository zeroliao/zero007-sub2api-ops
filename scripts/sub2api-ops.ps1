param(
  [ValidateSet("inspect", "doctor", "validate", "validate-candidate", "backup", "deploy", "bluegreen-deploy", "start-deploy", "start-bluegreen-deploy", "run-status", "run-logs", "active-slot", "switch-slot", "rollback", "status", "logs", "diff-server", "sync-from-server", "audit-allowlist", "validate-allowlist")]
  [string]$Action = "doctor",
  [string]$ConfigPath = ".env.ops"
)

$ErrorActionPreference = "Stop"

function Import-DotEnv {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Missing $Path. Copy .env.ops.example to .env.ops and fill in SSH settings."
  }

  Get-Content -LiteralPath $Path | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith("#")) {
      return
    }

    $parts = $line.Split("=", 2)
    if ($parts.Count -eq 2) {
      [Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim(), "Process")
    }
  }
}

function Require-Value {
  param([string]$Name)
  $value = [Environment]::GetEnvironmentVariable($Name, "Process")
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "Missing required setting: $Name"
  }
  return $value
}

function Invoke-Checked {
  param([string[]]$Command)

  $commandName = Split-Path -Leaf $Command[0]
  $isNetworkCommand = $commandName -in @("ssh", "ssh.exe", "scp", "scp.exe")
  $maxAttempts = if ($isNetworkCommand) { 3 } else { 1 }

  for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    if ($maxAttempts -gt 1) {
      Write-Host ">> [$attempt/$maxAttempts] $($Command -join ' ')"
    }
    else {
      Write-Host ">> $($Command -join ' ')"
    }

    & $Command[0] @($Command | Select-Object -Skip 1)
    if ($LASTEXITCODE -eq 0) {
      return
    }

    if (-not $isNetworkCommand -or $LASTEXITCODE -ne 255 -or $attempt -eq $maxAttempts) {
      throw "Command failed with exit code ${LASTEXITCODE}: $($Command -join ' ')"
    }

    $delaySeconds = 5 * $attempt
    Write-Host "Transient SSH/SCP failure detected; retrying in ${delaySeconds}s."
    Start-Sleep -Seconds $delaySeconds
  }
}

function ConvertTo-ShellSingleQuoted {
  param([string]$Value)
  return "'" + $Value.Replace("'", "'`"`"'`"") + "'"
}

function Get-GitOutput {
  param([string[]]$GitArgs)

  if ([string]::IsNullOrWhiteSpace($gitExe)) {
    throw "Missing git executable. Install Git or set SUB2API_GIT_EXE."
  }

  $output = & $gitExe -C $repoRoot @GitArgs 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "git $($GitArgs -join ' ') failed: $($output -join "`n")"
  }
  return ($output -join "`n").Trim()
}

function Invoke-GitChecked {
  param([string[]]$GitArgs)

  if ([string]::IsNullOrWhiteSpace($gitExe)) {
    throw "Missing git executable. Install Git or set SUB2API_GIT_EXE."
  }

  $maxAttempts = if ($GitArgs.Count -gt 0 -and $GitArgs[0] -eq "fetch") { 3 } else { 1 }
  for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    if ($maxAttempts -gt 1) {
      Write-Host ">> git [$attempt/$maxAttempts] $($GitArgs -join ' ')"
    }
    else {
      Write-Host ">> git $($GitArgs -join ' ')"
    }

    & $gitExe -C $repoRoot @GitArgs
    if ($LASTEXITCODE -eq 0) {
      return
    }

    if ($attempt -eq $maxAttempts) {
      throw "git $($GitArgs -join ' ') failed with exit code $LASTEXITCODE"
    }

    $delaySeconds = 5 * $attempt
    Write-Host "Transient git failure detected; retrying in ${delaySeconds}s."
    Start-Sleep -Seconds $delaySeconds
  }
}

function Get-RequiredOpsCommit {
  param(
    [string]$OpsRemote,
    [string]$OpsBranch
  )

  $status = Get-GitOutput @("status", "--porcelain")
  if (-not [string]::IsNullOrWhiteSpace($status)) {
    throw "Refusing Git-backed deployment with uncommitted ops changes. Commit and push first, or set SUB2API_ALLOW_DIRTY_DEPLOY=true for an explicit emergency local upload."
  }

  $commit = Get-GitOutput @("rev-parse", "HEAD")
  $remoteRef = "$OpsRemote/$OpsBranch"
  $existingRemoteCommit = ""
  try {
    $existingRemoteCommit = Get-GitOutput @("rev-parse", $remoteRef)
  }
  catch {
    $existingRemoteCommit = ""
  }

  if ($existingRemoteCommit -ne $commit) {
    Invoke-GitChecked @("fetch", $OpsRemote, $OpsBranch)
  }

  $remoteCommit = Get-GitOutput @("rev-parse", $remoteRef)

  if ($commit -ne $remoteCommit) {
    throw "Refusing deployment because local HEAD ($commit) does not match $OpsRemote/$OpsBranch ($remoteCommit). Push or sync the ops repository first."
  }

  return $commit
}

function Invoke-RemoteGitCheckout {
  param(
    [string]$RepoUrl,
    [string]$Branch,
    [string]$Commit,
    [string]$RemoteOpsDir,
    [string]$RemoteGitSshKey
  )

  $script = @'
#!/usr/bin/env bash
set -e
repo_url="$1"
branch="$2"
commit="$3"
repo_dir="$4"
git_key="$5"
git_ssh="ssh -i $git_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
mkdir -p "${repo_dir%/*}"
if [ ! -d "$repo_dir/.git" ]; then
  GIT_SSH_COMMAND="$git_ssh" git clone --no-checkout "$repo_url" "$repo_dir"
fi
cd "$repo_dir"
GIT_SSH_COMMAND="$git_ssh" git remote set-url origin "$repo_url"
GIT_SSH_COMMAND="$git_ssh" git fetch --prune origin "$branch"
git cat-file -e "$commit^{commit}"
git checkout --detach -f "$commit"
chmod +x remote/sub2api-remote-ops.sh
'@

  $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "sub2api-ops-checkout-$PID"
  $localHelper = Join-Path $tmpDir "checkout-ops.sh"
  $remoteHelper = "/tmp/sub2api-checkout-ops-$PID.sh"

  New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
  try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($localHelper, ($script -replace "`r`n", "`n"), $utf8NoBom)
    Invoke-Checked ($scpBase + @($localHelper, "${target}:$remoteHelper"))
    Invoke-Checked ($sshBase + @($target, "chmod +x '$remoteHelper'"))
    Invoke-Checked ($sshBase + @($target, "bash '$remoteHelper' $(ConvertTo-ShellSingleQuoted $RepoUrl) $(ConvertTo-ShellSingleQuoted $Branch) $(ConvertTo-ShellSingleQuoted $Commit) $(ConvertTo-ShellSingleQuoted $RemoteOpsDir) $(ConvertTo-ShellSingleQuoted $RemoteGitSshKey); rc=`$?; rm -f '$remoteHelper'; exit `$rc"))
  }
  finally {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Import-DotEnv -Path $ConfigPath

$hostName = Require-Value "SUB2API_SSH_HOST"
$userName = Require-Value "SUB2API_SSH_USER"
$port = Require-Value "SUB2API_SSH_PORT"
$remoteDir = Require-Value "SUB2API_REMOTE_DIR"
$healthUrl = Require-Value "SUB2API_HEALTH_URL"
$projectName = [Environment]::GetEnvironmentVariable("SUB2API_PROJECT_NAME", "Process")
$sshKey = [Environment]::GetEnvironmentVariable("SUB2API_SSH_KEY", "Process")
$opsRepo = [Environment]::GetEnvironmentVariable("SUB2API_OPS_REPO", "Process")
$opsRemote = [Environment]::GetEnvironmentVariable("SUB2API_OPS_REMOTE", "Process")
$opsBranch = [Environment]::GetEnvironmentVariable("SUB2API_OPS_BRANCH", "Process")
$remoteOpsDir = [Environment]::GetEnvironmentVariable("SUB2API_REMOTE_OPS_DIR", "Process")
$remoteGitSshKey = [Environment]::GetEnvironmentVariable("SUB2API_REMOTE_GIT_SSH_KEY", "Process")
$allowDirtyDeploy = [Environment]::GetEnvironmentVariable("SUB2API_ALLOW_DIRTY_DEPLOY", "Process")
$runId = [Environment]::GetEnvironmentVariable("SUB2API_RUN_ID", "Process")
$runLogTail = [Environment]::GetEnvironmentVariable("SUB2API_RUN_LOG_TAIL", "Process")

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$remoteScript = Join-Path $repoRoot "remote/sub2api-remote-ops.sh"
$composeFile = Join-Path $repoRoot "deploy/docker-compose.yml"
$gitExe = [Environment]::GetEnvironmentVariable("SUB2API_GIT_EXE", "Process")

if (-not (Test-Path -LiteralPath $remoteScript)) {
  throw "Missing remote script: $remoteScript"
}

if (-not (Test-Path -LiteralPath $composeFile)) {
  throw "Missing compose file: $composeFile"
}

if ([string]::IsNullOrWhiteSpace($gitExe)) {
  $gitCmd = Get-Command git -ErrorAction SilentlyContinue
  if ($gitCmd) {
    $gitExe = $gitCmd.Source
  }
  elseif (Test-Path -LiteralPath "D:\Program Files\Git\cmd\git.exe") {
    $gitExe = "D:\Program Files\Git\cmd\git.exe"
  }
}

$target = "${userName}@${hostName}"
$sshBase = @("ssh", "-p", $port, "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3")
$scpBase = @("scp", "-P", $port)

if (-not [string]::IsNullOrWhiteSpace($sshKey)) {
  $sshBase += @("-i", $sshKey)
  $scpBase += @("-i", $sshKey)
}

$gitBackedActions = @("deploy", "bluegreen-deploy", "start-deploy", "start-bluegreen-deploy", "validate-candidate")
$useGitBackedDeployment = $gitBackedActions -contains $Action

if ([string]::IsNullOrWhiteSpace($opsRepo)) {
  $opsRepo = "git@github.com:zeroliao/zero007-sub2api-ops.git"
}

if ([string]::IsNullOrWhiteSpace($opsRemote)) {
  $opsRemote = "origin"
}

if ([string]::IsNullOrWhiteSpace($opsBranch)) {
  if (-not [string]::IsNullOrWhiteSpace($gitExe)) {
    $detectedBranch = Get-GitOutput @("branch", "--show-current")
  }
  if ([string]::IsNullOrWhiteSpace($detectedBranch)) {
    $opsBranch = "main"
  }
  else {
    $opsBranch = $detectedBranch
  }
}

if ([string]::IsNullOrWhiteSpace($remoteOpsDir)) {
  $remoteOpsDir = "/home/$userName/zero007-sub2api-ops"
}

if ([string]::IsNullOrWhiteSpace($remoteGitSshKey)) {
  $remoteGitSshKey = "/home/$userName/.ssh/zero007_sub2api_ops_deploy"
}

$preserveEnvNames = @("SUB2API_REMOTE_DIR", "SUB2API_HEALTH_URL", "SUB2API_PROJECT_NAME", "SUB2API_RUN_ID", "SUB2API_RUN_LOG_TAIL")

if (-not [string]::IsNullOrWhiteSpace($runId)) {
  [Environment]::SetEnvironmentVariable("SUB2API_RUN_ID", $runId, "Process")
}

if (-not [string]::IsNullOrWhiteSpace($runLogTail)) {
  [Environment]::SetEnvironmentVariable("SUB2API_RUN_LOG_TAIL", $runLogTail, "Process")
}

if ($Action -eq "inspect") {
  $remoteTmpScript = "/tmp/sub2api-remote-ops-$PID.sh"
  Invoke-Checked ($scpBase + @($remoteScript, "${target}:$remoteTmpScript"))
  Invoke-Checked ($sshBase + @($target, "chmod +x '$remoteTmpScript'"))
  $remoteCommand = "SUB2API_REMOTE_DIR='$remoteDir' SUB2API_HEALTH_URL='$healthUrl' bash '$remoteTmpScript' '$Action'; rc=`$?; rm -f '$remoteTmpScript'; exit `$rc"
  Invoke-Checked ($sshBase + @($target, $remoteCommand))
  exit 0
}

if ($Action -eq "diff-server" -or $Action -eq "sync-from-server") {
  $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "sub2api-ops-$PID"
  New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
  $remoteComposeTmp = "/tmp/sub2api-compose-current-$PID.yml"
  $localRemoteCompose = Join-Path $tmpDir "docker-compose.server.yml"

  try {
    Invoke-Checked ($sshBase + @($target, "sudo cp '$remoteDir/docker-compose.yml' '$remoteComposeTmp'; sudo chown `$(id -u):`$(id -g) '$remoteComposeTmp'"))
    Invoke-Checked ($scpBase + @("${target}:$remoteComposeTmp", $localRemoteCompose))
    Invoke-Checked ($sshBase + @($target, "rm -f '$remoteComposeTmp'"))

    if ($Action -eq "sync-from-server") {
      Copy-Item -LiteralPath $localRemoteCompose -Destination $composeFile -Force
      Write-Host "Synced server compose to $composeFile"
      exit 0
    }

    if (-not [string]::IsNullOrWhiteSpace($gitExe)) {
      & $gitExe diff --no-index -- deploy/docker-compose.yml $localRemoteCompose
      $diffExit = $LASTEXITCODE
      if ($diffExit -eq 0) {
        Write-Host "No differences between local deploy/docker-compose.yml and server docker-compose.yml."
      }
      elseif ($diffExit -eq 1) {
        Write-Host "Differences found between local and server compose files."
      }
      else {
        throw "git diff failed with exit code $diffExit"
      }
    }
    else {
      Compare-Object (Get-Content -LiteralPath $composeFile) (Get-Content -LiteralPath $localRemoteCompose) | Out-Host
    }
  }
  finally {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  exit 0
}

if ($useGitBackedDeployment -and $allowDirtyDeploy -ne "true") {
  $commit = Get-RequiredOpsCommit -OpsRemote $opsRemote -OpsBranch $opsBranch
  Write-Host "Using Git-backed ops checkout: $opsRepo @ $commit"
  Invoke-RemoteGitCheckout -RepoUrl $opsRepo -Branch $opsBranch -Commit $commit -RemoteOpsDir $remoteOpsDir -RemoteGitSshKey $remoteGitSshKey

  $candidateCompose = "$remoteOpsDir/deploy/docker-compose.yml"
  $remoteScriptFromGit = "$remoteOpsDir/remote/sub2api-remote-ops.sh"
  $remoteCommand = "sudo --preserve-env=$(($preserveEnvNames + @("SUB2API_CANDIDATE_COMPOSE")) -join ',') SUB2API_REMOTE_DIR='$remoteDir' SUB2API_HEALTH_URL='$healthUrl' SUB2API_PROJECT_NAME='$projectName' SUB2API_CANDIDATE_COMPOSE='$candidateCompose' bash '$remoteScriptFromGit' '$Action'"
  Invoke-Checked ($sshBase + @($target, $remoteCommand))
  exit 0
}

if ($useGitBackedDeployment -and $allowDirtyDeploy -eq "true") {
  Write-Warning "SUB2API_ALLOW_DIRTY_DEPLOY=true is set. Falling back to emergency local upload mode."
}

$remoteTmpScript = "/tmp/sub2api-remote-ops-$PID.sh"
Invoke-Checked ($scpBase + @($remoteScript, "${target}:$remoteTmpScript"))
Invoke-Checked ($sshBase + @($target, "sudo mkdir -p '$remoteDir' '$remoteDir/.ops'; sudo cp '$remoteTmpScript' '$remoteDir/.ops/sub2api-remote-ops.sh'; sudo chmod +x '$remoteDir/.ops/sub2api-remote-ops.sh'; rm -f '$remoteTmpScript'"))

if ($Action -eq "deploy" -or $Action -eq "bluegreen-deploy" -or $Action -eq "start-deploy" -or $Action -eq "start-bluegreen-deploy" -or $Action -eq "validate-candidate") {
  $remoteTmpCompose = "/tmp/sub2api-compose-$PID.yml"
  Invoke-Checked ($scpBase + @($composeFile, "${target}:$remoteTmpCompose"))
  Invoke-Checked ($sshBase + @($target, "sudo cp '$remoteTmpCompose' '$remoteDir/.ops/docker-compose.candidate.yml'; rm -f '$remoteTmpCompose'"))
  $remoteCommand = "sudo --preserve-env=$(($preserveEnvNames + @("SUB2API_CANDIDATE_COMPOSE")) -join ',') SUB2API_REMOTE_DIR='$remoteDir' SUB2API_HEALTH_URL='$healthUrl' SUB2API_PROJECT_NAME='$projectName' SUB2API_CANDIDATE_COMPOSE='$remoteDir/.ops/docker-compose.candidate.yml' bash '$remoteDir/.ops/sub2api-remote-ops.sh' '$Action'"
}
else {
  $remoteCommand = "sudo --preserve-env=$($preserveEnvNames -join ',') SUB2API_REMOTE_DIR='$remoteDir' SUB2API_HEALTH_URL='$healthUrl' SUB2API_PROJECT_NAME='$projectName' bash '$remoteDir/.ops/sub2api-remote-ops.sh' '$Action'"
}

Invoke-Checked ($sshBase + @($target, $remoteCommand))
