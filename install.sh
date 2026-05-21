#!/bin/bash
# GitHub Actions Self-Hosted Runner Installation Script
# Usage: sudo ./install.sh [INSTALL_DIRECTORY] [--service-name NAME]
#
# Examples:
#   sudo ./install.sh                                                    # Default: /opt/github-runner + github-runner.service
#   sudo ./install.sh /opt/github-runner                                 # Custom dir
#   sudo ./install.sh /srv/compose/cicd \
#       --service-name roku-runner                                       # Co-located deployment (a co-located host pattern)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_DIR="/opt/github-runner"
SERVICE_NAME="github-runner"
while [ $# -gt 0 ]; do
    case "$1" in
        --service-name)
            SERVICE_NAME="$2"
            shift 2
            ;;
        --service-name=*)
            SERVICE_NAME="${1#--service-name=}"
            shift
            ;;
        -h|--help)
            sed -n '2,8p' "$0"
            exit 0
            ;;
        -*)
            echo "Error: unknown flag '$1'" >&2
            exit 2
            ;;
        *)
            INSTALL_DIR="$1"
            shift
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "GitHub Actions Runner Installer"
echo "=========================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run as root (use sudo)${NC}"
    exit 1
fi

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not installed${NC}"
    echo "Please install Docker first: https://docs.docker.com/engine/install/"
    exit 1
fi

# Check if Docker Compose is installed
if ! docker compose version &> /dev/null; then
    echo -e "${RED}Error: Docker Compose is not installed${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Docker and Docker Compose are installed${NC}"
echo ""
echo "Installation directory: $INSTALL_DIR"
echo ""

# Create installation directory
echo "Creating installation directory..."
mkdir -p "$INSTALL_DIR"

# Copy files
echo "Copying files..."
cp "$SCRIPT_DIR/docker-compose.yml" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/iptables-rules.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/mint-runner-token.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/runner-entrypoint.sh" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/iptables-rules.sh"
chmod +x "$INSTALL_DIR/mint-runner-token.sh"
chmod +x "$INSTALL_DIR/runner-entrypoint.sh"

# Check if .env exists
if [ ! -f "$INSTALL_DIR/.env" ]; then
    if [ -f "$SCRIPT_DIR/.env" ]; then
        cp "$SCRIPT_DIR/.env" "$INSTALL_DIR/"
        echo -e "${GREEN}✓ Copied existing .env file${NC}"
    else
        cp "$SCRIPT_DIR/.env.example" "$INSTALL_DIR/.env"
        echo -e "${YELLOW}⚠ Created .env from template${NC}"
        echo -e "${YELLOW}  IMPORTANT: Edit $INSTALL_DIR/.env with your GitHub App credentials${NC}"
    fi
else
    echo -e "${GREEN}✓ Existing .env file preserved${NC}"
fi

# Install systemd service with correct WorkingDirectory
echo ""
echo "Installing systemd service..."

# Create systemd service file with the correct WorkingDirectory
SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE_NAME}.service"
PROJECT_NAME="$SERVICE_NAME"
cat > "$SYSTEMD_SERVICE" << EOF
[Unit]
Description=GitHub Actions Self-Hosted Runner for Roku Tests
After=docker.service
Requires=docker.service
# Bound the restart loop. Without this, a deprecated runner binary (or any
# fast-failing root cause) generates thousands of restarts/day until manual
# intervention. 5 failures in 5 min → unit enters failed state; a missed
# HEALTHCHECKS_URL ping then alerts via Healthchecks.io.
StartLimitBurst=5
StartLimitIntervalSec=300

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStartPre=/usr/bin/docker compose --env-file .env -f docker-compose.yml --project-name $PROJECT_NAME down --remove-orphans
ExecStart=/usr/bin/docker compose --env-file .env -f docker-compose.yml --project-name $PROJECT_NAME up --abort-on-container-exit --force-recreate --remove-orphans
ExecStop=/usr/bin/docker compose --env-file .env -f docker-compose.yml --project-name $PROJECT_NAME down --remove-orphans
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

echo -e "${GREEN}✓ Systemd service installed${NC}"

# Check if .env has required variables
echo ""
echo "Checking configuration..."
if [ -f "$INSTALL_DIR/.env" ]; then
    # Source the .env file to check variables
    set -a
    source "$INSTALL_DIR/.env" 2>/dev/null || true
    set +a
    
    MISSING_VARS=""
    if [ -z "$ROKU_DEVICE_IP" ] || [ "$ROKU_DEVICE_IP" = "YOUR_ROKU_IP_HERE" ]; then
        MISSING_VARS="$MISSING_VARS\n  - ROKU_DEVICE_IP"
    fi

    if [ -n "$MISSING_VARS" ]; then
        echo -e "${YELLOW}⚠ Missing required .env configuration:${NC}"
        echo -e "$MISSING_VARS"
        echo ""
        echo "Please edit $INSTALL_DIR/.env and set these values before starting."
    fi
fi

# Check that the GitHub App credentials are placed on the host (NOT in .env).
# These are read by the registrar sidecar via a read-only bind mount.
echo ""
echo "Checking /etc/github-app/ ..."
GH_APP_MISSING=""
for f in key.pem app-id install-id repo-url; do
    if [ ! -r "/etc/github-app/$f" ]; then
        GH_APP_MISSING="$GH_APP_MISSING\n  - /etc/github-app/$f"
    fi
done
if [ -n "$GH_APP_MISSING" ]; then
    echo -e "${YELLOW}⚠ Missing GitHub App credential files:${NC}"
    echo -e "$GH_APP_MISSING"
    echo ""
    echo "See README 'Place the App credentials on the host' for setup steps."
    echo "All four files must exist with mode 0400 root:root before starting."
fi

# Summary
echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "Installation directory: $INSTALL_DIR"
echo "Systemd service: ${SERVICE_NAME}.service"
echo ""

if [ ! -f "$SCRIPT_DIR/.env" ] && [ ! -f "$INSTALL_DIR/.env" ]; then
    echo -e "${YELLOW}NEXT STEPS:${NC}"
    echo "1. Place GitHub App credentials in /etc/github-app/ (see README step 3)"
    echo ""
    echo "2. Edit $INSTALL_DIR/.env with the (non-secret) runner config:"
    echo "   - ROKU_DEVICE_IP   (required)"
    echo "   - HEALTHCHECKS_URL (optional, for offline alerting)"
    echo ""
    echo "3. Start the runner:"
    echo "   sudo systemctl enable --now ${SERVICE_NAME}"
    echo ""
    echo "4. Check status:"
    echo "   sudo systemctl status ${SERVICE_NAME}"
    echo "   docker logs -f roku-runner"
else
    echo -e "${GREEN}You can start the runner now:${NC}"
    echo "   sudo systemctl enable --now ${SERVICE_NAME}"
    echo ""
    echo "Check status:"
    echo "   sudo systemctl status ${SERVICE_NAME}"
    echo "   docker logs -f roku-runner"
fi

echo ""
echo "To view logs:"
echo "   docker logs -f roku-runner"
echo ""
echo "To stop:"
echo "   sudo systemctl stop ${SERVICE_NAME}"
echo ""
echo "To reinstall to a different location or service name:"
echo "   sudo ./install.sh /path/to/new/location --service-name custom-name"
echo ""
