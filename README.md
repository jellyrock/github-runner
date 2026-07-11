# GitHub Actions Self-Hosted Runner

A production-ready GitHub Actions self-hosted runner for running Roku hardware tests with network isolation and security hardening.

## Features

- **App-key isolation via sidecar registrar**: the GitHub App private key is mounted only into a one-shot registrar container that mints a short-lived runner registration token, then idles. The runner container has **no** App credentials in its env, so a malicious `pull_request_target` PR can't exfiltrate the key.
- **Network Isolation**: Runner can only access GitHub (HTTPS), npm registries, and your specific Roku device
- **Security Hardening**: Runs with dropped capabilities, no-new-privileges, and resource limits
- **Ephemeral Mode**: Fresh container for every job execution
- **Health Checks**: Monitors runner process and auto-restarts if unhealthy
- **Log Rotation**: Prevents disk space issues
- **Easy Deployment**: One-command installation with systemd integration

## Requirements

- Linux server with Docker and Docker Compose installed
- GitHub App with appropriate permissions
- Roku device on the same network for testing
- Minimum specs: 1 CPU, 3GB RAM

## Canonical source — do not fork these files

This repository is the **single source of truth** for the Roku runner. The
`docker-compose.yml` image digests (both `alpine` and `myoung34/github-runner`)
are pinned here and kept current by Renovate — and that pinning is
**load-bearing**: an un-bumped runner binary crash-loops once GitHub deprecates
it (see Troubleshooting).

**Do not copy these files into a host repo and commit them.** A committed copy
silently drifts from this source — the digests fall behind Renovate's bumps and
the pins rot. (Observed in practice: a downstream copy ran unpinned
`alpine:latest` and a stale runner digest while this repo's Renovate PRs sailed
past it, unused.) Hosts must instead **consume this repo at a pinned ref** and
treat the installed files as a generated artifact — see
[Consuming this repo on a host](#consuming-this-repo-on-a-host).

## Quick Start

### 1. Clone and Configure

```bash
git clone https://github.com/jellyrock/github-runner.git
cd github-runner
cp .env.example .env
```

### 2. Create GitHub App

1. Go to your organization settings: `https://github.com/organizations/jellyrock/settings/apps`
2. Click **New GitHub App**
3. Configure:
   - **GitHub App name**: `jellyrock-runner` (or any unique name)
   - **Homepage URL**: `https://github.com/jellyrock`
   - **Webhook**: Disable (uncheck "Active")
4. Set Permissions (minimum required for the sidecar registrar pattern):
   - **Actions**: Read & Write — required to mint runner registration tokens
   - **Metadata**: Read-only — auto-granted
   - (Add `Contents: Read & Write` and/or `Pull requests: Read & Write` only if your App also does auto-commits or auto-PRs. The runner itself does **not** need them.)
   - **Do NOT grant `Administration` or `Workflows: write`** — the runner registration flow doesn't need them, and they massively widen blast radius if the key leaks.
5. Click **Create GitHub App**
6. Scroll down to **Private keys** and click **Generate a private key**
7. Save the downloaded `.pem` file securely
8. Click **Install App** (left sidebar)
9. Select your repository and click **Install**
10. Note the **App ID** from the URL or app settings page
11. Note the **Installation ID** from the URL after installing (format: `/installations/INSTALL_ID`)

### 3. Place the App credentials on the host (NOT in `.env`)

The App private key never lives in `.env` or in the runner container's env — only the registrar sidecar reads it, from a host path with `root:0400` perms.

```bash
sudo mkdir -p /etc/github-app
sudo chown root:root /etc/github-app
sudo chmod 0700 /etc/github-app

# Paste the private key downloaded in step 2:
sudo tee /etc/github-app/key.pem < /path/to/your-app-private-key.pem
sudo chmod 0400 /etc/github-app/key.pem

# Numeric App ID (single line)
echo "123456" | sudo tee /etc/github-app/app-id
sudo chmod 0400 /etc/github-app/app-id

# Numeric Installation ID (single line)
echo "78901234" | sudo tee /etc/github-app/install-id
sudo chmod 0400 /etc/github-app/install-id

# "owner/repo" format
echo "jellyrock/jellyrock" | sudo tee /etc/github-app/repo-url
sudo chmod 0400 /etc/github-app/repo-url
```

### 4. Configure runner-specific environment variables

Edit `.env` with the (non-secret) runner config:

```bash
# Required: Roku device IP (no default - must be set)
ROKU_DEVICE_IP=192.168.1.200

# Optional: Customize runner
RUNNER_NAME=roku-runner-01
RUNNER_LABELS=self-hosted,roku,roku-device
TIMEZONE=America/New_York
```

`ROKU_DEVICE_IP` is **required**. None of the GitHub App credentials should ever be in `.env`.

### 5. Install and Start

**Default installation (to `/opt/github-runner`):**
```bash
sudo ./install.sh
sudo systemctl enable --now github-runner
```

**Custom installation path:**
```bash
# Install to a custom directory
sudo ./install.sh /var/lib/github-runner

# Then start
sudo systemctl enable --now github-runner
```

**Run the unit as a non-root user:**
```bash
# The unit runs `docker compose` as this user instead of root. The user must
# exist and be in the `docker` group; install.sh chowns the install dir to it.
sudo ./install.sh /opt/github-runner --service-user ci
```

`--service-user` defaults to `root`. Running as a docker-group user keeps the unit's
host process off uid 0 — the container hardening is unchanged (it lives in the compose
file). Combine with `--service-name` as needed.

The install script will:
- Copy all necessary files to the specified directory (including `mint-runner-token.sh` and `runner-entrypoint.sh`)
- Create a systemd service with the correct working directory
- Set up log rotation and health checks

### 6. Verify Installation

```bash
# Check service status
sudo systemctl status github-runner

# View runner logs
docker logs -f roku-runner

# Check GitHub (should show runner as online)
# https://github.com/jellyrock/jellyrock/settings/actions/runners
```

## Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│                    Host System (Linux)                             │
│                                                                    │
│  /etc/github-app/         ← App key + IDs (root:0400, host-only)   │
│       │                                                            │
│       │ bind-mount RO                                              │
│       ▼                                                            │
│  ┌─────────────────────────┐                                       │
│  │  roku-runner-registrar  │ mints registration token,             │
│  │  (alpine, one-shot)     │ writes /shared/runner-token, idles    │
│  └────────────┬────────────┘                                       │
│               │ (shared volume)                                    │
│               ▼                                                    │
│  ┌────────────────────────┐  ┌──────────────────────┐              │
│  │  roku-runner           │  │  iptables-sidecar    │              │
│  │  (no App env vars)     │──│  (network filtering) │              │
│  │  reads RUNNER_TOKEN    │  │  - NET_ADMIN cap     │              │
│  │  from shared volume    │  │  - blocks local LAN  │              │
│  └────────────────────────┘  └──────────────────────┘              │
└────────────────────────────────────────────────────────────────────┘
                            │
            ┌───────────────┼───────────────┐
            │               │               │
     ┌──────▼──────┐ ┌──────▼──────┐ ┌──────▼──────┐
     │   GitHub    │ │  npm/CDNs   │ │ Roku Device │
     │  (HTTPS)    │ │  (HTTPS)    │ │  (.env IP)  │
     └─────────────┘ └─────────────┘ └─────────────┘
```

**Key isolation property**: a malicious `pull_request_target` PR running inside `roku-runner` can read its own env, its filesystem, and the (already-consumed, ~1-hour-expiring) registration token in `/shared/runner-token`. It **cannot** reach `/etc/github-app/key.pem` — that path is only mounted into the registrar, which exits after writing the token.

## Security Model

### Network Security

- **Egress Allowed**: HTTP/HTTPS to any destination (required for npm, apt, GitHub)
- **Local Network**: Restricted to only the Roku device IP from `.env`
- **Isolation**: Uses iptables sidecar container with NET_ADMIN capability

### Container Security

- **No New Privileges**: Prevents privilege escalation
- **Capability Dropping**: All capabilities dropped except required ones (SETUID, SETGID, CHOWN, DAC_OVERRIDE, FOWNER)
- **Read-Only Root**: tmpfs mounts for /tmp and /home/runner
- **Resource Limits**: 1 CPU, 3GB RAM per runner
- **Ephemeral**: Fresh container for every job (no persistence between runs)

## Configuration Reference

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `ROKU_DEVICE_IP` | **Yes** | **None** | **IP address of Roku test device (REQUIRED)** |
| `RUNNER_NAME` | No | `roku-runner-01` | Runner display name |
| `RUNNER_LABELS` | No | `self-hosted,roku,roku-device` | Labels for job matching |
| `TIMEZONE` | No | `America/New_York` | Container timezone |

GitHub App credentials are **not** environment variables — they live as files in `/etc/github-app/` on the host (see step 3). The runner container has no access to them; only the registrar sidecar does.

| Host file | Required | Description |
|-----------|----------|-------------|
| `/etc/github-app/key.pem` | Yes | App private key (RSA PEM), 0400 root:root |
| `/etc/github-app/app-id` | Yes | Numeric App ID, single line |
| `/etc/github-app/install-id` | Yes | Numeric Installation ID, single line |
| `/etc/github-app/repo-url` | Yes | `owner/repo` (e.g. `jellyrock/jellyrock`) |

### Resource Limits

- **CPU**: 1 core
- **Memory**: 3GB
- **Logs**: 10MB per file, max 3 files (rotated)

## Operations

### Start/Stop/Restart

```bash
# Start
sudo systemctl start github-runner

# Stop
sudo systemctl stop github-runner

# Restart
sudo systemctl restart github-runner

# View logs
sudo journalctl -u github-runner -f
docker logs -f roku-runner
```

### Update

The runner image is **pinned to a digest** (not `:latest`) and bumped by
Renovate. To update:

1. Wait for the Renovate PR (titled `chore(deps): pin myoung34/github-runner …`)
2. Review and merge
3. Pull the new digest on the host and restart:

   ```bash
   cd /opt/github-runner   # or your INSTALL_DIR
   sudo docker compose pull
   sudo systemctl restart github-runner
   ```

The `chore(deps)` digest PRs are auto-merged on green CI (see `renovate.json`).
For emergency updates outside the Renovate cadence (e.g. GitHub deprecates a
runner version sooner than expected), edit the digest in `docker-compose.yml`
directly and run the same `compose pull` + `systemctl restart` cycle.

### Disaster Recovery

If the runner host fails:

1. **Setup new hardware** with Docker installed
2. **Clone this repository**: `git clone https://github.com/jellyrock/github-runner.git`
3. **Restore `/etc/github-app/`** from a secure backup (or re-create per step 3 of Quick Start using your existing App's `.pem` and IDs)
4. **Restore `.env`** from backup (contains only Roku IP + runner labels + optional `HEALTHCHECKS_URL` — no secrets)
5. **Run install.sh**: `sudo ./install.sh` (add `--service-name` if not using the default)
6. **Start service**: `sudo systemctl enable --now github-runner` (or your chosen service name)

The runner will automatically register with GitHub using the same name.

## Monitoring

The runner has three layers of failure detection, each catching a different class of problem:

| Layer | Catches | Configured by |
| --- | --- | --- |
| Docker healthcheck (`ps aux \| grep Runner.Listener`) | Container alive but listener process dead | `docker-compose.yml` (always on) |
| systemd `StartLimitBurst=5/300s` | Repeated container crashes (deprecated binary, bad config) | Unit file emitted by `install.sh` |
| Healthchecks.io push heartbeat | "Runner offline" from GitHub's perspective — covers all of the above plus host-level issues (kernel panic, docker dead, network down) | `HEALTHCHECKS_URL` in `.env` |

### Setting up the Healthchecks.io heartbeat

1. Create a check at <https://healthchecks.io/> (or your self-hosted HC instance)
2. Configure: **period** = `1 minute`, **grace** = `20 minutes`. The runner is ephemeral — the container restarts between every job — so the heartbeat has a gap on each cycle. A generous grace keeps those normal restart gaps (and brief self-recovering hiccups) from false-alerting, so a DOWN means a *sustained* outage worth paging on. (A too-tight grace causes alert fatigue: this check flipped 20× in 50 days on `grace=5m`, mostly self-recovered blips, which trained the alert to be ignored right before a real 18h outage.)
3. Add HC's **Gotify** (or email, Slack, etc.) integration to the check
4. Copy the check's ping URL into `.env`:

   ```bash
   HEALTHCHECKS_URL=https://hc-ping.com/<your-check-uuid>
   ```

5. `sudo systemctl restart <service-name>` to pick up the change

The runner pings `<URL>` every 60 s while it's alive. A runner that crashes within seconds of startup (deprecated binary, bad config, missing token) never gets to the periodic ping, so once the gap exceeds period + grace HC.io alerts. It does **not** ping `<URL>/start`: the container is ephemeral and dies before a run "completes", so a start signal never gets a matching success — it only adds noise.

## Troubleshooting

### Runner crash-loops with "Runner version X.Y.Z is deprecated and cannot receive messages"

**Cause:** GitHub deprecates older runner binaries every 1–3 months. The `myoung34/github-runner` image bundles a specific binary version — once GitHub deprecates it, the runner fails immediately on every start.

**Fix:**

```bash
cd /opt/github-runner   # or your INSTALL_DIR
sudo docker compose pull
sudo systemctl reset-failed <service-name>   # clear StartLimitBurst counter
sudo systemctl restart <service-name>
docker logs roku-runner | grep "Current runner version"
```

**Prevention:** the image is digest-pinned and Renovate raises PRs that auto-merge on green CI (see `renovate.json`). Make sure the Renovate GitHub App is installed on this repository and that CI is green for digest PRs.

### Runner shows as offline

```bash
# Check service status
sudo systemctl status <service-name>

# Watch the live runner output
docker logs -f roku-runner

# Confirm registration token was minted
docker logs roku-runner-registrar | tail
```

### systemd unit in `failed` state (StartLimitBurst exhausted)

The unit gives up after 5 failed starts in 5 minutes to avoid the multi-thousand-restart pathology. To clear it after fixing the underlying cause:

```bash
sudo systemctl reset-failed <service-name>
sudo systemctl start <service-name>
```

### Job fails during npm install

The runner needs HTTPS access to the npm registry. Check iptables:

```bash
docker exec roku-iptables iptables -L OUTPUT -n | grep 443
```

### Cannot connect to Roku device

Verify the IP in `.env`:

```bash
# From the runner container
docker exec roku-runner ping $ROKU_DEVICE_IP
```

### Permission denied errors

The runner uses root user by design (required by myoung34 image). This is normal.

## Consuming this repo on a host

A host must consume this repo **as the source**, not vendor a hand-edited copy.
The drift this prevents is concrete: the digest pins above only protect the
host if the host actually tracks *this* file.

1. **Pin a ref.** Track a specific tag or commit of this repo on the host — not
   a floating copy of `main`. Updates then become deliberate and reviewable
   (and Renovate can bump the pinned ref like any other dependency).
2. **Install from the pinned ref**, co-locating with other Compose projects via
   `--service-name` so the systemd unit name can't collide with a host-wide
   `github-runner` convention (example install dir `/srv/compose/cicd`):

   ```bash
   sudo ./install.sh /srv/compose/cicd --service-name roku-runner
   ```

   This emits `/etc/systemd/system/roku-runner.service` with
   `--project-name roku-runner` baked into every `docker compose` invocation —
   its own Compose project namespace, fully isolated from any sibling project
   that might do `docker compose up --remove-orphans` in a parent directory.
   Add `--service-user <user>` to run that unit as a non-root docker-group user
   instead of root.
3. **Treat the installed files as a generated artifact.** `.gitignore` them in
   the host repo (or vendor them under a clearly-marked, sync-only path). **Never
   hand-edit the image digests in the host copy** — that is exactly the drift
   this contract exists to prevent.
4. **Re-sync on Renovate bumps.** When a `chore(deps)` digest PR merges *here*,
   re-install (or re-pull the pinned ref) on the host and restart the unit, so
   the bump actually reaches the running container:

   ```bash
   sudo ./install.sh /srv/compose/cicd --service-name roku-runner
   sudo docker compose -p roku-runner pull && sudo systemctl restart roku-runner
   ```

**Sibling-project safety:** if a peer script does bulk `compose up --remove-orphans` from a parent directory, make sure it explicitly **excludes** the runner's compose file — e.g. `grep -v '^./cicd/'`. The `--project-name` isolation means `--remove-orphans` can't reach across projects, but it's still safest to exclude the file entirely so the runner is never (re)started outside its systemd unit.

## Development

### Testing Changes

1. Make changes to configuration files
2. Restart the service: `sudo systemctl restart github-runner`
3. Trigger a test workflow in your repository

### Adding Features

This runner is specifically designed for Roku hardware testing. To modify for other use cases:
- Update `REPO_URL` in docker-compose.yml
- Adjust `RUNNER_LABELS` for your workflow matching
- Modify resource limits as needed

## Support

For issues or questions:
1. Check logs: `docker logs roku-runner`
2. Verify configuration in `.env`
3. Test network connectivity from container
4. Open an issue in this repository
