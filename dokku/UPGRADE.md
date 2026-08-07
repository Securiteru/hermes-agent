# Deploying Hermes Agent to Dokku

This file lives at the repo root (not in `dokku/`) because Dokku reads it
unconditionally from the build context. The `dokku/` directory holds the
overlay pieces that the `Dockerfile.dokku` references; nothing in
`dokku/` is part of the upstream Hermes Agent codebase.

## What this overlay does

Hermes Agent's published image assumes a single long-running container
with `network_mode: host` and an interactive `~/.hermes` data volume.
Dokku instead expects an HTTP service on `$PORT` with a `/health`
endpoint. This overlay bridges the two:

1. **`Dockerfile.dokku`** — builds the upstream image first, then layers
   Dokku-specific files on top. The upstream `Dockerfile` is **not
   modified**; only files inside this overlay's `dokku/` directory plus
   the `Procfile`, `CHECKS`, and `app.json` at the repo root are ours.

2. **`dokku/healthcheck.py`** — a 100-line stdlib HTTP server bound to
   `127.0.0.1:9090` (Dokku's healthcheck port). It answers `200 ok` on
   `GET /health` and a richer JSON status on `GET /health/deep`. It does
   NOT need aiohttp — the upstream image seals `/opt/hermes` and blocks
   lazy installs (`HERMES_DISABLE_LAZY_INSTALLS=1`), so adding aiohttp
   at runtime would fail.

3. **`dokku/s6-rc.d/dokku-healthcheck/`** — registers the healthcheck as
   a third s6-supervised service alongside the upstream `main-hermes`
   and `dashboard`. s6 restarts it on crash.

4. **`dokku/00-hermes-dokku-config`** — runs as a s6 cont-init.d hook
   (BEFORE user services start). On first boot (empty `/opt/data`),
   seeds `/opt/data/config.yaml` with provider, API server, and
   gateway settings derived from environment variables. On subsequent
   boots this is a no-op — operator changes to `config.yaml` are
   preserved.

5. **`CHECKS` + `app.json` + `Procfile`** at the repo root — Dokku's
   required manifest files. The `Procfile` makes `web` invoke
   `gateway run`, which the upstream `main-wrapper.sh` routes to
   `hermes gateway run` with the `s6-setuidgid hermes` privilege drop.

## First-time deploy (from a fresh clone)

```bash
# 1. Build the upstream image (one-time, ~5-15 min, cached after that)
docker build -t hermes-agent:upstream --build-arg HERMES_GIT_SHA=$(git rev-parse HEAD) .

# 2. Build the Dokku overlay image
docker build -f Dockerfile.dokku -t hermes-agent:dokku .

# 3. Local smoke test (verify /health answers 200)
docker run --rm -d --name hermes-smoke \
    -e API_SERVER_KEY=test-key \
    -e LLM_BASE_URL=http://100.73.253.25:20128/v1 \
    -e LLM_API_KEY=test \
    -e HERMES_UID=10000 \
    hermes-agent:dokku
sleep 30   # let s6 boot, config seed, services start
docker exec hermes-smoke curl -sS http://127.0.0.1:9090/health
# expect: ok
docker exec hermes-smoke s6-svstat /run/service/dokku-healthcheck
# expect: up
docker stop hermes-smoke

# 4. Create the Dokku app on the GCP helper host
ssh dokku@100.100.104.101 'dokku apps:create hermes-agent'

# 5. Attach persistent storage (must exist on the host)
ssh dokku@100.100.104.101 'mkdir -p /var/lib/dokku/data/storage/hermes-agent'
ssh dokku@100.100.104.101 \
    'dokku storage:mount hermes-agent /var/lib/dokku/data/storage/hermes-agent:/opt/data'

# 6. Set environment (Tailscale-internal, do NOT expose publicly)
ssh dokku@100.100.104.101 'dokku config:set hermes-agent \
    HERMES_UID=10000 \
    HERMES_GID=10000 \
    HERMES_DISABLE_LAZY_INSTALLS=1 \
    HERMES_LAZY_INSTALL_TARGET=/opt/data/lazy-packages \
    API_SERVER_HOST=0.0.0.0 \
    API_SERVER_PORT=9091 \
    API_SERVER_KEY=replace-with-psst-value \
    LLM_BASE_URL=http://100.73.253.25:20128/v1 \
    LLM_MODEL=auto/best'

# Inject secrets via psst (do NOT echo values into the shell history)
psst HERMES_API_SERVER_KEY -- ssh dokku@100.100.104.101 \
    "dokku config:set --no-restart hermes-agent API_SERVER_KEY=\$HERMES_API_SERVER_KEY"
psst OMNIROUTE_API_KEY -- ssh dokku@100.100.104.101 \
    "dokku config:set --no-restart hermes-agent LLM_API_KEY=\$OMNIROUTE_API_KEY CUSTOM_API_KEY=\$OMNIROUTE_API_KEY"
psst TELEGRAM_BOT_TOKEN -- ssh dokku@100.100.104.101 \
    "dokku config:set --no-restart hermes-agent TELEGRAM_BOT_TOKEN=\$TELEGRAM_BOT_TOKEN"

# Allow the Docker bridge to reach OmniRoute through the helper's Tailscale IP.
# This is host-local traffic to a Tailscale address; it does not open port 20128
# to the public interface. Run on agent-helper, or use dokku/allow-omniroute-tailscale.sh.
sudo ufw allow from 172.17.0.0/16 to 100.73.253.25 \
    port 20128 proto tcp comment 'Hermes to OmniRoute via Tailscale'

# 7. Add the Dokku remote and deploy
git remote add gcp-dokku dokku@100.100.104.101:hermes-agent
git push gcp-dokku main:main

# Optional Tailscale-only dashboard companion. Configure basic auth before
# starting it; PASSWORD_HASH is preferred over storing plaintext in Dokku:
dokku config:set --no-restart hermes-agent \
    HERMES_DASHBOARD=1 \
    HERMES_DASHBOARD_HOST=0.0.0.0 \
    HERMES_DASHBOARD_PORT=9119 \
    HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin \
    HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH='<scrypt hash>' \
    HERMES_DASHBOARD_BASIC_AUTH_SECRET='<random signing secret>'
dokku ports:add hermes-agent http:9091:9091
dokku ports:add hermes-agent http:9119:9119
# Run on the host; public ingress remains denied.
./dokku/allow-hermes-webui-tailscale.sh
```

## Run both browser UIs in the Hermes image (preferred)

The custom browser UI is a separate project from Hermes Agent's built-in
dashboard: [`nesquena/hermes-webui`](https://github.com/nesquena/hermes-webui).
`Dockerfile.dokku` copies the pinned UI release into the Hermes image and
installs its dependencies into the sealed Hermes virtualenv. Enable it as a
companion process so one Dokku app owns the API and both browser UIs:

```bash
dokku config:set --no-restart hermes-agent \
    HERMES_WEBUI=1 \
    HERMES_WEBUI_HOST=0.0.0.0 \
    HERMES_WEBUI_PORT=8787 \
    HERMES_WEBUI_STATE_DIR=/opt/data/webui \
    HERMES_WEBUI_DEFAULT_WORKSPACE=/opt/data/workspace \
    HERMES_WEBUI_AGENT_DIR=/opt/hermes \
    HERMES_WEBUI_CHAT_BACKEND=api_server \
    HERMES_WEBUI_GATEWAY_BASE_URL=http://127.0.0.1:9091
dokku ports:add hermes-agent http:8787:8787
./dokku/allow-hermes-webui-tailscale.sh
```

Set `HERMES_WEBUI_PASSWORD` from `psst`. The wrapper defaults
`HERMES_WEBUI_GATEWAY_API_KEY` to `API_SERVER_KEY`; do not duplicate the key
unless the deployment needs a separate secret. Verify `8787`, `9091`, and
`9119` through Tailscale and confirm the public host address times out.

## Alternative: run a separate `hermes-webui` rollback app

The custom browser UI is a separate project from Hermes Agent's built-in
dashboard: [`nesquena/hermes-webui`](https://github.com/nesquena/hermes-webui).
Run it as its own Dokku app only when a separate rollback/container is needed;
do not confuse its port with the built-in dashboard on `9119`.

```bash
# Build the pinned upstream UI image with the editable-install compatibility
# patch used by Hermes Agent's sealed source tree.
docker build -f dokku/Dockerfile.hermes-webui \
    -t hermes-webui:VERSION-dokku .

dokku apps:create hermes-webui
dokku config:set hermes-webui \
    HERMES_HOME=/home/hermeswebui/.hermes \
    HERMES_WEBUI_HOST=0.0.0.0 \
    HERMES_WEBUI_PORT=8787 \
    HERMES_WEBUI_STATE_DIR=/home/hermeswebui/.hermes/webui \
    HERMES_WEBUI_AGENT_DIR=/home/hermeswebui/.hermes/hermes-agent \
    HERMES_WEBUI_DEFAULT_WORKSPACE=/home/hermeswebui/.hermes/workspace \
    HERMES_WEBUI_CHAT_BACKEND=api_server \
    HERMES_WEBUI_GATEWAY_BASE_URL=http://100.73.253.25:9091 \
    HERMES_WEBUI_GATEWAY_API_KEY='<psst HERMES_API_SERVER_KEY>' \
    HERMES_WEBUI_PASSWORD='<psst HERMES_WEBUI_PASSWORD>'
dokku storage:mount hermes-webui \
    /var/lib/dokku/data/storage/hermes-agent:/home/hermeswebui/.hermes
dokku storage:mount hermes-webui \
    /var/lib/dokku/data/storage/hermes-webui-agent-src:/home/hermeswebui/.hermes/hermes-agent
dokku ports:add hermes-webui http:8787:8787
./dokku/allow-hermes-webui-tailscale.sh

# The UI container reaches the API server over the helper's Tailscale address;
# this bridge-only rule is required in addition to the Tailscale client rule.
sudo ufw allow from 172.17.0.0/16 to 100.73.253.25 \
    port 9091 proto tcp comment 'Hermes WebUI to API via Tailscale'

dokku git:from-image hermes-webui hermes-webui:VERSION-dokku
```

Verify `GET /health` and a real chat through `http://100.73.253.25:8787`.
The public host address must time out on `8787`, `9091`, and `9119`.

# 8. Verify
```bash
ssh dokku@100.100.104.101 'dokku ps:report hermes-agent'
ssh dokku@100.100.104.101 'dokku logs hermes-agent -t'
curl -sS http://100.100.104.101:9091/v1/models \
    -H "Authorization: Bearer $API_SERVER_KEY"
```

## Merging from upstream

```bash
# Fetch the latest upstream
git fetch upstream

# Merge into our deploy branch
git checkout dokku-deploy
git merge upstream/main --no-edit

# If upstream changed:
#   - the entrypoint/CMD contract   -> re-verify Procfile still routes correctly
#   - the s6 service layout          -> re-verify dokku/s6-rc.d/ still loads
#   - the API server env vars        -> re-verify gateway/config.py honors them
#   - the venv / provider resolution -> re-verify 00-hermes-dokku-config
# In practice the only conflicts are: none — our changes are 100% in
# new files that upstream doesn't touch.

# Rebuild + redeploy
docker build -t hermes-agent:upstream --build-arg HERMES_GIT_SHA=$(git rev-parse HEAD) .
docker build -f Dockerfile.dokku -t hermes-agent:dokku .
git push gcp-dokku main:main
```

## Why an overlay, not a fork

Upstream Hermes Agent is a fast-moving repo (18,052 commits at the time
of this writing). The `dokku-deploy` branch keeps every upstream change
mergeable in one command (`git merge upstream/main --no-edit`) because
none of our changes touch upstream-managed files. The only files
`git diff upstream/main --name-only` would ever show are:

- `Dockerfile.dokku` (new)
- `Procfile` (new)
- `CHECKS` (new)
- `app.json` (new)
- `dokku/` (new directory)

If upstream ever ships a `Procfile` or `app.json` of their own, the
merge will conflict — but that's a one-time resolution and we'd
update this overlay to match upstream's contract.

## Security notes

- The OpenAI-compatible API server binds `0.0.0.0:$API_SERVER_PORT` but
  the GCP host firewall (UFW) blocks 9090/9091 from the public
  interface. Tailscale is the only route. Even if the firewall
  regressed, `API_SERVER_KEY` is required (upstream's startup guard in
  `gateway/platforms/api_server.py:check_api_server_requirements`).
- The healthcheck binds `127.0.0.1:9090` so the gateway can use a
  different port for external traffic without collision. The healthcheck
  is reachable only from inside the container.
- `/opt/data` (config, OAuth tokens, auth.json, skills, memory) lives
  on a Dokku storage mount at `/var/lib/dokku/data/storage/hermes-agent/`.
  Back this up — it is the only durable state.
- NEVER log `API_SERVER_KEY`, `LLM_API_KEY`, `TELEGRAM_BOT_TOKEN`, or
  any `Authorization` header. The upstream `sanitize_inputs()` PII
  redactor covers most cases, but log hygiene is operator
  responsibility.
