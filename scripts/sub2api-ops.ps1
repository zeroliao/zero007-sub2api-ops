param(
  [ValidateSet("inspect", "doctor", "validate", "backup", "deploy", "rollback", "status", "logs")]
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
  Write-Host ">> $($Command -join ' ')"
  & $Command[0] @($Command | Select-Object -Skip 1)
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed with exit code ${LASTEXITCODE}: $($Command -join ' ')"
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

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$remoteScript = Join-Path $repoRoot "remote/sub2api-remote-ops.sh"
$composeFile = Join-Path $repoRoot "deploy/docker-compose.yml"

if (-not (Test-Path -LiteralPath $remoteScript)) {
  throw "Missing remote script: $remoteScript"
}

if (-not (Test-Path -LiteralPath $composeFile)) {
  throw "Missing compose file: $composeFile"
}

$target = "${userName}@${hostName}"
$sshBase = @("ssh", "-p", $port, "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3")
$scpBase = @("scp", "-P", $port)

if (-not [string]::IsNullOrWhiteSpace($sshKey)) {
  $sshBase += @("-i", $sshKey)
  $scpBase += @("-i", $sshKey)
}

if ($Action -eq "inspect") {
  $remoteTmpScript = "/tmp/sub2api-remote-ops-$PID.sh"
  Invoke-Checked ($scpBase + @($remoteScript, "${target}:$remoteTmpScript"))
  Invoke-Checked ($sshBase + @($target, "chmod +x '$remoteTmpScript'"))
  $remoteCommand = "SUB2API_REMOTE_DIR='$remoteDir' SUB2API_HEALTH_URL='$healthUrl' bash '$remoteTmpScript' '$Action'; rc=`$?; rm -f '$remoteTmpScript'; exit `$rc"
  Invoke-Checked ($sshBase + @($target, $remoteCommand))
  exit 0
}

$remoteTmpScript = "/tmp/sub2api-remote-ops-$PID.sh"
Invoke-Checked ($scpBase + @($remoteScript, "${target}:$remoteTmpScript"))
Invoke-Checked ($sshBase + @($target, "sudo mkdir -p '$remoteDir' '$remoteDir/.ops'; sudo cp '$remoteTmpScript' '$remoteDir/.ops/sub2api-remote-ops.sh'; sudo chmod +x '$remoteDir/.ops/sub2api-remote-ops.sh'; rm -f '$remoteTmpScript'"))

if ($Action -eq "deploy") {
  $remoteTmpCompose = "/tmp/sub2api-compose-$PID.yml"
  Invoke-Checked ($scpBase + @($composeFile, "${target}:$remoteTmpCompose"))
  Invoke-Checked ($sshBase + @($target, "sudo cp '$remoteTmpCompose' '$remoteDir/.ops/docker-compose.candidate.yml'; rm -f '$remoteTmpCompose'"))
  $remoteCommand = "sudo --preserve-env=SUB2API_REMOTE_DIR,SUB2API_HEALTH_URL,SUB2API_CANDIDATE_COMPOSE,SUB2API_PROJECT_NAME SUB2API_REMOTE_DIR='$remoteDir' SUB2API_HEALTH_URL='$healthUrl' SUB2API_PROJECT_NAME='$projectName' SUB2API_CANDIDATE_COMPOSE='$remoteDir/.ops/docker-compose.candidate.yml' bash '$remoteDir/.ops/sub2api-remote-ops.sh' '$Action'"
}
else {
  $remoteCommand = "sudo --preserve-env=SUB2API_REMOTE_DIR,SUB2API_HEALTH_URL,SUB2API_PROJECT_NAME SUB2API_REMOTE_DIR='$remoteDir' SUB2API_HEALTH_URL='$healthUrl' SUB2API_PROJECT_NAME='$projectName' bash '$remoteDir/.ops/sub2api-remote-ops.sh' '$Action'"
}

Invoke-Checked ($sshBase + @($target, $remoteCommand))
