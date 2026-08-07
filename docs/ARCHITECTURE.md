# Hermes Agent — Dokku Deployment Architecture

> **Status:** Production-deployed (2026-07-27)
> **Location:** GCP Dokku instance `100.100.104.101` (Tailscale internal-only)
> **Endpoint:** `http://100.100.104.101:9091` (Tailscale network only)
> **Fork:** [Securiteru/hermes-agent](https://github.com/Securiteru/hermes-agent) @ `dokku-deploy`

---

## 1. System Overview

Hermes Agent (by Nous Research) is deployed as a Docker container on a Dokku
host running on GCP. The container exposes an OpenAI-compatible API server
that proxies LLM requests through OmniRoute (a self-hosted LLM gateway). All
access is restricted to the Tailscale internal network.

```mermaid
graph TB
    subgraph "Tailscale Network (100.x.x.x)"
        Client["Client<br/>(opencode, curl, etc.)"]

        subgraph "GCP Dokku Host — 100.100.104.101"
            Nginx["Nginx Reverse Proxy<br/>:9091"]

            subgraph "Docker Container<br/>hermes-agent.web.1"
                InitWrapper["hermes-dokku-init<br/>(PID 1 replacement)"]
                Gateway["Hermes Gateway API<br/>aiohttp :9091"]
                Healthcheck["Healthcheck Sidecar<br/>stdlib HTTP :9090<br/>(conditional)"]
                Stage2["stage2-hook.sh<br/>(UID remap, chown)"]
                ConfigSeed["00-hermes-dokku-config<br/>(config.yaml seed)"]
                Volume["/opt/data<br/>(persistent storage)"]
            end
        end

        subgraph "OmniRoute Host — 100.73.253.25"
            OmniRoute["OmniRoute LLM Gateway<br/>:20128"]
            UpstreamLLMs["Upstream LLM Providers<br/>(OpenAI, Anthropic, Z.AI, etc.)"]
        end
    end

    Client -->|"HTTP :9091<br/>Authorization: Bearer KEY"| Nginx
    Nginx -->|"proxy_pass<br/>172.17.x.x:9091"| Gateway

    InitWrapper -->|"1. runs"| Stage2
    InitWrapper -->|"2. runs"| ConfigSeed
    InitWrapper -->|"3. starts (bg)"| Healthcheck
    InitWrapper -->|"4. exec (fg)"| Gateway

    Gateway -->|"POST /v1/chat/completions<br/>Authorization: Bearer sk-..."| OmniRoute
    OmniRoute -->|"routes to best provider"| UpstreamLLMs

    Volume -.->|"mounted"| Gateway
    Volume -.->|"mounted"| ConfigSeed

    style Client fill:#4CAF50,color:#fff
    style Nginx fill:#2196F3,color:#fff
    style Gateway fill:#FF9800,color:#fff
    style OmniRoute fill:#9C27B0,color:#fff
    style InitWrapper fill:#F44336,color:#fff
    style Volume fill:#607D8B,color:#fff
```

---

## 2. Container Process Model

The upstream Hermes image uses **s6-overlay** with `ENTRYPOINT ["/init", ...]`
which requires PID 1. Dokku's process supervisor runs the ENTRYPOINT as a child
process, causing `s6-overlay-suexec: fatal: can only run as pid 1`.

The solution is a **custom init wrapper** (`dokku/init-wrapper.sh`) that
replaces s6-overlay's `/init` and manually performs the initialization steps
that `/init` would have done.

```mermaid
flowchart TD
    Start["Dokku starts container<br/>ENTRYPOINT: /usr/local/bin/hermes-dokku-init"]

    Start --> A["1. Export PATH=/command:$PATH<br/>(s6 binaries live in /command)"]
    A --> B["2. Export S6_KEEP_ENV=1<br/>(tell with-contenv to keep current env<br/>instead of reading /run/s6/container_environment)"]
    B --> C["3. mkdir /run/s6 /run/service<br/>chown hermes:hermes"]
    C --> D["4. Run stage2-hook.sh<br/>(UID remap, /opt/data chown,<br/>skills sync, config migrate)"]

    D -->|"exit 0"| E["stage2 OK"]
    D -->|"exit 1 (non-fatal)"| F["log warning, continue<br/>(s6-applyuidgid fails without<br/>SETGID cap — most sub-ops are idempotent)"]

    E --> G["5. Re-assert /run/s6 ownership"]
    F --> G

    G --> H["6. Run 00-hermes-dokku-config<br/>(seed config.yaml on first boot)"]
    H --> I["7. Conditional: start healthcheck sidecar<br/>if HEALTHCHECK_PORT != API_SERVER_PORT"]

    I --> J["8. exec /opt/hermes/docker/main-wrapper.sh gateway run<br/>(replaces init wrapper process)"]
    J --> K["Gateway runs as foreground process<br/>Dokku tracks this PID"]

    K -.->|"SIGTERM"| L["trap: kill healthcheck, exit 0"]

    style Start fill:#F44336,color:#fff
    style D fill:#FF9800,color:#fff
    style J fill:#4CAF50,color:#fff
    style B fill:#2196F3,color:#fff
```

---

## 3. Request Flow — Chat Completion

```mermaid
sequenceDiagram
    participant C as Client
    participant N as Nginx (:9091)
    participant G as Hermes Gateway
    participant O as OmniRoute (:20128)
    participant L as Upstream LLM

    C->>N: POST /v1/chat/completions<br/>Authorization: Bearer HERMES_API_SERVER_KEY<br/>{"model":"auto/best-coding",<br/>"messages":[...]}
    N->>N: Match server_name<br/>hermes-agent.dokku-prod...
    N->>G: proxy_pass http://hermes-agent-9091

    G->>G: Validate API_SERVER_KEY<br/>against env var
    alt Invalid key
        G-->>N: 401 {"error":"gateway_auth_failed"}
        N-->>C: 401
    end

    G->>G: Load config.yaml<br/>(provider: custom, base_url: OmniRoute,<br/>api_key: sk-6d183...)
    G->>G: Build system prompt + tools<br/>(69 bundled skills)
    G->>O: POST /v1/chat/completions<br/>Authorization: Bearer sk-6d183...<br/>{"model":"auto/best-coding",<br/>"messages":[system, user, ...]}

    O->>O: Route to best provider<br/>(e.g., z-ai/glm-5.2 via nvidia)
    O->>L: Forward request to upstream
    L-->>O: Streaming response chunks
    O-->>G: SSE chunks<br/>(x-omniroute-model, latency, cost)

    G->>G: Collect response<br/>(non-streaming mode)
    G-->>N: 200 {"choices":[{"message":{"content":"Hello!"}}]}
    N-->>C: 200 JSON response

    Note over G,O: If OmniRoute returns 401:<br/>Gateway retries (api_max_retries=3)<br/>then surfaces error to client
```

---

## 4. Health Check Flow

```mermaid
flowchart LR
    subgraph "Dokku Deploy Check"
        HC1["app.json healthcheck<br/>type: startup<br/>path: /health<br/>attempts: 10<br/>wait: 30s<br/>timeout: 90s"]
    end

    subgraph "Container"
        GW["Gateway API Server<br/>:9091<br/>GET /health →<br/>{'status':'ok',<br/>'platform':'hermes-agent',<br/>'version':'0.19.0'}"]

        Sidecar["Healthcheck Sidecar<br/>:9090 (conditional)<br/>GET /health → 'ok'<br/>GET /health/deep → JSON"]
    end

    subgraph "Dokku Default"
        LC["Port listening check<br/>(from EXPOSE directive)<br/>expected: 9091"]
    end

    HC1 -->|"HTTP GET"| GW
    LC -->|"TCP connect"| GW

    Note1["Note: Sidecar only starts when<br/>HEALTHCHECK_PORT != API_SERVER_PORT<br/>Currently: both = 9091, so sidecar is SKIPPED<br/>Gateway's built-in /health suffices"]

    style GW fill:#4CAF50,color:#fff
    style Sidecar fill:#607D8B,color:#fff
    style Note1 fill:#FFF9C4
```

---

## 5. Network Topology

```mermaid
graph LR
    subgraph "Internet"
        Internet((Internet))
    end

    subgraph "Tailscale Mesh VPN"
        subgraph "Developer Machine"
            DevClient["Dev Machine<br/>100.x.x.x"]
        end

        subgraph "GCP Instance (agent-helper)"
            DokkuHost["Dokku Host<br/>100.100.104.101"]

            subgraph "Docker Bridge Network (172.17.0.0/16)"
                HermesContainer["hermes-agent.web.1<br/>172.17.0.x:9091"]
                OtherContainers["Other Dokku apps<br/>(backend-api, error-relay, etc.)"]
            end

            NginxProc["Nginx<br/>0.0.0.0:9091<br/>0.0.0.0:5000<br/>0.0.0.0:8080"]
        end

        subgraph "OmniRoute Host"
            OmniRouteHost["OmniRoute<br/>100.73.253.25:20128<br/>(standalone Docker, NOT Dokku)"]
        end
    end

    Internet -.->|"blocked<br/>(no public port)"| DokkuHost

    DevClient -->|"HTTP :9091"| DokkuHost
    DokkuHost --> NginxProc
    NginxProc -->|"upstream"| HermesContainer

    HermesContainer -->|"HTTP :20128<br/>(Tailscale)"| OmniRouteHost
    OmniRouteHost -->|"HTTPS"| Internet

    style DevClient fill:#4CAF50,color:#fff
    style DokkuHost fill:#2196F3,color:#fff
    style HermesContainer fill:#FF9800,color:#fff
    style OmniRouteHost fill:#9C27B0,color:#fff
    style Internet fill:#F44336,color:#fff
```

---

## 6. Docker Image Build Pipeline

```mermaid
flowchart TB
    subgraph "Local Development (macOS arm64)"
        LocalRepo["hermes-agent repo<br/>infra_openclaw/hermes/<br/>branch: dokku-deploy"]
        DockerfileUpstream["Dockerfile (upstream)<br/>363 lines, builds from source"]
        DockerfileDokku["Dockerfile.dokku (overlay)<br/>FROM localhost/hermes-agent:upstream<br/>+ init-wrapper, healthcheck, config seed"]
    end

    subgraph "Dokku Server (Linux amd64)"
        ServerRepo["/tmp/hermes-agent/<br/>git clone --depth 1"]
        UpstreamImage["localhost/hermes-agent:upstream<br/>2.63GB, amd64<br/>(built on server)"]
        DokkuImage["dokku/hermes-agent:latest<br/>(built by Dokku from Dockerfile.dokku)"]
    end

    subgraph "GitHub"
        GitHubFork["Securiteru/hermes-agent<br/>branch: dokku-deploy"]
    end

    LocalRepo -->|"git push origin"| GitHubFork
    GitHubFork -->|"git clone"| ServerRepo
    ServerRepo -->|"docker build -t<br/>localhost/hermes-agent:upstream ."| UpstreamImage

    LocalRepo -->|"git push gcp-dokku<br/>dokku-deploy:main"| DokkuPush["Dokku git receive hook"]
    DokkuPush -->|"builder-dockerfile<br/>dockerfile-path: Dockerfile.dokku"| DokkuBuild["docker build<br/>(DOCKER_BUILDKIT=0)"]
    DokkuBuild -->|"FROM localhost/hermes-agent:upstream"| UpstreamImage
    DokkuBuild -->|"+ overlay layers"| DokkuImage

    DokkuImage -->|"dokku ps:scale + deploy"| RunningContainer["hermes-agent.web.1<br/>(running)"]

    style UpstreamImage fill:#FF9800,color:#fff
    style DokkuImage fill:#4CAF50,color:#fff
    style RunningContainer fill:#2196F3,color:#fff
    style DokkuBuild fill:#9C27B0,color:#fff
```

---

## 7. Configuration & Secrets Flow

```mermaid
flowchart TB
    subgraph "Secrets (psst)"
        PsstHermesKey["HERMES_API_SERVER_KEY<br/>(gateway auth)"]
        PsstOmniKey["OMNIROUTE_API_KEY<br/>(LLM provider)"]
        PsstTelegram["TELEGRAM_BOT_TOKEN<br/>(currently unset)"]
    end

    subgraph "Dokku Config (dokku config:set)"
        EnvAPIKey["API_SERVER_KEY=28f96d..."]
        EnvCustomKey["CUSTOM_API_KEY=sk-6d183..."]
        EnvLLMKey["LLM_API_KEY=sk-6d183..."]
        EnvOpenAIKey["OPENAI_API_KEY=sk-6d183..."]
        EnvPort["API_SERVER_PORT=9091"]
        EnvHost["API_SERVER_HOST=0.0.0.0"]
        EnvUID["HERMES_UID=10000"]
        EnvGID["HERMES_GID=10000"]
        EnvDisableLazy["HERMES_DISABLE_LAZY_INSTALLS=1"]
        EnvPlatforms["GATEWAY_PLATFORMS=api_server"]
        EnvBuildKit["DOCKER_BUILDKIT=0"]
        EnvProxy["DOKKU_PROXY_PORT_MAP=http:9091:9091"]
        EnvPortVar["PORT=9091"]
    end

    subgraph "Persistent Volume (/opt/data)"
        ConfigYaml["config.yaml<br/>provider: custom<br/>base_url: http://100.73.253.25:20128/v1<br/>api_key: sk-6d183...<br/>default: auto/best-coding<br/>custom_providers: [omniroute entry]"]
        Sessions["sessions/<br/>(SQLite state.db, response_store.db)"]
        Skills["skills/<br/>(69 bundled)"]
        CronDB["cron/executions.db"]
    end

    subgraph "Dokku Storage Mount"
        Storage["/var/lib/dokku/data/storage/hermes-agent<br/>→ /opt/data<br/>(chown 10000:10000)"]
    end

    PsstHermesKey -.->|"psst set"| EnvAPIKey
    PsstOmniKey -.->|"psst set"| EnvCustomKey
    PsstOmniKey -.->|"psst set"| EnvLLMKey
    PsstOmniKey -.->|"psst set"| EnvOpenAIKey

    EnvAPIKey -.->|"injected at runtime"| ContainerEnv["Container Environment"]
    EnvCustomKey -.-> ContainerEnv
    EnvPort -.-> ContainerEnv

    Storage -->|"mount"| Volume["/opt/data (in container)"]
    Volume --> ConfigYaml
    Volume --> Sessions
    Volume --> Skills
    Volume --> CronDB

    ConfigYaml -->|"read by gateway"| Gateway["Hermes Gateway"]
    ContainerEnv --> Gateway

    style PsstHermesKey fill:#F44336,color:#fff
    style PsstOmniKey fill:#F44336,color:#fff
    style ConfigYaml fill:#FF9800,color:#fff
    style Storage fill:#607D8B,color:#fff
    style Gateway fill:#4CAF50,color:#fff
```

---

## 8. Deployment Sequence

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant Git as GitHub
    participant Srv as Dokku Server
    participant Docker as Docker Daemon
    participant Nginx as Nginx
    participant App as hermes-agent.web.1

    Note over Dev,Srv: Phase 1: Build upstream image on server (one-time)

    Dev->>Git: git push origin dokku-deploy
    Dev->>Srv: ssh dokku@100.100.104.101<br/>git clone --depth 1 -b dokku-deploy<br/>https://github.com/Securiteru/hermes-agent.git
    Srv->>Docker: docker build -t localhost/hermes-agent:upstream .
    Docker-->>Srv: Image built (2.63GB amd64)

    Note over Dev,Srv: Phase 2: Configure Dokku app

    Dev->>Srv: dokku builder-dockerfile:set hermes-agent<br/>dockerfile-path Dockerfile.dokku
    Dev->>Srv: dokku config:set hermes-agent<br/>API_SERVER_KEY=... CUSTOM_API_KEY=...<br/>API_SERVER_PORT=9091 PORT=9091<br/>DOKKU_PROXY_PORT_MAP=http:9091:9091<br/>DOCKER_BUILDKIT=0 ...
    Dev->>Srv: dokku storage:mount hermes-agent<br/>/var/lib/dokku/data/storage/hermes-agent:/opt/data

    Note over Dev,Srv: Phase 3: Deploy

    Dev->>Srv: git push gcp-dokku dokku-deploy:main
    Srv->>Srv: Pre-receive hook
    Srv->>Docker: docker build -f Dockerfile.dokku<br/>(DOCKER_BUILDKIT=0, legacy builder)
    Docker->>Docker: FROM localhost/hermes-agent:upstream<br/>(found locally, no registry pull)
    Docker->>Docker: COPY init-wrapper, healthcheck, config seed
    Docker->>Docker: Override ENTRYPOINT → hermes-dokku-init
    Docker-->>Srv: dokku/hermes-agent:latest

    Srv->>Docker: docker run (web.1)<br/>env vars injected<br/>/opt/data mounted
    Docker->>App: hermes-dokku-init runs<br/>→ stage2-hook → config seed → exec gateway

    Srv->>App: Healthcheck: GET /health (10 attempts, 30s wait)
    App-->>Srv: {"status":"ok"} (gateway built-in /health)

    Srv->>Nginx: Create nginx.conf<br/>listen 9091, proxy_pass hermes-agent-9091
    Nginx-->>Srv: nginx reloaded

    Srv->>Srv: Rename container to hermes-agent.web.1
    Srv->>Srv: Shut down old container (60s grace)
    Srv-->>Dev: Application deployed:<br/>http://hermes-agent...:9091
```

---

## 9. Key Design Decisions

```mermaid
mindmap
  root((Hermes on Dokku))
    s6-overlay Bypass
      Problem: /init requires PID 1
      Solution: Custom init-wrapper.sh
      S6_KEEP_ENV=1 preserves env
      stage2-hook runs non-fatally
      Gateway exec'd as foreground
    Image Build Strategy
      Upstream built on server (amd64)
      Not in registry (local only)
      DOCKER_BUILDKIT=0 for legacy builder
      Dockerfile.dokku = thin overlay
      Merge-friendly with upstream
    Port Layout
      Gateway API: 9091 (Dokku proxied)
      Healthcheck: 9090 (conditional sidecar)
      EXPOSE 9091 (Dokku listening check)
      No port 5000 (conflict with other apps)
    LLM Provider
      OmniRoute on Tailscale
      provider: custom in config.yaml
      api_key in config (not just env)
      auto/best-coding combo
      Routes to z-ai/glm-5.2 etc.
    Security
      Tailscale-only (no public port)
      API_SERVER_KEY auth required
      /opt/data persistent volume
      HERMES_UID=10000 non-root
      No Telegram (token conflict)
```

---

## 10. File Structure (Dokku Overlay)

```
hermes-agent/                          # Securiteru fork, branch: dokku-deploy
├── Dockerfile                         # Upstream (363 lines, unchanged)
├── Dockerfile.dokku                   # Dokku overlay (FROM upstream image)
├── Procfile                           # web: /opt/hermes/docker/main-wrapper.sh gateway run
├── app.json                           # Dokku healthchecks (startup /health)
├── .env.dokku.example                 # Env var schema (no secrets)
└── dokku/
    ├── init-wrapper.sh                # Custom PID-1 replacement (bypasses s6 /init)
    ├── healthcheck.py                 # Stdlib HTTP sidecar (/health, /health/deep)
    ├── 00-hermes-dokku-config         # First-boot config.yaml seed (cont-init.d)
    ├── UPGRADE.md                     # How to sync with upstream
    └── s6-rc.d/                       # (reference only, not used)
```

---

## 11. Verification Commands

```bash
# Health check (from Tailscale)
curl -sS http://100.100.104.101:9091/health
# → {"status":"ok","platform":"hermes-agent","version":"0.19.0"}

# List models (authenticated)
psst HERMES_API_SERVER_KEY -- bash -c \
  'curl -sS http://100.100.104.101:9091/v1/models \
   -H "Authorization: Bearer $HERMES_API_SERVER_KEY"'
# → {"object":"list","data":[{"id":"hermes-agent",...}]}

# Chat completion (authenticated)
psst HERMES_API_SERVER_KEY -- bash -c \
  'curl -sS http://100.100.104.101:9091/v1/chat/completions \
   -H "Authorization: Bearer $HERMES_API_SERVER_KEY" \
   -H "Content-Type: application/json" \
   -d "{\"model\":\"auto/best-coding\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello\"}],\"max_tokens\":10}"'
# → {"choices":[{"message":{"content":"Hello!"}}]}

# Container status
ssh dokku@100.100.104.101 "dokku ps:report hermes-agent"

# View logs
ssh dokku@100.100.104.101 "dokku logs hermes-agent -t"

# Restart
ssh dokku@100.100.104.101 "dokku ps:restart hermes-agent"

# Rebuild upstream image on server (after upstream changes)
ssh dokku@100.100.104.101 "cd /tmp/hermes-agent && git pull && docker build -t localhost/hermes-agent:upstream ."

# Redeploy (after pushing to dokku-deploy branch)
cd infra_openclaw/hermes && git push gcp-dokku dokku-deploy:main
```

---

## 12. Known Limitations & Future Work

| Item | Status | Notes |
|------|--------|-------|
| Telegram gateway | Disabled | `TELEGRAM_BOT_TOKEN` unset due to conflict with another bot instance. Re-enable with a dedicated token. |
| cAdvisor | Stopped | Was blocking nginx port 8080. Restart with `docker start cadvisor`. |
| SQLite WAL | Warning | Linked SQLite 3.46.1 has WAL-reset bug; using `journal_mode=DELETE`. Upgrade to 3.51.3+ via `hermes update`. |
| Terminal backend | Local (unsandboxed) | Gateway runs with full host terminal/file access. Consider `terminal.backend: docker` for sandboxing. |
| Image registry | None | Upstream image built locally on server. Consider pushing to GHCR for reproducibility. |
| HTTPS/TLS | None | Internal Tailscale only. Add Let's Encrypt if external access needed. |
| gbrain page | TODO | Capture reference page at `scenextras/hermes-agent-dokku-deploy`. |
