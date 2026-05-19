#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-doctor}"
DEPLOY_DIR="${SUB2API_REMOTE_DIR:-/srv/sub2api-deploy}"
HEALTH_URL="${SUB2API_HEALTH_URL:-http://127.0.0.1:8080/health}"
COMPOSE_FILE="${SUB2API_COMPOSE_FILE:-docker-compose.yml}"
PROJECT_NAME="${SUB2API_PROJECT_NAME:-sub2api}"
LOCK_DIR="/tmp/${PROJECT_NAME}-deploy.lock"
CANDIDATE_COMPOSE="${SUB2API_CANDIDATE_COMPOSE:-}"

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
  else
    fail "Missing Docker Compose. Install Docker Compose v2 or docker-compose v1."
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

load_env() {
  cd "$DEPLOY_DIR"
  [ -f ".env" ] || fail "Missing $DEPLOY_DIR/.env. Create it from the server's current production settings first."
  set -a
  # shellcheck disable=SC1091
  . ".env"
  set +a
}

validate_env() {
  local missing=0
  local required=(POSTGRES_PASSWORD JWT_SECRET TOTP_ENCRYPTION_KEY)

  for key in "${required[@]}"; do
    if [ -z "${!key:-}" ]; then
      log "Missing required .env value: $key"
      missing=1
    fi
  done

  if [ "${POSTGRES_PASSWORD:-}" = "change_this_secure_password" ]; then
    log "POSTGRES_PASSWORD still uses the example placeholder."
    missing=1
  fi

  case "${SERVER_PORT:-8080}" in
    ''|*[!0-9]*) log "SERVER_PORT must be numeric."; missing=1 ;;
  esac

  [ "$missing" -eq 0 ] || fail "Environment validation failed."
}

validate_compose() {
  load_env
  validate_env
  compose config >/dev/null
  log "Compose and environment validation passed."
}

validate_candidate_compose() {
  load_env
  validate_env
  [ -f "$CANDIDATE_COMPOSE" ] || fail "Candidate compose file was not found: $CANDIDATE_COMPOSE"
  docker compose -p "$PROJECT_NAME" -f "$CANDIDATE_COMPOSE" config >/dev/null
  log "Candidate compose validation passed: $CANDIDATE_COMPOSE"
}

acquire_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    fail "Another deployment is already running: $LOCK_DIR"
  fi
  trap 'rm -rf "$LOCK_DIR"' EXIT
}

prepare_dirs() {
  mkdir -p "$DEPLOY_DIR" "$DEPLOY_DIR/data" "$DEPLOY_DIR/postgres_data" "$DEPLOY_DIR/redis_data" "$DEPLOY_DIR/backups"
}

backup() {
  load_env
  local stamp backup_dir
  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  backup_dir="$DEPLOY_DIR/backups/$stamp"
  mkdir -p "$backup_dir"

  log "Creating backup at $backup_dir"
  cp -a "$DEPLOY_DIR/.env" "$backup_dir/.env"
  [ -f "$DEPLOY_DIR/$COMPOSE_FILE" ] && cp -a "$DEPLOY_DIR/$COMPOSE_FILE" "$backup_dir/$COMPOSE_FILE"
  [ -f "$DEPLOY_DIR/config.yaml" ] && cp -a "$DEPLOY_DIR/config.yaml" "$backup_dir/config.yaml"

  if compose ps --status running postgres >/dev/null 2>&1; then
    log "Creating PostgreSQL dump."
    compose exec -T postgres pg_dump -U "${POSTGRES_USER:-sub2api}" -d "${POSTGRES_DB:-sub2api}" > "$backup_dir/postgres.sql"
  else
    log "PostgreSQL is not running; skipping pg_dump."
  fi

  if command -v tar >/dev/null 2>&1; then
    tar -C "$DEPLOY_DIR" -czf "$backup_dir/config-and-app-data.tar.gz" .env "$COMPOSE_FILE" data 2>/dev/null || true
  fi

  ln -sfn "$backup_dir" "$DEPLOY_DIR/backups/latest"
  log "Backup completed."
}

wait_for_health() {
  local max_attempts="${1:-30}"
  local sleep_seconds="${2:-5}"
  local i

  for i in $(seq 1 "$max_attempts"); do
    if curl -fsS --max-time 10 "$HEALTH_URL" >/dev/null 2>&1; then
      log "Health check passed: $HEALTH_URL"
      return 0
    fi
    log "Health check attempt $i/$max_attempts failed; waiting ${sleep_seconds}s."
    sleep "$sleep_seconds"
  done

  return 1
}

check_logs() {
  local bad
  bad="$(compose logs --tail=160 sub2api 2>/dev/null | grep -Ei 'panic|fatal|database.*failed|connection refused|migration.*failed' || true)"
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad"
    return 1
  fi
  return 0
}

deploy() {
  acquire_lock
  prepare_dirs

  if [ -n "$CANDIDATE_COMPOSE" ]; then
    validate_candidate_compose
  else
    validate_compose
  fi

  backup

  if [ -n "$CANDIDATE_COMPOSE" ]; then
    log "Installing candidate compose file."
    cp -a "$CANDIDATE_COMPOSE" "$DEPLOY_DIR/$COMPOSE_FILE"
    validate_compose
  fi

  log "Pulling latest images."
  compose pull

  log "Starting services."
  compose up -d

  if ! wait_for_health 36 5 || ! check_logs; then
    log "Verification failed; starting rollback."
    rollback
    fail "Deployment failed and rollback was attempted."
  fi

  compose ps
  log "Deployment completed successfully."
}

rollback() {
  load_env
  local latest
  latest="$(readlink -f "$DEPLOY_DIR/backups/latest" 2>/dev/null || true)"
  [ -n "$latest" ] && [ -d "$latest" ] || fail "No latest backup found."

  log "Rolling back using $latest"
  cp -a "$latest/.env" "$DEPLOY_DIR/.env"
  [ -f "$latest/$COMPOSE_FILE" ] && cp -a "$latest/$COMPOSE_FILE" "$DEPLOY_DIR/$COMPOSE_FILE"
  [ -f "$latest/config.yaml" ] && cp -a "$latest/config.yaml" "$DEPLOY_DIR/config.yaml"

  load_env
  compose up -d
  wait_for_health 24 5 || fail "Rollback started, but health check still failed."
  log "Rollback completed."
}

doctor() {
  require_cmd docker
  require_cmd curl
  compose version >/dev/null
  prepare_dirs
  validate_compose
  compose ps || true
  log "Doctor check completed."
}

status() {
  load_env
  compose ps
  wait_for_health 1 1 || true
}

logs() {
  load_env
  compose logs --tail="${SUB2API_LOG_TAIL:-200}" sub2api
}

inspect() {
  log "Host: $(hostname)"
  log "User: $(id -un)"
  log "Kernel: $(uname -a)"

  if command -v docker >/dev/null 2>&1; then
    docker --version
    if docker compose version >/dev/null 2>&1; then
      docker compose version
    elif command -v docker-compose >/dev/null 2>&1; then
      docker-compose --version
    else
      log "Docker is installed, but Docker Compose was not found."
    fi

    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' || true
  else
    log "Docker was not found."
  fi

  log "Checking common deployment directories."
  for dir in "$DEPLOY_DIR" /opt/sub2api /srv/sub2api /root/sub2api "$HOME/sub2api"; do
    if [ -e "$dir" ]; then
      ls -la "$dir"
      [ -f "$dir/docker-compose.yml" ] && log "Found compose file: $dir/docker-compose.yml"
      [ -f "$dir/.env" ] && log "Found env file: $dir/.env"
    fi
  done
}

case "$ACTION" in
  inspect) inspect ;;
  doctor) doctor ;;
  validate) validate_compose ;;
  backup) backup ;;
  deploy) deploy ;;
  rollback) rollback ;;
  status) status ;;
  logs) logs ;;
  *) fail "Unknown action: $ACTION" ;;
esac
