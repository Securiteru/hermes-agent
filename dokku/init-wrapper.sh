#!/bin/sh
# Hermes Agent — Dokku init wrapper.
#
# Replaces s6-overlay's /init (which can't run as a child of Dokku's
# process supervisor) with a minimal init that:
#
#   1. Adds /command to PATH (s6 binaries live there; normally prepended
#      by /init, which we're bypassing).
#   2. Pre-creates /run/s6 and chowns it to hermes (the gateway runtime
#      writes session state there).
#   3. Runs the upstream stage2-hook.sh (UID remap, /opt/data chown, etc.)
#      directly. This script uses #!/bin/sh and standard tools; its only
#      s6 dependency is `s6-setuidgid`, which we just made discoverable.
#   4. Runs my own 00-hermes-dokku-config (config.yaml seed).
#   5. Starts the healthcheck sidecar in the background.
#   6. Execs the gateway as the foreground process.
#
# Skipped (s6-only, not needed without s6):
#   - /etc/cont-init.d/01-hermes-setup        (just execs stage2-hook.sh)
#   - /etc/cont-init.d/015-supervise-perms    (chowns s6 supervise/ trees)
#   - /etc/cont-init.d/02-reconcile-profiles  (recreates per-profile s6 services)
#   - /etc/s6-overlay/s6-rc.d/                (s6-rc user bundle)

set -e

# --- PATH + /run/s6 prep (replaces what /init would have done) ---
# s6 binaries (s6-setuidgid, execlineb, with-contenv, etc.) live in /command.
# /init normally prepends /command to PATH; we do it explicitly here so the
# upstream stage2-hook.sh's `s6-setuidgid hermes ...` calls resolve.
export PATH="/command:${PATH}"

# S6_KEEP_ENV=1 tells /command/with-contenv (the shebang on main-wrapper.sh
# and the upstream cont-init.d scripts) to KEEP the current process environment
# instead of clearing it and loading from /run/s6/container_environment (which
# only exists when /init runs as PID 1). Without this, with-contenv fails with
# "s6-envdir: fatal: unable to envdir /run/s6/container_environment: No such
# file or directory" and the gateway can't start.
export S6_KEEP_ENV=1

# /run/s6 is the s6-overlay runtime state directory. Without /init running,
# it doesn't exist; some upstream code paths still mkdir under it. Pre-create
# as root, then chown to the hermes user so the privilege-dropped process
# can write to it.
mkdir -p /run/s6 /run/service 2>/dev/null || true
chown -R hermes:hermes /run/s6 /run/service 2>/dev/null || true

# --- Stage 1: UID remap + /opt/data chown ---
# The upstream stage2-hook.sh does all the cont-init work in one pass:
#   - validates HERMES_UID/HERMES_GID and remaps the hermes user
#   - creates /opt/data subdirs and chowns them
#   - runs docker_config_migrate.py
#   - writes s6 container_environment (we don't need this, but it's a no-op)
#
# Some sub-operations inside stage2-hook.sh fail under Dokku's process
# supervisor (e.g. s6-applyuidgid can't set supplementary groups without
# elevated caps). The script is designed to be mostly-idempotent and
# tolerant of partial failures, so we run it WITHOUT `set -e` here and
# log the exit code for diagnostics.
echo "[hermes-dokku-init] running stage2-hook.sh (UID remap, /opt/data chown)"
if /opt/hermes/docker/stage2-hook.sh; then
    echo "[hermes-dokku-init] stage2-hook.sh OK"
else
    rc=$?
    echo "[hermes-dokku-init] stage2-hook.sh exited $rc (continuing — most sub-ops are non-fatal)"
fi

# Re-assert /run/s6 + /run/service ownership in case stage2-hook reset them.
mkdir -p /run/s6 /run/service 2>/dev/null || true
chown -R hermes:hermes /run/s6 /run/service 2>/dev/null || true

# --- Stage 2: first-boot config seed ---
echo "[hermes-dokku-init] running 00-hermes-dokku-config (config.yaml seed)"
/etc/cont-init.d/00-hermes-dokku-config

# --- Stage 3: healthcheck sidecar ---
# Bind 127.0.0.1:9090. Stays in the background; if it dies, Dokku's
# healthcheck will fail and Dokku will restart the container (per
# `on-failure:10` policy).
echo "[hermes-dokku-init] starting healthcheck sidecar"
/usr/local/bin/hermes-healthcheck &
HEALTHCHECK_PID=$!
echo "[hermes-dokku-init] healthcheck pid: $HEALTHCHECK_PID"

# Trap signals to clean up the healthcheck on shutdown.
trap 'echo "[hermes-dokku-init] shutting down"; kill -TERM $HEALTHCHECK_PID 2>/dev/null; exit 0' TERM INT

# --- Stage 4: exec the gateway in the foreground ---
# main-wrapper.sh handles arg routing and drops to the hermes user via
# s6-setuidgid. When this exits, Dokku restarts the container.
echo "[hermes-dokku-init] exec gateway run (foreground)"
exec /opt/hermes/docker/main-wrapper.sh gateway run

