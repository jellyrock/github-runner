#!/bin/bash
# GitHub Actions Self-Hosted Runner Installation Script
# Usage: sudo ./install.sh [INSTALL_DIRECTORY]
# 
# Examples:
#   sudo ./install.sh                          # Uses default: /opt/github-runner
#   sudo ./install.sh /opt/github-runner       # Install to /opt/github-runner

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Allow install directory to be passed as argument, default to /opt/github-runner
INSTALL_DIR="${1:-/opt/github-runner}"

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
chmod +x "$INSTALL_DIR/iptables-rules.sh"

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
SYSTEMD_SERVICE="/etc/systemd/system/github-runner.service"
cat > "$SYSTEMD_SERVICE" << EOF
[Unit]
Description=GitHub Actions Self-Hosted Runner for Roku Tests
After=docker.service
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/docker compose --env-file .env -f docker-compose.yml up --abort-on-container-exit --force-recreate
ExecStop=/usr/bin/docker compose -f docker-compose.yml down
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
    if [ -z "$GITHUB_APP_ID" ] || [ "$GITHUB_APP_ID" = "YOUR_APP_ID_HERE" ]; then
        MISSING_VARS="$MISSING_VARS\n  - GITHUB_APP_ID"
    fi
    if [ -z "$GITHUB_APP_PEM" ] || [ "$GITHUB_APP_PEM" = "YOUR_PRIVATE_KEY_CONTENT_HERE" ]; then
        MISSING_VARS="$MISSING_VARS\n  - GITHUB_APP_PEM"
    fi
    
    if [ -n "$MISSING_VARS" ]; then
        echo -e "${YELLOW}⚠ Missing required configuration:${NC}"
        echo -e "$MISSING_VARS"
        echo ""
        echo "Please edit $INSTALL_DIR/.env and set these values before starting."
    fi
fi

# Summary
echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "Installation directory: $INSTALL_DIR"
echo "Systemd service: github-runner.service"
echo ""

if [ ! -f "$SCRIPT_DIR/.env" ] && [ ! -f "$INSTALL_DIR/.env" ]; then
    echo -e "${YELLOW}NEXT STEPS:${NC}"
    echo "1. Edit $INSTALL_DIR/.env with your credentials:"
    echo "   - GITHUB_APP_ID"
    echo "   - GITHUB_APP_INSTALL_ID"
    echo "   - GITHUB_APP_PEM"
    echo "   - ROKU_DEVICE_IP"
    echo ""
    echo "2. Start the runner:"
    echo "   sudo systemctl enable --now github-runner"
    echo ""
    echo "3. Check status:"
    echo "   sudo systemctl status github-runner"
    echo "   docker logs -f roku-runner"
else
    echo -e "${GREEN}You can start the runner now:${NC}"
    echo "   sudo systemctl enable --now github-runner"
    echo ""
    echo "Check status:"
    echo "   sudo systemctl status github-runner"
    echo "   docker logs -f roku-runner"
fi

echo ""
echo "To view logs:"
echo "   docker logs -f roku-runner"
echo ""
echo "To stop:"
echo "   sudo systemctl stop github-runner"
echo ""
echo "To reinstall to a different location:"
echo "   sudo ./install.sh /path/to/new/location"
echo ""
