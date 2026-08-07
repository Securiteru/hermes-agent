#!/usr/bin/env bash
set -euo pipefail

# Permit both Hermes browser surfaces only through the host's Tailscale
# interface. The Dokku proxy may listen on all interfaces; UFW keeps the raw
# ports private.
DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"
CHAT_WEBUI_PORT="${HERMES_WEBUI_PORT:-8787}"

if ! command -v ufw >/dev/null 2>&1; then
  echo "ufw is required" >&2
  exit 1
fi

for rule in \
  "$CHAT_WEBUI_PORT|Hermes custom WebUI via Tailscale" \
  "$DASHBOARD_PORT|Hermes dashboard via Tailscale"; do
  port="${rule%%|*}"
  comment="${rule#*|}"
  if sudo ufw status | grep -Fq "$comment"; then
    echo "UFW rule already present: $comment"
  else
    sudo ufw allow in on tailscale0 to any port "$port" \
      proto tcp comment "$comment"
    echo "Added Tailscale-only rule: $comment"
  fi
done

sudo ufw status | grep -E 'Hermes (custom WebUI|dashboard) via Tailscale'
