#!/usr/bin/env bash
# =============================================================================
# Sub2API deployment (Docker Compose) — runs ON the target server via SSH.
# Design goals for THIS server:
#   - Docker is installed but the login user is NOT in the docker group,
#     yet has passwordless sudo -> use `sudo docker`.
#   - Existing services already use ports 80/443 -> we only publish 8080.
#   - PostgreSQL/Redis are NOT published to the host (internal network only).
#   - Infra secrets (DB password, JWT, TOTP) are generated here and stored in
#     .env (chmod 600). They never leave the server.
#   - Admin email/password are injected (base64) from GitHub secrets.
# =============================================================================
set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-$HOME/sub2api-deploy}"
DOCKER="sudo docker"

# Decode admin credentials passed base64-encoded from the workflow.
ADMIN_EMAIL="$(printf '%s' "${ADMIN_EMAIL_B64:-}" | base64 -d 2>/dev/null || true)"
ADMIN_PASSWORD="$(printf '%s' "${ADMIN_PASSWORD_B64:-}" | base64 -d 2>/dev/null || true)"
: "${ADMIN_EMAIL:=admin@sub2api.local}"

if [ -z "$ADMIN_PASSWORD" ]; then
  echo "ERROR: ADMIN_PASSWORD not provided (set the ADMIN_PASSWORD repo secret)." >&2
  exit 1
fi

echo "==> [1/7] Verifying docker access"
$DOCKER version --format '{{.Server.Version}}' >/dev/null
$DOCKER compose version >/dev/null

echo "==> [2/7] Preparing deploy dir: $DEPLOY_DIR"
mkdir -p "$DEPLOY_DIR"/data "$DEPLOY_DIR"/postgres_data "$DEPLOY_DIR"/redis_data
cd "$DEPLOY_DIR"

echo "==> [3/7] Writing docker-compose.yml"
cat > docker-compose.yml <<'YAML'
services:
  sub2api:
    image: weishaw/sub2api:latest
    container_name: sub2api
    restart: unless-stopped
    ulimits:
      nofile: {soft: 100000, hard: 100000}
    ports:
      - "${BIND_HOST:-0.0.0.0}:${SERVER_PORT:-8080}:8080"
    volumes:
      - ./data:/app/data
    environment:
      - AUTO_SETUP=true
      - SERVER_HOST=0.0.0.0
      - SERVER_PORT=8080
      - SERVER_MODE=release
      - DATABASE_HOST=postgres
      - DATABASE_PORT=5432
      - DATABASE_USER=${POSTGRES_USER:-sub2api}
      - DATABASE_PASSWORD=${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}
      - DATABASE_DBNAME=${POSTGRES_DB:-sub2api}
      - DATABASE_SSLMODE=disable
      - REDIS_HOST=redis
      - REDIS_PORT=6379
      - REDIS_DB=0
      - ADMIN_EMAIL=${ADMIN_EMAIL:-admin@sub2api.local}
      - ADMIN_PASSWORD=${ADMIN_PASSWORD:-}
      - JWT_SECRET=${JWT_SECRET:-}
      - JWT_EXPIRE_HOUR=24
      - TOTP_ENCRYPTION_KEY=${TOTP_ENCRYPTION_KEY:-}
      - TZ=${TZ:-Asia/Shanghai}
    depends_on:
      postgres: {condition: service_healthy}
      redis: {condition: service_healthy}
    networks: [sub2api-network]
    healthcheck:
      test: ["CMD", "wget", "-q", "-T", "5", "-O", "/dev/null", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  postgres:
    image: postgres:18-alpine
    container_name: sub2api-postgres
    restart: unless-stopped
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
    environment:
      - POSTGRES_USER=${POSTGRES_USER:-sub2api}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}
      - POSTGRES_DB=${POSTGRES_DB:-sub2api}
      - PGDATA=/var/lib/postgresql/data
      - TZ=${TZ:-Asia/Shanghai}
    networks: [sub2api-network]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-sub2api} -d ${POSTGRES_DB:-sub2api}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  redis:
    image: redis:8-alpine
    container_name: sub2api-redis
    restart: unless-stopped
    volumes:
      - ./redis_data:/data
    command: redis-server --save 60 1 --appendonly yes --appendfsync everysec
    environment:
      - TZ=${TZ:-Asia/Shanghai}
    networks: [sub2api-network]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 5s

networks:
  sub2api-network:
    driver: bridge
YAML

echo "==> [4/7] Ensuring .env (secrets generated on first deploy only)"
if [ ! -f .env ]; then
  umask 077
  cat > .env <<ENV
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) — keep this file private (chmod 600)
POSTGRES_USER=sub2api
POSTGRES_DB=sub2api
POSTGRES_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
TOTP_ENCRYPTION_KEY=$(openssl rand -hex 32)
ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
BIND_HOST=0.0.0.0
SERVER_PORT=8080
TZ=Asia/Shanghai
ENV
  chmod 600 .env
  echo "    New .env created with fresh secrets."
else
  echo "    .env already exists — preserving existing secrets (not overwriting)."
fi

echo "==> [5/7] Pulling images (this can take a minute on 1 vCPU)"
$DOCKER compose pull

echo "==> [6/7] Starting services"
$DOCKER compose up -d

echo "==> [7/7] Waiting for sub2api to become healthy"
ok=0
for i in $(seq 1 30); do
  sleep 5
  status="$($DOCKER inspect --format '{{.State.Health.Status}}' sub2api 2>/dev/null || echo unknown)"
  echo "    attempt $i: sub2api health=$status"
  if [ "$status" = "healthy" ]; then ok=1; break; fi
done

echo "----- container status -----"
$DOCKER compose ps
echo "----- last 30 log lines (secrets NOT printed) -----"
$DOCKER compose logs --tail 30 sub2api | grep -viE 'password|secret|token|jwt' || true

if [ "$ok" = "1" ]; then
  echo "RESULT: SUCCESS — sub2api is healthy on port 8080."
else
  echo "RESULT: WARNING — sub2api did not report healthy within timeout. Check logs above."
  exit 2
fi
