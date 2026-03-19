# GitHub Actions Self-Hosted Runner

A production-ready GitHub Actions self-hosted runner for running Roku hardware tests with network isolation and security hardening.

## Features

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
4. Set Permissions:
   - **Actions**: Read & Write
   - **Administration**: Read & Write
   - **Contents**: Read & Write
   - **Metadata**: Read-only
   - **Pull requests**: Read & Write
5. Click **Create GitHub App**
6. Scroll down to **Private keys** and click **Generate a private key**
7. Save the downloaded `.pem` file securely
8. Click **Install App** (left sidebar)
9. Select your repository and click **Install**
10. Note the **App ID** from the URL or app settings page
11. Note the **Installation ID** from the URL after installing (format: `/installations/INSTALL_ID`)

### 3. Configure Environment Variables

Edit `.env` with your values:

```bash
# Required: GitHub App credentials
GITHUB_APP_ID=123456
GITHUB_APP_INSTALL_ID=78901234
GITHUB_APP_PEM="-----BEGIN RSA PRIVATE KEY-----
MIIE... (your private key content) ...
-----END RSA PRIVATE KEY-----"

# Required: Roku device IP (no default - must be set)
ROKU_DEVICE_IP=192.168.1.200

# Optional: Customize runner
RUNNER_NAME=roku-runner-01
RUNNER_LABELS=self-hosted,roku,roku-device
```

**Important**: 
- `ROKU_DEVICE_IP` is **required** and has no default. The runner will fail to start without it.
- For the private key, you can either paste it as a single line with `\n` characters, or keep it multi-line in the file

### 4. Install and Start

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

The install script will:
- Copy all necessary files to the specified directory
- Create a systemd service with the correct working directory
- Set up log rotation and health checks

### 5. Verify Installation

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
┌─────────────────────────────────────────────────────────────┐
│                    Host System (Linux)                      │
│  ┌─────────────────────────────────────────────────────┐   │
│  │         Systemd: github-runner.service              │   │
│  └──────────────────┬──────────────────────────────────┘   │
│                     │                                       │
│  ┌──────────────────▼──────────────────────────────────┐   │
│  │              Docker Compose                         │   │
│  │  ┌─────────────────┐  ┌──────────────────────┐     │   │
│  │  │  roku-runner    │  │  iptables-sidecar    │     │   │
│  │  │  (main runner)  │──│  (network filtering) │     │   │
│  │  │  - 1 CPU        │  │  - NET_ADMIN cap     │     │   │
│  │  │  - 3GB RAM      │  │  - blocks local LAN  │     │   │
│  │  └─────────────────┘  └──────────────────────┘     │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                            │
            ┌───────────────┼───────────────┐
            │               │               │
     ┌──────▼──────┐ ┌──────▼──────┐ ┌──────▼──────┐
     │   GitHub    │ │  npm/CDNs   │ │ Roku Device │
     │  (HTTPS)    │ │  (HTTPS)    │ │  (.env IP)  │
     └─────────────┘ └─────────────┘ └─────────────┘
```

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
| `GITHUB_APP_ID` | Yes | - | GitHub App ID |
| `GITHUB_APP_INSTALL_ID` | Yes | - | GitHub App Installation ID |
| `GITHUB_APP_PEM` | Yes | - | GitHub App private key |
| `ROKU_DEVICE_IP` | **Yes** | **None** | **IP address of Roku test device (REQUIRED)** |
| `RUNNER_NAME` | No | `roku-runner-01` | Runner display name |
| `RUNNER_LABELS` | No | `self-hosted,roku,roku-device` | Labels for job matching |
| `TIMEZONE` | No | `America/New_York` | Container timezone |

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

```bash
# Pull latest runner image
docker pull myoung34/github-runner:latest

# Restart service
sudo systemctl restart github-runner
```

### Disaster Recovery

If the runner host fails:

1. **Setup new hardware** with Docker installed
2. **Clone this repository**: `git clone https://github.com/jellyrock/github-runner.git`
3. **Copy `.env` file** from backup (contains your GitHub App credentials)
4. **Run install.sh**: `sudo ./install.sh`
5. **Start service**: `sudo systemctl enable --now github-runner`

The runner will automatically register with GitHub using the same name.

## Troubleshooting

### Runner shows as offline

```bash
# Check service status
sudo systemctl status github-runner

# View logs
docker logs roku-runner

# Check GitHub API response
docker exec roku-runner curl -s https://api.github.com
```

### Job fails during npm install

The runner needs HTTPS access to npm registry. Check iptables:
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
