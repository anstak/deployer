# VPS Deploy Guide: Node.js + PM2 + PostgreSQL + Caddy

## Overview

Everything is derived from your GitHub repository name.
For a repo named `simpleapp`:

| | Value |
|---|---|
| App folder | `/root/simpleapp` |
| PM2 process | `simpleapp` |
| DB name | `simpleapp-db` |
| DB user | `simpleapp-user` |
| Caddy config | `/etc/caddy/sites/simpleapp` |
| Backup files | `/root/backups/simpleapp_YYYYMMDD.sql.gz` |

Multiple apps on the same server — just run setup again with a different repo.

```
setup.sh (once per app)  →  Installs software, creates DB, clones repo
git push (every time)    →  Writes .env, configures Caddy, builds & deploys
```

## Step 1: Buy a VPS

Any provider (Hetzner, DigitalOcean, Vultr, etc).
Minimum: 512 MB RAM, Ubuntu 22/24.

## Step 2: Point your domain

Create an A record in DNS:

```
simpleapp.com → YOUR_VPS_IP
```

## Step 3: Create a GitHub Personal Access Token

GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens

Permissions:
- `Contents: Read` on your repository

## Step 4: Run the setup script

```bash
ssh root@YOUR_VPS_IP
```

```bash
curl -fsSL https://raw.githubusercontent.com/anstak/deployer/main/setup.sh | bash -s -- \
  --db-password "your-secure-password" \
  --github-repo "YOUR_USER/simpleapp" \
  --github-token "ghp_xxxxxxxxxxxx"
```

Optional:

```
--node-version 24      # default: 22 (options: 20, 22, 24)
```

Save the `DATABASE_URL` printed at the end.

### Adding a second app on the same server

Just run setup again with a different repo and password:

```bash
curl -fsSL https://raw.githubusercontent.com/anstak/deployer/main/setup.sh | bash -s -- \
  --db-password "another-password" \
  --github-repo "YOUR_USER/myapi" \
  --github-token "ghp_xxxxxxxxxxxx"
```

Node.js, PostgreSQL, and Caddy won't be reinstalled — the script handles this gracefully.
A new DB, user, and app folder will be created.

## Step 5: Configure GitHub

### Create `production` environment

Go to: Your repo → Settings → Environments → New environment

Name: `production` → Configure environment

All secrets and variables below are created inside this environment.

### Secrets (encrypted, hidden in logs)

Inside the `production` environment → Add secret:

| Secret | Value |
|---|---|
| `VPS_HOST` | Your server IP |
| `VPS_SSH_KEY` | Private key from `cat ~/.ssh/deploy_key` (see above) |
| `ENV_FILE` | All secret env vars (see below) |

### ENV_FILE content

Paste as the value of `ENV_FILE` secret:

```
DATABASE_URL=postgres://simpleapp-user:password@localhost:5432/simpleapp-db
BETTER_AUTH_SECRET=your-secret-key
BETTER_AUTH_URL=https://simpleapp.com
RESEND_API_KEY=re_...
EMAIL_FROM=noreply@simpleapp.com
PUBLIC_TURNSTILE_SITE_KEY=...
TURNSTILE_SECRET_KEY=...
```

### Variables (non-sensitive, visible in logs)

Inside the `production` environment → Variables tab → Add variable:

| Variable | Example | Default |
|---|---|---|
| `DOMAIN` | `simpleapp.com` | — |
| `APP_PORT` | `3000` | `3000` |
| `NODE_ENV` | `production` | `production` |

## Step 6: Add the deploy workflow

Copy `deploy.yml` to `.github/workflows/deploy.yml` in your repo.

## Step 7: Deploy

```bash
git push origin main
```

Done. First deploy configures Caddy, writes `.env`, builds the app, and starts it.
Every subsequent push auto-deploys.

---

## Common tasks

### Adding new env vars

1. Edit `ENV_FILE` secret in GitHub (add the new line)
2. Push any commit

### Changing domain

1. Update `DOMAIN` variable in GitHub
2. Point new domain to server IP (A record)
3. Push any commit — Caddy gets new SSL cert automatically

### Run Drizzle commands manually

```bash
ssh root@YOUR_VPS_IP
cd ~/simpleapp
npx drizzle-kit push
npx drizzle-kit studio
npx drizzle-kit migrate
```

---

## Useful commands

### App

```bash
pm2 status
pm2 logs simpleapp
pm2 logs simpleapp --lines 100
pm2 restart simpleapp
pm2 monit
```

### Database

```bash
# Connect
psql -U simpleapp-user -d simpleapp-db -h localhost

# Manual backup
PGPASSWORD='yourpass' pg_dump -U simpleapp-user simpleapp-db > backup.sql

# Restore
psql -U simpleapp-user -d simpleapp-db -h localhost < backup.sql
```

Daily backups: `/root/backups/` (cron, 3:00 AM, 7-day retention).

### Caddy

```bash
systemctl status caddy
journalctl -u caddy -f
```

### Multiple apps

```bash
# See all running apps
pm2 status

# Logs for specific app
pm2 logs simpleapp
pm2 logs myapi

# List all Caddy sites
ls /etc/caddy/sites/
```