#!/bin/bash
set -e

# ============================================================
# VPS Setup Script: Node.js + PM2 + PostgreSQL + Caddy
#
# Installs all dependencies and configures the database.
# App name, DB user, and DB name are derived from the repo name.
# App deployment is handled by GitHub Actions.
#
# Usage:
#   bash setup.sh \
#     --db-password supersecret123 \
#     --github-repo USER/repo \
#     --github-token ghp_xxxxx
#
# Options:
#   --db-password   (required) PostgreSQL password
#   --github-repo   (required) GitHub repo (user/repo)
#   --github-token  (required) GitHub personal access token
#   --node-version  Node.js version: 20, 22 or 24 (default: 24)
# ============================================================

# Suppress interactive prompts and kernel restart warnings
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export DEBIAN_FRONTEND=noninteractive

# Defaults
DB_PASS=""
NODE_VERSION="24"
REPO=""
GH_TOKEN=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --db-password) DB_PASS="$2"; shift 2;;
    --node-version) NODE_VERSION="$2"; shift 2;;
    --github-repo) REPO="$2"; shift 2;;
    --github-token) GH_TOKEN="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

# Validation
ERRORS=()
[[ -z "$DB_PASS" ]] && ERRORS+=("--db-password is required")
[[ -z "$REPO" ]] && ERRORS+=("--github-repo is required")
[[ -z "$GH_TOKEN" ]] && ERRORS+=("--github-token is required")
[[ ! "$NODE_VERSION" =~ ^(20|22|24)$ ]] && ERRORS+=("--node-version must be 20, 22, or 24")

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo "Error:"
  for err in "${ERRORS[@]}"; do echo "  - $err"; done
  exit 1
fi

# Derive names from repo
APP_NAME=$(echo "$REPO" | cut -d'/' -f2)
DB_NAME="${APP_NAME}-db"
DB_USER="${APP_NAME}-user"
DATABASE_URL="postgres://$DB_USER:$DB_PASS@localhost:5432/$DB_NAME"

echo "============================================"
echo "  VPS Setup"
echo "============================================"
echo "  Repo:         $REPO"
echo "  App name:     $APP_NAME"
echo "  DB user:      $DB_USER"
echo "  DB name:      $DB_NAME"
echo "  Node.js:      v$NODE_VERSION"
echo "============================================"
echo ""

# --- Install Node.js (skip if already installed) ---
if command -v node &>/dev/null; then
  echo "==> Node.js already installed: $(node -v)"
else
  echo "==> Installing Node.js $NODE_VERSION..."
  curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
  apt-get update -y
  apt-get install -y nodejs
fi

if ! command -v pm2 &>/dev/null; then
  echo "==> Installing PM2..."
  npm i -g pm2
fi

corepack enable 2>/dev/null || true

# --- Install PostgreSQL 18 (skip if already installed) ---
if command -v psql &>/dev/null; then
  echo "==> PostgreSQL already installed"
else
  echo "==> Installing PostgreSQL 18..."
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor --yes -o /usr/share/keyrings/postgresql-archive-keyring.gpg 2>/dev/null

  echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    | tee /etc/apt/sources.list.d/pgdg.list > /dev/null

  apt-get update -y
  apt-get install -y postgresql-18 postgresql-contrib-18
fi

echo "==> Creating database and user..."
cd /tmp
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE USER \"$DB_USER\" WITH PASSWORD '$DB_PASS';"

sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";"
cd /root

sed -i 's/local\s*all\s*all\s*peer/local all all md5/' /etc/postgresql/*/main/pg_hba.conf
systemctl restart postgresql

# --- Install Caddy (skip if already installed) ---
if command -v caddy &>/dev/null; then
  echo "==> Caddy already installed"
else
  echo "==> Installing Caddy..."
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl

  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null

  chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  chmod o+r /etc/apt/sources.list.d/caddy-stable.list

  apt-get update -y
  apt-get install -y caddy
fi

# Enable Caddy site imports
mkdir -p /etc/caddy/sites
grep -q "import /etc/caddy/sites/\*" /etc/caddy/Caddyfile 2>/dev/null || echo "import /etc/caddy/sites/*" > /etc/caddy/Caddyfile
systemctl restart caddy

# --- Clone repo (skip if already cloned) ---
if [ -d "/root/$APP_NAME" ]; then
  echo "==> App folder /root/$APP_NAME already exists, skipping clone"
else
  echo "==> Cloning repository..."
  git clone https://${GH_TOKEN}@github.com/${REPO}.git /root/$APP_NAME
fi

# --- PM2 autostart ---
pm2 startup systemd -u root --hp /root 2>/dev/null || true

# --- Generate SSH deploy key for GitHub Actions ---
DEPLOY_KEY_PATH="/root/.ssh/deploy_key"
if [ -f "$DEPLOY_KEY_PATH" ]; then
  echo "==> Deploy key already exists"
else
  echo "==> Generating SSH deploy key..."
  ssh-keygen -t ed25519 -f "$DEPLOY_KEY_PATH" -C "github-actions-deploy" -N ""
  cat "${DEPLOY_KEY_PATH}.pub" >> /root/.ssh/authorized_keys
fi
VPS_SSH_KEY=$(cat "$DEPLOY_KEY_PATH")
VPS_HOST=$(curl -s ifconfig.me)

# --- Cron: daily DB backup, keep 7 days ---
mkdir -p /root/backups
CRON_JOB="0 3 * * * PGPASSWORD='$DB_PASS' pg_dump -U '$DB_USER' '$DB_NAME' | gzip > /root/backups/${APP_NAME}_\$(date +\%Y\%m\%d).sql.gz && find /root/backups -name '${APP_NAME}_*' -mtime +7 -delete"

# Add cron only if not already present
(crontab -l 2>/dev/null | grep -v "$APP_NAME" ; echo "$CRON_JOB") | crontab -

echo ""
echo "============================================"
echo "  Setup complete!"
echo "============================================"
echo ""
echo "  App name:     $APP_NAME"
echo "  App folder:   /root/$APP_NAME"
echo "  DB user:      $DB_USER"
echo "  DB name:      $DB_NAME"
echo ""
echo "  Add these to your GitHub Secrets:"
echo ""
echo "  VPS_SSH_KEY="
echo "$VPS_SSH_KEY"
echo ""
echo "  VPS_HOST=$VPS_HOST"
echo ""
echo "  ENV_FILE:"
echo "  DATABASE_URL=$DATABASE_URL"
echo ""
echo "  Now configure GitHub Variables and Secrets,"
echo "  then push to main to trigger the first deploy."
echo ""
echo "============================================"