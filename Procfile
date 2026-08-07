# Procfile for Dokku deployment of Hermes Agent.
#
# `web` is the long-running gateway with the OpenAI-compatible API server
# enabled. Dokku maps $PORT (default 5000) to the container, but Hermes's
# API server is configured via API_SERVER_PORT (default 9091) so the
# Dokku healthcheck (port 9090, internal-only) and the public API
# (port 9091) don't collide.
#
# The upstream s6-overlay /init remains PID 1 and supervises:
#   - main-hermes (no-op sleep infinity by design)
#   - dashboard   (disabled unless HERMES_DASHBOARD=1)
#   - dokku-healthcheck (added by Dockerfile.dokku)
#
# `dokku run hermes-agent hermes <subcommand>` invokes the CLI via the
# upstream main-wrapper.sh directly (no Dokku Procfile entry needed).

web: /opt/hermes/docker/main-wrapper.sh gateway run
