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
Several apps from one repository (a monorepo) are supported too — see
[Several apps from one repository](#several-apps-from-one-repository).

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

Only needed when several apps live in one repository (see below):

| Variable | Example | Default |
|---|---|---|
| `APP_NAME` | `myproject-api` | repo name |
| `APP_DIR` | `api` | `.` (repository root) |
| `BUILD_COMMAND` | `pnpm build` | `pnpm build` |
| `MIGRATE_COMMAND` | `pnpm db:migrate` | `pnpm db:migrate` |
| `START_SCRIPT` | `dist/server.js` | `build/index.js` |

`BUILD_COMMAND`, `MIGRATE_COMMAND` and `START_SCRIPT` run in `APP_DIR`, and the
`.env` file is written there.

## Step 6: Add the deploy workflow

Copy `deploy.yml` to `.github/workflows/deploy.yml` in your repo.

## Step 7: Deploy

```bash
git push origin main
```

Done. First deploy configures Caddy, writes `.env`, builds the app, and starts it.
Every subsequent push auto-deploys.

---

## Several apps from one repository

A monorepo with, say, `web/` and `api/` deploys as two apps on the same
server. Each app gets its own name, folder (a separate clone of the
repository), database, PM2 process, port and Caddy site — exactly as if they
were two repositories.

### 1. Run setup once per app

Same repository, a different `--app-name` and password for each:

```bash
curl -fsSL https://raw.githubusercontent.com/anstak/deployer/main/setup.sh | bash -s -- \
  --app-name "myproject-web" \
  --db-password "web-password" \
  --github-repo "YOUR_USER/myproject" \
  --github-token "ghp_xxxxxxxxxxxx"

curl -fsSL https://raw.githubusercontent.com/anstak/deployer/main/setup.sh | bash -s -- \
  --app-name "myproject-api" \
  --db-password "api-password" \
  --github-repo "YOUR_USER/myproject" \
  --github-token "ghp_xxxxxxxxxxxx"
```

### 2. One GitHub environment per app

Create an environment per app (for example `production-web` and
`production-api`) instead of the single `production`:

| | `production-web` | `production-api` |
|---|---|---|
| Variable `APP_NAME` | `myproject-web` | `myproject-api` |
| Variable `APP_DIR` | `web` | `api` |
| Variable `DOMAIN` | `myproject.com` | `api.myproject.com` |
| Variable `APP_PORT` | `3000` | `3001` |
| Variable `START_SCRIPT` | — (`build/index.js`) | `dist/server.js` |
| Secret `ENV_FILE` | web's env, with its `DATABASE_URL` | api's env, with its `DATABASE_URL` |

`VPS_HOST` and `VPS_SSH_KEY` are the same for all apps — they can be added
once as repository secrets instead of per environment.

### 3. One workflow per app

Copy `workflow-deploy.yml` once per app (`deploy-web.yml`, `deploy-api.yml`),
point it at the app's environment and deploy only when that app — or code it
shares — changes:

```yaml
name: Deploy web

on:
  push:
    branches: [main]
    paths:
      - 'web/**'
      - 'packages/**'       # shared code, if any
      - 'pnpm-lock.yaml'

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production-web
    # ...the rest as in workflow-deploy.yml
```

`pnpm install` runs at the repository root, so a pnpm workspace installs as a
whole; the build, migrations and the app itself run in `APP_DIR`.

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