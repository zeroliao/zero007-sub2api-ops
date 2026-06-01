#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-doctor}"
DEPLOY_DIR="${SUB2API_REMOTE_DIR:-/srv/sub2api-deploy}"
HEALTH_URL="${SUB2API_HEALTH_URL:-http://127.0.0.1:8080/health}"
COMPOSE_FILE="${SUB2API_COMPOSE_FILE:-docker-compose.yml}"
PROJECT_NAME="${SUB2API_PROJECT_NAME:-sub2api}"
LOCK_DIR="/tmp/${PROJECT_NAME}-deploy.lock"
CANDIDATE_COMPOSE="${SUB2API_CANDIDATE_COMPOSE:-}"
MIGRATIONS_DIR="${SUB2API_MIGRATIONS_DIR:-}"
ACTIVE_SLOT_FILE="$DEPLOY_DIR/.ops/active-slot"
BACKUP_RETENTION="${SUB2API_BACKUP_RETENTION:-3}"
RUNS_DIR="$DEPLOY_DIR/.ops/deploy-runs"
RUN_RETENTION="${SUB2API_RUN_RETENTION:-20}"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
DEFAULT_UPSTREAM_HOSTS="api.openai.com,api.anthropic.com,api.kimi.com,open.bigmodel.cn,api.minimaxi.com,generativelanguage.googleapis.com,cloudcode-pa.googleapis.com,oauth2.googleapis.com,www.googleapis.com,*.openai.azure.com"
DEFAULT_PRICING_HOSTS="raw.githubusercontent.com"
DEFAULT_CRS_HOSTS=""

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\"'\"'/g")"
}

compose_file() {
  local file="$1"
  shift

  if docker compose version >/dev/null 2>&1; then
    docker compose -p "$PROJECT_NAME" -f "$file" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose -p "$PROJECT_NAME" -f "$file" "$@"
  else
    fail "Missing Docker Compose. Install Docker Compose v2 or docker-compose v1."
  fi
}

compose() {
  compose_file "$COMPOSE_FILE" "$@"
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
  local required=(POSTGRES_PASSWORD JWT_SECRET TOTP_ENCRYPTION_KEY REDIS_PASSWORD)

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

  if [ "${REDIS_PASSWORD:-}" = "change_this_secure_password" ]; then
    log "REDIS_PASSWORD still uses the example placeholder."
    missing=1
  fi

  case "${SERVER_PORT:-8080}" in
    ''|*[!0-9]*) log "SERVER_PORT must be numeric."; missing=1 ;;
  esac

  case "$BACKUP_RETENTION" in
    ''|*[!0-9]*) log "SUB2API_BACKUP_RETENTION must be numeric."; missing=1 ;;
    *) [ "$BACKUP_RETENTION" -ge 1 ] || { log "SUB2API_BACKUP_RETENTION must be at least 1."; missing=1; } ;;
  esac

  if [ "${BIND_HOST:-127.0.0.1}" = "0.0.0.0" ] && [ "${SUB2API_ALLOW_PUBLIC_BIND:-false}" != "true" ]; then
    log "BIND_HOST=0.0.0.0 requires SUB2API_ALLOW_PUBLIC_BIND=true."
    missing=1
  fi

  if ! find "$DEPLOY_DIR/postgres_data" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
    if [ -z "${ADMIN_PASSWORD:-}" ]; then
      log "ADMIN_PASSWORD is required for first deployment when postgres_data is empty."
      missing=1
    fi
  fi

  [ "$missing" -eq 0 ] || fail "Environment validation failed."
}

prune_backups() {
  local keep="${1:-$BACKUP_RETENTION}"
  local backups_dir="$DEPLOY_DIR/backups"
  local backup_dir real_backups_dir real_backup_dir
  local -a backup_dirs=()

  [ -d "$backups_dir" ] || return 0
  real_backups_dir="$(readlink -f "$backups_dir")"
  [ -n "$real_backups_dir" ] || fail "Unable to resolve backups directory: $backups_dir"

  while IFS= read -r backup_dir; do
    backup_dirs+=("$backup_dir")
  done < <(find "$backups_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)

  while [ "${#backup_dirs[@]}" -gt "$keep" ]; do
    backup_dir="${backup_dirs[0]}"
    backup_dirs=("${backup_dirs[@]:1}")
    real_backup_dir="$(readlink -f "$backups_dir/$backup_dir")"

    case "$real_backup_dir" in
      "$real_backups_dir"/*) ;;
      *) fail "Refusing to prune backup outside backups directory: $real_backup_dir" ;;
    esac

    log "Pruning old backup: $real_backup_dir"
    rm -rf "$real_backup_dir"
  done
}

validate_image_pins() {
  local file="$1"
  local missing=0
  local config service image
  local found_caddy=0
  local found_blue=0
  local found_green=0
  local found_postgres=0
  local found_redis=0
  local found_sing_box=0

  config="$(compose_file "$file" --profile bluegreen config)"
  while IFS='|' read -r service image; do
    case "$service" in
      caddy) found_caddy=1 ;;
      sub2api-blue) found_blue=1 ;;
      sub2api-green) found_green=1 ;;
      postgres) found_postgres=1 ;;
      redis) found_redis=1 ;;
      sing-box) found_sing_box=1 ;;
      clash-node) ;;
      *) continue ;;
    esac

    if [ "${image#*@sha256:}" = "$image" ]; then
      log "Service '$service' image is not pinned by digest: $image"
      missing=1
    fi
  done < <(
    printf '%s\n' "$config" | awk '
      /^[[:space:]]{2}[A-Za-z0-9_.-]+:$/ {
        service=$1
        sub(":", "", service)
      }
      /^[[:space:]]{4}image:/ {
        print service "|" $2
      }
    '
  )

  [ "$found_caddy" -eq 1 ] || { log "Missing compose service image: caddy"; missing=1; }
  [ "$found_blue" -eq 1 ] || { log "Missing compose service image: sub2api-blue"; missing=1; }
  [ "$found_green" -eq 1 ] || { log "Missing compose service image: sub2api-green"; missing=1; }
  [ "$found_postgres" -eq 1 ] || { log "Missing compose service image: postgres"; missing=1; }
  [ "$found_redis" -eq 1 ] || { log "Missing compose service image: redis"; missing=1; }
  [ "$found_sing_box" -eq 1 ] || { log "Missing compose service image: sing-box"; missing=1; }

  [ "$missing" -eq 0 ] || fail "Compose image pin validation failed."
}

compose_service_image() {
  local file="$1"
  local target_service="$2"

  compose_file "$file" config | awk -v target="$target_service" '
    /^[[:space:]]{2}[A-Za-z0-9_.-]+:$/ {
      service=$1
      sub(":", "", service)
    }
    /^[[:space:]]{4}image:/ && service == target {
      print $2
      exit
    }
  '
}

applied_migrations_file() {
  local out="$1"
  : > "$out"

  if compose ps --status running postgres >/dev/null 2>&1; then
    compose exec -T postgres psql -qAt -U "${POSTGRES_USER:-sub2api}" -d "${POSTGRES_DB:-sub2api}" -v ON_ERROR_STOP=1 \
      -c "select filename from schema_migrations order by filename" > "$out" 2>/dev/null || true
  fi
}

scan_migration_dir() {
  local scan_dir="$1"
  local applied_file="$2"
  local findings_file="$3"
  local file name

  while IFS= read -r -d '' file; do
    name="$(basename "$file")"
    if grep -Fxq "$name" "$applied_file"; then
      continue
    fi

    grep -Ein '\bDROP[[:space:]]+TABLE\b|\bDROP[[:space:]]+COLUMN\b|\bDELETE[[:space:]]+FROM\b|\bALTER[[:space:]]+TYPE\b|\bALTER[[:space:]]+TABLE\b.*\bALTER[[:space:]]+COLUMN\b.*\bTYPE\b' "$file" >> "$findings_file" || true
  done < <(find "$scan_dir" -type f -name '*.sql' -print0 | sort -z)
}

require_destructive_migration_confirmation() {
  local findings_file="$1"

  if [ ! -s "$findings_file" ]; then
    return 0
  fi

  log "Potential destructive unapplied migrations detected:"
  cat "$findings_file"

  if [ "${SUB2API_DESTRUCTIVE_MIGRATION_CONFIRMED:-false}" != "true" ] || [ -z "${SUB2API_DESTRUCTIVE_MIGRATION_NOTE:-}" ]; then
    log "Destructive migrations require SUB2API_DESTRUCTIVE_MIGRATION_CONFIRMED=true and a non-empty SUB2API_DESTRUCTIVE_MIGRATION_NOTE."
    return 1
  fi

  log "Destructive migration confirmation: $SUB2API_DESTRUCTIVE_MIGRATION_NOTE"
  return 0
}

validate_destructive_migrations() {
  local scan_dir="${MIGRATIONS_DIR:-$DEPLOY_DIR/.ops/migrations}"
  local applied_file findings_file

  if [ ! -d "$scan_dir" ]; then
    log "Migration source directory not found; skipping source migration scan: $scan_dir"
    return 0
  fi

  applied_file="$(mktemp)"
  findings_file="$(mktemp)"
  applied_migrations_file "$applied_file"
  scan_migration_dir "$scan_dir" "$applied_file" "$findings_file"
  if ! require_destructive_migration_confirmation "$findings_file"; then
    rm -f "$applied_file" "$findings_file"
    fail "Destructive migration validation failed."
  fi
  rm -f "$applied_file" "$findings_file"

  log "Destructive migration scan passed."
}

validate_image_migrations() {
  local file="$1"
  local image cid tmp extracted applied_file findings_file found=0
  image="$(compose_service_image "$file" sub2api-blue)"

  [ -n "$image" ] || return 0
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    log "Sub2API image is not available locally; skipping image migration scan: $image"
    return 0
  fi

  cid="$(docker create "$image" 2>/dev/null || true)"
  if [ -z "$cid" ]; then
    log "Unable to create temporary container for migration scan; skipping image scan."
    return 0
  fi

  tmp="$(mktemp -d)"
  applied_file="$(mktemp)"
  findings_file="$(mktemp)"
  applied_migrations_file "$applied_file"

  for image_path in /app/migrations /app/backend/migrations /migrations; do
    extracted="$tmp/$(basename "$image_path")"
    if docker cp "$cid:$image_path" "$extracted" >/dev/null 2>&1; then
      found=1
      scan_migration_dir "$extracted" "$applied_file" "$findings_file"
    fi
  done

  if [ "$found" -eq 0 ]; then
    log "No migration SQL directory found inside image; image migration scan skipped."
    docker rm "$cid" >/dev/null 2>&1 || true
    rm -rf "$tmp" "$applied_file" "$findings_file"
    return 0
  fi

  if ! require_destructive_migration_confirmation "$findings_file"; then
    docker rm "$cid" >/dev/null 2>&1 || true
    rm -rf "$tmp" "$applied_file" "$findings_file"
    fail "Destructive migration validation failed."
  fi
  docker rm "$cid" >/dev/null 2>&1 || true
  rm -rf "$tmp" "$applied_file" "$findings_file"
  log "Image migration scan passed."
}

validate_compose() {
  load_env
  prepare_dirs
  validate_env
  compose config >/dev/null
  validate_image_pins "$COMPOSE_FILE"
  validate_destructive_migrations
  log "Compose and environment validation passed."
}

validate_candidate_compose() {
  load_env
  prepare_dirs
  validate_env
  [ -f "$CANDIDATE_COMPOSE" ] || fail "Candidate compose file was not found: $CANDIDATE_COMPOSE"
  compose_file "$CANDIDATE_COMPOSE" config >/dev/null
  validate_image_pins "$CANDIDATE_COMPOSE"
  validate_destructive_migrations
  log "Candidate compose validation passed: $CANDIDATE_COMPOSE"
}

acquire_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    fail "Another deployment is already running: $LOCK_DIR"
  fi
  trap 'rm -rf "$LOCK_DIR"' EXIT
}

prepare_dirs() {
  mkdir -p "$DEPLOY_DIR" "$DEPLOY_DIR/data" "$DEPLOY_DIR/postgres_data" "$DEPLOY_DIR/redis_data" "$DEPLOY_DIR/backups" "$DEPLOY_DIR/caddy" "$DEPLOY_DIR/caddy_data" "$DEPLOY_DIR/caddy_config" "$DEPLOY_DIR/.ops" "$RUNS_DIR"
  if [ ! -f "$DEPLOY_DIR/caddy/Caddyfile" ]; then
    write_caddyfile blue
  fi
  if [ ! -f "$ACTIVE_SLOT_FILE" ]; then
    printf 'blue\n' > "$ACTIVE_SLOT_FILE"
  fi
}

slot_service() {
  case "$1" in
    blue) printf 'sub2api-blue' ;;
    green) printf 'sub2api-green' ;;
    *) fail "Invalid slot: $1" ;;
  esac
}

active_slot() {
  local slot
  slot="$(cat "$ACTIVE_SLOT_FILE" 2>/dev/null || true)"
  case "$slot" in
    blue|green) printf '%s\n' "$slot" ;;
    '') printf 'blue\n' ;;
    *) fail "Invalid active slot file value: $slot" ;;
  esac
}

inactive_slot() {
  case "$(active_slot)" in
    blue) printf 'green\n' ;;
    green) printf 'blue\n' ;;
  esac
}

yaml_single_quote() {
  printf '%s' "$1" | sed "s/'/''/g"
}

write_caddyfile() {
  local slot="$1"
  local service subscription_path mobile_subscription_path subscription_file mobile_subscription_file node_server node_port node_method node_password
  service="$(slot_service "$slot")"
  mkdir -p "$DEPLOY_DIR/caddy"

  if [ -n "${CLASH_SUBSCRIPTION_TOKEN:-}" ]; then
    printf '%s' "$CLASH_SUBSCRIPTION_TOKEN" | grep -Eq '^[A-Za-z0-9_-]{16,}$' \
      || fail "CLASH_SUBSCRIPTION_TOKEN must be at least 16 chars and contain only letters, numbers, '_' or '-'."
    [ -n "${CLASH_NODE_PASSWORD:-}" ] || fail "CLASH_NODE_PASSWORD is required when CLASH_SUBSCRIPTION_TOKEN is set."

    subscription_path="/clash/${CLASH_SUBSCRIPTION_TOKEN}.yaml"
    mobile_subscription_path="/clash/${CLASH_SUBSCRIPTION_TOKEN}.mobile.yaml"
    node_server="${CLASH_NODE_SERVER:-api.zero007.chat}"
    node_port="${CLASH_NODE_PORT:-8388}"
    node_method="${CLASH_NODE_METHOD:-aes-256-gcm}"
    node_password="$(yaml_single_quote "$CLASH_NODE_PASSWORD")"
    mkdir -p "$DEPLOY_DIR/caddy/subscriptions"
    subscription_file="$DEPLOY_DIR/caddy/subscriptions/${CLASH_SUBSCRIPTION_TOKEN}.yaml"
    mobile_subscription_file="$DEPLOY_DIR/caddy/subscriptions/${CLASH_SUBSCRIPTION_TOKEN}.mobile.yaml"
    find "$DEPLOY_DIR/caddy/subscriptions" -maxdepth 1 -type f -name '*.yaml' ! -name "${CLASH_SUBSCRIPTION_TOKEN}.yaml" ! -name "${CLASH_SUBSCRIPTION_TOKEN}.mobile.yaml" -delete

    cat > "$subscription_file" <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: false
unified-delay: true
tcp-concurrent: true
global-client-fingerprint: chrome

profile:
  store-selected: true
  store-fake-ip: true

dns:
  enable: true
  listen: 127.0.0.1:1053
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "*.lan"
    - "*.local"
    - localhost.ptlogin2.qq.com
    - localhost.sec.qq.com
    - localhost.work.weixin.qq.com
    - geosite:private
    - geosite:cn
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
  fallback:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query
  fallback-filter:
    geoip: true
    geoip-code: CN
    geosite:
      - geolocation-!cn

proxies:
  - name: zero007-sub2api-ss
    type: ss
    server: $node_server
    port: $node_port
    cipher: $node_method
    password: '$node_password'
    udp: true

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - zero007-sub2api-ss
      - DIRECT
  - name: Final
    type: select
    proxies:
      - PROXY
      - DIRECT

rules:
  - DOMAIN,localhost,DIRECT
  - DOMAIN-SUFFIX,localhost,DIRECT
  - DOMAIN-SUFFIX,local,DIRECT
  - DOMAIN-SUFFIX,lan,DIRECT
  - DOMAIN-SUFFIX,invalid,DIRECT
  - IP-CIDR,0.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,198.18.0.0/15,DIRECT,no-resolve
  - IP-CIDR,224.0.0.0/4,DIRECT,no-resolve
  - IP-CIDR,240.0.0.0/4,DIRECT,no-resolve
  - IP-CIDR6,::1/128,DIRECT,no-resolve
  - IP-CIDR6,fc00::/7,DIRECT,no-resolve
  - IP-CIDR6,fe80::/10,DIRECT,no-resolve
  - GEOSITE,private,DIRECT
  - GEOSITE,cn,DIRECT
  - DOMAIN-SUFFIX,cn,DIRECT
  - GEOSITE,geolocation-!cn,PROXY
  - GEOIP,CN,DIRECT,no-resolve
  - MATCH,Final

EOF
    chmod 0644 "$subscription_file"

    cat > "$mobile_subscription_file" <<EOF
mode: rule
log-level: info
ipv6: false
allow-lan: false

proxies:
  - name: zero007-sub2api-ss
    type: ss
    server: $node_server
    port: $node_port
    cipher: $node_method
    password: '$node_password'
    udp: true

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - zero007-sub2api-ss
      - DIRECT

rules:
  - DOMAIN-SUFFIX,local,DIRECT
  - DOMAIN-SUFFIX,lan,DIRECT
  - DOMAIN-SUFFIX,localhost,DIRECT
  - DOMAIN,localhost,DIRECT
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,224.0.0.0/4,DIRECT,no-resolve
  - IP-CIDR6,::1/128,DIRECT,no-resolve
  - IP-CIDR6,fc00::/7,DIRECT,no-resolve
  - IP-CIDR6,fe80::/10,DIRECT,no-resolve
  - DOMAIN-SUFFIX,cn,DIRECT
  - DOMAIN-SUFFIX,baidu.com,DIRECT
  - DOMAIN-SUFFIX,bilibili.com,DIRECT
  - DOMAIN-SUFFIX,qq.com,DIRECT
  - DOMAIN-SUFFIX,wechat.com,DIRECT
  - DOMAIN-SUFFIX,aliyun.com,DIRECT
  - DOMAIN-SUFFIX,alipay.com,DIRECT
  - DOMAIN-SUFFIX,taobao.com,DIRECT
  - DOMAIN-SUFFIX,jd.com,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF
    chmod 0644 "$mobile_subscription_file"

    cat > "$DEPLOY_DIR/caddy/Caddyfile" <<EOF
:8080 {
	handle $subscription_path {
		root * /srv/clash-subscriptions
		rewrite * /${CLASH_SUBSCRIPTION_TOKEN}.yaml
		header Content-Type "text/yaml; charset=utf-8"
		file_server
	}

	handle $mobile_subscription_path {
		root * /srv/clash-subscriptions
		rewrite * /${CLASH_SUBSCRIPTION_TOKEN}.mobile.yaml
		header Content-Type "text/yaml; charset=utf-8"
		file_server
	}

	handle {
		reverse_proxy $service:8080
	}
}
EOF
    return
  fi

  cat > "$DEPLOY_DIR/caddy/Caddyfile" <<EOF
:8080 {
	reverse_proxy $service:8080
}
EOF
}

reload_caddy() {
  local caddy_container
  compose up -d caddy
  caddy_container="$(compose ps -q --status running caddy 2>/dev/null || true)"
  if [ -n "$caddy_container" ]; then
    compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile
  fi
}

stop_legacy_app_container() {
  local cid
  cid="$(docker ps -q --filter 'name=^/sub2api$' 2>/dev/null || true)"
  if [ -n "$cid" ]; then
    log "Stopping legacy single-container app before Caddy binds the public port: sub2api"
    docker stop "$cid" >/dev/null
  fi
}

switch_slot() {
  local target="${1:-${SUB2API_TARGET_SLOT:-}}"
  [ -n "$target" ] || target="$(inactive_slot)"
  slot_service "$target" >/dev/null

  log "Switching active slot to $target."
  compose --profile bluegreen up -d "$(slot_service "$target")"
  wait_for_service_health "$(slot_service "$target")" 36 5
  write_caddyfile "$target"
  stop_legacy_app_container
  reload_caddy
  printf '%s\n' "$target" > "$ACTIVE_SLOT_FILE"
  wait_for_health 12 5 || fail "Caddy switched to $target, but external health check failed."
  log "Active slot is now $target."
}

backup() {
  load_env
  prepare_dirs
  local stamp backup_dir
  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  backup_dir="$DEPLOY_DIR/backups/$stamp"
  mkdir -p "$backup_dir"

  log "Creating backup at $backup_dir"
  cp -a "$DEPLOY_DIR/.env" "$backup_dir/.env"
  [ -f "$DEPLOY_DIR/$COMPOSE_FILE" ] && cp -a "$DEPLOY_DIR/$COMPOSE_FILE" "$backup_dir/$COMPOSE_FILE"
  [ -f "$DEPLOY_DIR/config.yaml" ] && cp -a "$DEPLOY_DIR/config.yaml" "$backup_dir/config.yaml"
  [ -f "$DEPLOY_DIR/caddy/Caddyfile" ] && mkdir -p "$backup_dir/caddy" && cp -a "$DEPLOY_DIR/caddy/Caddyfile" "$backup_dir/caddy/Caddyfile"
  [ -f "$ACTIVE_SLOT_FILE" ] && mkdir -p "$backup_dir/.ops" && cp -a "$ACTIVE_SLOT_FILE" "$backup_dir/.ops/active-slot"

  if compose ps --status running postgres >/dev/null 2>&1; then
    log "Creating PostgreSQL dump."
    compose exec -T postgres pg_dump -U "${POSTGRES_USER:-sub2api}" -d "${POSTGRES_DB:-sub2api}" > "$backup_dir/postgres.sql"
  else
    log "PostgreSQL is not running; skipping pg_dump."
  fi

  if command -v tar >/dev/null 2>&1; then
    tar -C "$DEPLOY_DIR" -czf "$backup_dir/config-and-app-data.tar.gz" .env "$COMPOSE_FILE" caddy .ops/active-slot data 2>/dev/null || true
  fi

  ln -sfn "$backup_dir" "$DEPLOY_DIR/backups/latest"
  prune_backups "$BACKUP_RETENTION"
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

wait_for_service_health() {
  local service="$1"
  local max_attempts="${2:-30}"
  local sleep_seconds="${3:-5}"
  local i status container_id

  for i in $(seq 1 "$max_attempts"); do
    container_id="$(compose ps -q "$service" 2>/dev/null || true)"
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
    if [ "$status" = "healthy" ] || [ "$status" = "running" ]; then
      log "Service health passed: $service ($status)"
      return 0
    fi
    log "Service health attempt $i/$max_attempts failed for $service: ${status:-unknown}; waiting ${sleep_seconds}s."
    sleep "$sleep_seconds"
  done

  return 1
}

check_service_logs() {
  local service="$1"
  local bad pattern
  case "$service" in
    sing-box|clash-node)
      pattern='panic|fatal|migration.*failed'
      ;;
    *)
      pattern='panic|fatal|database.*failed|connection refused|migration.*failed'
      ;;
  esac

  bad="$(compose logs --tail=160 "$service" 2>/dev/null | grep -Ei "$pattern" || true)"
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad"
    return 1
  fi
  return 0
}

compose_has_service() {
  local service="$1"
  compose --profile bluegreen config --services | grep -qx "$service"
}

ensure_sidecar_services() {
  local service
  for service in sing-box clash-node; do
    if compose_has_service "$service"; then
      log "Ensuring sidecar service: $service"
      compose --profile bluegreen up -d "$service"
      wait_for_service_health "$service" 12 3 || fail "Sidecar service failed health check: $service"
      check_service_logs "$service" || fail "Sidecar logs contain fatal patterns: $service"
    fi
  done
}

check_logs() {
  check_service_logs "$(slot_service "$(active_slot)")"
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

  stop_legacy_app_container

  log "Pulling latest images."
  compose pull
  validate_image_migrations "$COMPOSE_FILE"

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

bluegreen_deploy() {
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

  stop_legacy_app_container

  log "Pulling latest images."
  compose --profile bluegreen pull
  validate_image_migrations "$COMPOSE_FILE"

  local target target_service previous
  previous="$(active_slot)"
  target="$(inactive_slot)"
  target_service="$(slot_service "$target")"

  ensure_sidecar_services

  log "Starting inactive slot: $target_service"
  compose --profile bluegreen up -d postgres redis "$target_service"
  wait_for_service_health "$target_service" 36 5 || fail "Inactive slot failed health check: $target_service"
  check_service_logs "$target_service" || fail "Inactive slot logs contain fatal patterns: $target_service"

  log "Switching Caddy traffic from $previous to $target."
  write_caddyfile "$target"
  compose --profile bluegreen up -d caddy
  reload_caddy
  printf '%s\n' "$target" > "$ACTIVE_SLOT_FILE"

  if ! wait_for_health 24 5 || ! check_service_logs "$target_service"; then
    log "Blue-green verification failed; switching traffic back to $previous."
    write_caddyfile "$previous"
    compose --profile bluegreen up -d "$(slot_service "$previous")"
    wait_for_service_health "$(slot_service "$previous")" 24 5 || true
    reload_caddy
    printf '%s\n' "$previous" > "$ACTIVE_SLOT_FILE"
    fail "Blue-green deployment failed and traffic was switched back."
  fi

  log "Stopping previous slot to avoid duplicate background jobs: $(slot_service "$previous")"
  compose stop "$(slot_service "$previous")" || true
  compose ps
  log "Blue-green deployment completed successfully. Active slot: $target."
}

prune_runs() {
  local keep="${1:-$RUN_RETENTION}"
  local run_dir real_runs_dir real_run_dir
  local -a run_dirs=()

  case "$keep" in
    ''|*[!0-9]*) keep=20 ;;
  esac
  [ "$keep" -ge 1 ] || keep=20
  [ -d "$RUNS_DIR" ] || return 0

  real_runs_dir="$(readlink -f "$RUNS_DIR")"
  [ -n "$real_runs_dir" ] || fail "Unable to resolve runs directory: $RUNS_DIR"

  while IFS= read -r run_dir; do
    run_dirs+=("$run_dir")
  done < <(find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)

  while [ "${#run_dirs[@]}" -gt "$keep" ]; do
    run_dir="${run_dirs[0]}"
    run_dirs=("${run_dirs[@]:1}")
    real_run_dir="$(readlink -f "$RUNS_DIR/$run_dir")"

    case "$real_run_dir" in
      "$real_runs_dir"/*) ;;
      *) fail "Refusing to prune run outside runs directory: $real_run_dir" ;;
    esac

    log "Pruning old deploy run: $real_run_dir"
    rm -rf "$real_run_dir"
  done
}

start_background_run() {
  local target_action="$1"
  local run_id run_dir env_file quoted_run_dir quoted_env_file quoted_compose quoted_script
  local env_names=(
    SUB2API_REMOTE_DIR
    SUB2API_HEALTH_URL
    SUB2API_COMPOSE_FILE
    SUB2API_PROJECT_NAME
    SUB2API_CANDIDATE_COMPOSE
    SUB2API_BACKUP_RETENTION
    SUB2API_RUN_RETENTION
  )
  local name value

  prepare_dirs
  case "$target_action" in
    deploy|bluegreen-deploy) ;;
    *) fail "Background runs only support deploy or bluegreen-deploy." ;;
  esac

  run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$target_action-$$"
  run_dir="$RUNS_DIR/$run_id"
  mkdir -p "$run_dir"

  printf '%s\n' "$target_action" > "$run_dir/action"
  printf 'queued\n' > "$run_dir/status"
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$run_dir/started-at"

  env_file="$run_dir/env.sh"
  : > "$env_file"
  for name in "${env_names[@]}"; do
    value="${!name:-}"
    if [ -n "$value" ]; then
      printf 'export %s=%s\n' "$name" "$(shell_quote "$value")" >> "$env_file"
    fi
  done

  quoted_env_file="$(shell_quote "$env_file")"
  quoted_run_dir="$(shell_quote "$run_dir")"
  quoted_compose="$(shell_quote "$DEPLOY_DIR/$COMPOSE_FILE")"
  quoted_script="$(shell_quote "$SCRIPT_PATH")"

  cat > "$run_dir/runner.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
run_dir=$quoted_run_dir
cd $(shell_quote "$DEPLOY_DIR")
source $quoted_env_file
if [ -n "\${SUB2API_CANDIDATE_COMPOSE:-}" ] && [ -f "\$SUB2API_CANDIDATE_COMPOSE" ]; then
  cp -a "\$SUB2API_CANDIDATE_COMPOSE" $quoted_compose
fi
printf 'running\n' > "\$run_dir/status"
date -u '+%Y-%m-%dT%H:%M:%SZ' > "\$run_dir/running-at"
set +e
bash $quoted_script $target_action >> "\$run_dir/run.log" 2>&1
rc=\$?
set -e
printf '%s\n' "\$rc" > "\$run_dir/exit-code"
date -u '+%Y-%m-%dT%H:%M:%SZ' > "\$run_dir/finished-at"
if [ "\$rc" -eq 0 ]; then
  printf 'succeeded\n' > "\$run_dir/status"
else
  printf 'failed\n' > "\$run_dir/status"
fi
exit "\$rc"
EOF
  chmod +x "$run_dir/runner.sh"

  (
    cd "$run_dir"
    nohup bash "$run_dir/runner.sh" >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$run_dir/pid"
  )

  ln -sfn "$run_dir" "$RUNS_DIR/latest"
  prune_runs "$RUN_RETENTION"
  log "Started background deploy run: $run_id"
  log "Run directory: $run_dir"
  log "Check status with: run-status"
}

latest_run_dir() {
  local run="${SUB2API_RUN_ID:-latest}"
  local run_dir

  prepare_dirs
  if [ "$run" = "latest" ]; then
    run_dir="$(readlink -f "$RUNS_DIR/latest" 2>/dev/null || true)"
  else
    run_dir="$RUNS_DIR/$run"
  fi

  [ -n "$run_dir" ] && [ -d "$run_dir" ] || return 1
  printf '%s\n' "$run_dir"
}

run_status() {
  local run_dir status pid exit_code started_at finished_at action
  run_dir="$(latest_run_dir || true)"
  if [ -z "$run_dir" ]; then
    printf 'status=none\n'
    printf 'runs_dir=%s\n' "$RUNS_DIR"
    return 0
  fi

  action="$(cat "$run_dir/action" 2>/dev/null || true)"
  status="$(cat "$run_dir/status" 2>/dev/null || printf 'unknown')"
  pid="$(cat "$run_dir/pid" 2>/dev/null || true)"
  exit_code="$(cat "$run_dir/exit-code" 2>/dev/null || true)"
  started_at="$(cat "$run_dir/started-at" 2>/dev/null || true)"
  finished_at="$(cat "$run_dir/finished-at" 2>/dev/null || true)"

  printf 'run_id=%s\n' "$(basename "$run_dir")"
  printf 'action=%s\n' "${action:-unknown}"
  printf 'status=%s\n' "$status"
  [ -n "$pid" ] && printf 'pid=%s\n' "$pid"
  [ -n "$exit_code" ] && printf 'exit_code=%s\n' "$exit_code"
  [ -n "$started_at" ] && printf 'started_at=%s\n' "$started_at"
  [ -n "$finished_at" ] && printf 'finished_at=%s\n' "$finished_at"
  printf 'run_dir=%s\n' "$run_dir"
}

run_logs() {
  local run_dir tail_lines
  run_dir="$(latest_run_dir || true)"
  tail_lines="${SUB2API_RUN_LOG_TAIL:-200}"
  if [ -z "$run_dir" ]; then
    log "No deploy run found."
    return 0
  fi

  if [ -f "$run_dir/run.log" ]; then
    tail -n "$tail_lines" "$run_dir/run.log"
  else
    log "Run log not found yet: $run_dir/run.log"
  fi
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
  [ -f "$latest/caddy/Caddyfile" ] && mkdir -p "$DEPLOY_DIR/caddy" && cp -a "$latest/caddy/Caddyfile" "$DEPLOY_DIR/caddy/Caddyfile"
  [ -f "$latest/.ops/active-slot" ] && mkdir -p "$DEPLOY_DIR/.ops" && cp -a "$latest/.ops/active-slot" "$ACTIVE_SLOT_FILE"

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
  prepare_dirs
  compose logs --tail="${SUB2API_LOG_TAIL:-200}" caddy "$(slot_service "$(active_slot)")" postgres redis
}

trim() {
  local value="$*"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

host_from_url() {
  local raw="$1"
  raw="$(trim "$raw")"
  [ -n "$raw" ] || return 1

  case "$raw" in
    http://*|https://*) ;;
    *) return 1 ;;
  esac

  raw="${raw#*://}"
  raw="${raw%%/*}"
  raw="${raw%%\?*}"
  raw="${raw%%#*}"
  raw="${raw%@*}"

  if [ "${raw#\[}" != "$raw" ]; then
    raw="${raw#\[}"
    raw="${raw%%\]*}"
  else
    raw="${raw%%:*}"
  fi

  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  [ -n "$raw" ] || return 1
  printf '%s' "$raw"
}

scheme_from_url() {
  local raw="$1"
  raw="$(trim "$raw")"
  case "$raw" in
    http://*) printf 'http' ;;
    https://*) printf 'https' ;;
    *) return 1 ;;
  esac
}

host_matches_allowlist() {
  local host="$1"
  local allowlist="$2"
  local entry suffix

  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  IFS=',' read -r -a entries <<< "$allowlist"
  for entry in "${entries[@]}"; do
    entry="$(trim "$entry")"
    entry="$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')"
    [ -n "$entry" ] || continue
    entry="${entry%%:*}"

    if [ "${entry#\*.}" != "$entry" ]; then
      suffix="${entry#*.}"
      if [ "$host" = "$suffix" ] || [ "${host%.$suffix}" != "$host" ]; then
        return 0
      fi
      continue
    fi

    if [ "$host" = "$entry" ]; then
      return 0
    fi
  done

  return 1
}

is_private_host() {
  local host="$1"
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"

  case "$host" in
    localhost|*.localhost|0.0.0.0|127.*|10.*|192.168.*|169.254.*) return 0 ;;
    172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*) return 0 ;;
    ::1|fc*|fd*|fe80:*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_allowlist_url() {
  local label="$1"
  local raw="$2"
  local allowlist="$3"
  local allow_http="$4"
  local allow_private="$5"
  local scheme host

  scheme="$(scheme_from_url "$raw" 2>/dev/null || true)"
  host="$(host_from_url "$raw" 2>/dev/null || true)"

  if [ -z "$scheme" ] || [ -z "$host" ]; then
    log "ALLOWLIST_BLOCK invalid_url|$label|$raw"
    return 1
  fi

  if [ "$scheme" = "http" ] && [ "$allow_http" != "true" ]; then
    log "ALLOWLIST_BLOCK insecure_http|$label|$raw"
    return 1
  fi

  if [ "$allow_private" != "true" ] && is_private_host "$host"; then
    log "ALLOWLIST_BLOCK private_host|$label|$raw"
    return 1
  fi

  if ! host_matches_allowlist "$host" "$allowlist"; then
    log "ALLOWLIST_BLOCK host_not_allowed|$label|$host|$raw"
    return 1
  fi

  log "ALLOWLIST_OK $label|$host"
  return 0
}

validate_allowlist() {
  load_env

  local upstream_hosts pricing_hosts crs_hosts allow_http allow_private failed line label raw
  upstream_hosts="${SECURITY_URL_ALLOWLIST_UPSTREAM_HOSTS:-$DEFAULT_UPSTREAM_HOSTS}"
  pricing_hosts="${SECURITY_URL_ALLOWLIST_PRICING_HOSTS:-$DEFAULT_PRICING_HOSTS}"
  crs_hosts="${SECURITY_URL_ALLOWLIST_CRS_HOSTS:-$DEFAULT_CRS_HOSTS}"
  allow_http="${SECURITY_URL_ALLOWLIST_ALLOW_INSECURE_HTTP:-false}"
  allow_private="${SECURITY_URL_ALLOWLIST_ALLOW_PRIVATE_HOSTS:-false}"
  failed=0

  log "Validating URL allowlist candidates against current server data."
  log "This action is read-only and redacts credentials."
  log "Candidate upstream hosts: $upstream_hosts"
  log "Candidate pricing hosts: $pricing_hosts"
  log "Candidate CRS hosts: ${crs_hosts:-<empty>}"
  log "Allow insecure HTTP: $allow_http"
  log "Allow private hosts: $allow_private"

  while IFS='|' read -r label raw; do
    [ -n "${label:-}" ] || continue
    validate_allowlist_url "$label" "$raw" "$upstream_hosts" "$allow_http" "$allow_private" || failed=1
  done < <(
    compose exec -T postgres psql -qAt -U "${POSTGRES_USER:-sub2api}" -d "${POSTGRES_DB:-sub2api}" -v ON_ERROR_STOP=1 <<'SQL'
select 'account_base_url:' || id || ':' || platform || ':' || type || ':' || status || '|' || coalesce(credentials->>'base_url', '')
from accounts
where deleted_at is null
  and coalesce(credentials->>'base_url', '') <> ''
order by platform, type, id;

select 'setting_url:' || key || '|' || value
from settings
where key ilike '%url%'
  and value is not null
  and value <> ''
  and value ~* '^https?://'
order by key;
SQL
  )

  validate_allowlist_url "pricing_remote_url" "${PRICING_REMOTE_URL:-https://raw.githubusercontent.com/Wei-Shaw/model-price-repo/main/model_prices_and_context_window.json}" "$pricing_hosts" "$allow_http" "$allow_private" || failed=1
  validate_allowlist_url "pricing_hash_url" "${PRICING_HASH_URL:-https://raw.githubusercontent.com/Wei-Shaw/model-price-repo/main/model_prices_and_context_window.sha256}" "$pricing_hosts" "$allow_http" "$allow_private" || failed=1

  if [ "$failed" -ne 0 ]; then
    fail "URL allowlist validation failed. Update SECURITY_URL_ALLOWLIST_* candidates before enabling the allowlist."
  fi

  log "URL allowlist validation passed."
}

audit_allowlist() {
  load_env

  log "Auditing outbound URL allowlist candidates."
  log "This action is read-only and redacts credentials."

  compose exec -T postgres psql -U "${POSTGRES_USER:-sub2api}" -d "${POSTGRES_DB:-sub2api}" -v ON_ERROR_STOP=1 <<'SQL'
\pset tuples_only on
\pset format unaligned

select 'account_base_url|' || id || '|' || platform || '|' || type || '|' || status || '|' || coalesce(credentials->>'base_url', '')
from accounts
where deleted_at is null
  and coalesce(credentials->>'base_url', '') <> ''
order by platform, type, id;

select 'account_count|' || platform || '|' || type || '|' || status || '|' || count(*)
from accounts
where deleted_at is null
group by platform, type, status
order by platform, type, status;

select 'proxy_host|' || id || '|' || protocol || '|' || host || '|' || port || '|' || status
from proxies
where deleted_at is null
order by id;

select 'proxy_count|' || count(*)
from proxies
where deleted_at is null;

select 'setting_url|' || key || '|' || value
from settings
where key ilike '%url%'
  and value is not null
  and value <> ''
order by key;

select 'settings_count|' || count(*)
from settings;
SQL

  cat <<'EOF'
default_pricing_host|raw.githubusercontent.com
default_upstream_host|api.openai.com
default_upstream_host|api.anthropic.com
default_upstream_host|api.kimi.com
default_upstream_host|open.bigmodel.cn
default_upstream_host|api.minimaxi.com
default_upstream_host|generativelanguage.googleapis.com
default_upstream_host|cloudcode-pa.googleapis.com
default_upstream_host|oauth2.googleapis.com
default_upstream_host|www.googleapis.com
default_upstream_host|*.openai.azure.com
EOF
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
  audit-allowlist) audit_allowlist ;;
  validate-allowlist) validate_allowlist ;;
  active-slot) prepare_dirs; active_slot ;;
  switch-slot) load_env; prepare_dirs; switch_slot ;;
  doctor) doctor ;;
  validate) validate_compose ;;
  validate-candidate) validate_candidate_compose ;;
  backup) backup ;;
  start-deploy) start_background_run deploy ;;
  start-bluegreen-deploy) start_background_run bluegreen-deploy ;;
  run-status) run_status ;;
  run-logs) run_logs ;;
  deploy) deploy ;;
  bluegreen-deploy) bluegreen_deploy ;;
  rollback) rollback ;;
  status) status ;;
  logs) logs ;;
  *) fail "Unknown action: $ACTION" ;;
esac
