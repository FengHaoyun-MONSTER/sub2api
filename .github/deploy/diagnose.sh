#!/usr/bin/env bash
# Read-only server diagnostic for sub2api deployment planning.
# This script MUST NOT modify anything on the server.
set -uo pipefail

line() { printf '\n===== %s =====\n' "$1"; }

line "OS / KERNEL"
uname -a || true
grep -E 'PRETTY_NAME|^VERSION=' /etc/os-release 2>/dev/null || true

line "ARCH"
uname -m || true

line "IDENTITY / SUDO"
id || true
if sudo -n true 2>/dev/null; then
  echo "SUDO: passwordless sudo AVAILABLE"
else
  echo "SUDO: NOT passwordless (needs password or unavailable)"
fi

line "CPU / MEMORY"
echo "cores: $(nproc 2>/dev/null || echo '?')"
free -h 2>/dev/null || true

line "DISK (root fs)"
df -h / 2>/dev/null || true

line "DOCKER"
if command -v docker >/dev/null 2>&1; then
  docker --version 2>/dev/null || true
  if docker compose version >/dev/null 2>&1; then
    docker compose version 2>/dev/null | head -1
  else
    echo "docker compose plugin: NOT AVAILABLE"
  fi
  echo "-- docker daemon reachable? --"
  if docker info >/dev/null 2>&1; then
    echo "docker daemon: OK (current user can use docker)"
  else
    echo "docker daemon: NOT reachable by this user (may need sudo/docker group)"
  fi
  echo "-- running containers --"
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}' 2>/dev/null || echo "cannot list (permission?)"
else
  echo "docker: NOT INSTALLED"
fi

line "KEY PORTS IN USE (8080 5432 6379 80 443)"
if command -v ss >/dev/null 2>&1; then
  ss -tlnp 2>/dev/null | grep -E ':(8080|5432|6379|80|443)\b' || echo "none of the key ports detected as listening (or need root for details)"
elif command -v netstat >/dev/null 2>&1; then
  netstat -tlnp 2>/dev/null | grep -E ':(8080|5432|6379|80|443)\b' || echo "none of the key ports detected as listening (or need root for details)"
else
  echo "no ss/netstat available"
fi

line "ALL LISTENING TCP PORTS (top 40)"
if command -v ss >/dev/null 2>&1; then
  ss -tlnp 2>/dev/null | head -40 || true
elif command -v netstat >/dev/null 2>&1; then
  netstat -tlnp 2>/dev/null | head -40 || true
fi

line "EXISTING SUB2API TRACES"
ls -la /opt/sub2api 2>/dev/null || echo "no /opt/sub2api directory"
systemctl status sub2api --no-pager 2>/dev/null | head -5 || echo "no sub2api systemd service"
if command -v docker >/dev/null 2>&1; then
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i sub2api || echo "no sub2api containers"
fi

line "FIREWALL (informational)"
if command -v ufw >/dev/null 2>&1; then
  sudo -n ufw status 2>/dev/null || echo "ufw present (status needs sudo)"
else
  echo "ufw not present"
fi

line "DIAGNOSTIC DONE"
