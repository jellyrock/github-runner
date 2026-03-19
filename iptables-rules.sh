#!/bin/sh
# Configure iptables for runner network
# Allows HTTPS/HTTP egress while restricting local network to Roku device only

set -e

# Install iptables if needed
if ! which iptables >/dev/null 2>&1; then
    apk add --no-cache iptables
fi

# Get Roku device IP from environment variable (REQUIRED)
if [ -z "$ROKU_DEVICE_IP" ]; then
    echo "Error: ROKU_DEVICE_IP environment variable is required"
    echo "Please set it in your .env file"
    exit 1
fi
ROKU_IP="$ROKU_DEVICE_IP"

echo "Configuring iptables..."
echo "Roku device IP: $ROKU_IP"

# Clear all existing rules
iptables -F OUTPUT 2>/dev/null || true

# Allow loopback
iptables -A OUTPUT -o lo -j ACCEPT

# Allow DNS
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Allow HTTP/HTTPS to anywhere (required for npm, apt, GitHub, CDNs, etc.)
iptables -A OUTPUT -p tcp --dport 80 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT

# Allow Roku device (CI hardware under test) - from environment variable
iptables -A OUTPUT -d "$ROKU_IP" -j ACCEPT

# Drop everything else
iptables -A OUTPUT -j DROP

echo "iptables configured: HTTPS + HTTP allowed, local network restricted to $ROKU_IP"
iptables -L OUTPUT -n --line-numbers | tail -10
