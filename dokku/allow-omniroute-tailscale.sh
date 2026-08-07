#!/usr/bin/env bash
set -euo pipefail

# Permit Hermes/Docker clients to reach OmniRoute through the helper's
# Tailscale address. This does not open OmniRoute on the public interface.
TAILSCALE_IP="${TAILSCALE_IP:-100.73.253.25}"
DOCKER_CIDR="${DOCKER_CIDR:-172.17.0.0/16}"
OMNIROUTE_PORT="${OMNIROUTE_PORT:-20128}"
RULE_COMMENT="Hermes to OmniRoute via Tailscale"

if ! command -v ufw >/dev/null 2>&1; then
  echo "ufw is required" >&2
  exit 1
fi

if sudo ufw status | grep -Fq "$RULE_COMMENT"; then
  echo "UFW rule already present: $RULE_COMMENT"
else
  sudo ufw allow from "$DOCKER_CIDR" to "$TAILSCALE_IP" \
    port "$OMNIROUTE_PORT" proto tcp comment "$RULE_COMMENT"
  echo "Added Docker-to-Tailscale OmniRoute rule"
fi

sudo ufw status | grep -F "$RULE_COMMENT"
