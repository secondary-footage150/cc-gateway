# CC Gateway

Reverse proxy that unifies device fingerprints for shared Claude Code accounts. All client machines appear as a single device to Anthropic.

## How it works

```
Clients (multiple machines)          CC Gateway              Anthropic
┌──────────┐                    ┌─────────────────┐
│ Machine A │─── env vars ──────│                 │
│ Machine B │─── route all ─────│  Rewrite:       │──── single ────▶ api.anthropic.com
│ Machine C │─── CC traffic ────│  device_id      │     device      (sees one Mac,
└──────────┘    to gateway      │  env 40+ fields │     identity     one user)
                                │  process metrics│
                                │  prompt text    │
                                │  HTTP headers   │
                                │  OAuth token    │
                                └─────────────────┘
```

Three-layer defense:

| Layer | Mechanism | Purpose |
|-------|-----------|---------|
| 1. Env vars | `ANTHROPIC_BASE_URL` + `DISABLE_NONESSENTIAL` | CC voluntarily routes to gateway |
| 2. Clash rules | `*.anthropic.com → REJECT` | Network-level block of direct connections |
| 3. Gateway rewrite | device_id / env / process / prompt | Clean all fingerprints |

## Gateway setup (admin, one-time)

### 1. Extract OAuth token

On a machine that has logged into Claude Code:

```bash
bash scripts/extract-token.sh
```

This extracts the `refresh_token` from macOS Keychain. The gateway manages token refresh — clients never need to login.

### 2. Configure

```bash
cp config.example.yaml config.yaml

# Generate a canonical device identity
npm run generate-identity
# Generate auth tokens for each client
npm run generate-token machine-a
npm run generate-token machine-b
```

Edit `config.yaml`:
- Paste the `refresh_token` from step 1
- Paste the generated `device_id`
- Paste client tokens
- Set `prompt_env` to match `env` (platform, shell, OS version)

### 3. TLS certificate

```bash
mkdir certs
# Self-signed (internal use):
openssl req -x509 -newkey rsa:2048 -keyout certs/key.pem -out certs/cert.pem -days 365 -nodes -subj '/CN=cc-gateway'
# Or use Let's Encrypt for a public domain
```

### 4. Start

```bash
# Docker (recommended)
docker-compose up -d

# Or direct
npm install && npm run build && npm start
```

### 5. Verify

```bash
# Health check (no auth)
curl https://gateway:8443/_health

# Rewrite verification (auth required)
curl -H "Authorization: Bearer <token>" https://gateway:8443/_verify
```

## Client setup (each machine)

### Option A: Script

```bash
bash <(curl -s https://gateway:8443/setup.sh)
# or
bash scripts/client-setup.sh
```

### Option B: Manual

Add to `~/.zshrc`:

```bash
export ANTHROPIC_BASE_URL="https://gateway.office.com:8443"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_OAUTH_TOKEN="gateway-managed"
export ANTHROPIC_CUSTOM_HEADERS="Proxy-Authorization: Bearer YOUR_TOKEN_HERE"
```

Then `source ~/.zshrc` and run `claude` normally. No browser login needed.

### Option C: + Clash (recommended)

Add to your ClashX config (see `clash-rules.yaml`):

```yaml
rules:
  - DOMAIN,gateway.office.com,DIRECT
  - DOMAIN-SUFFIX,anthropic.com,REJECT
  - DOMAIN-SUFFIX,claude.com,REJECT
  - DOMAIN-SUFFIX,claude.ai,REJECT
  - DOMAIN-SUFFIX,datadoghq.com,REJECT
```

This blocks any accidental direct connections to Anthropic as a safety net.

## What gets rewritten

| Field | Source | Rewrite |
|-------|--------|---------|
| `device_id` | `metadata.user_id` + event data | → canonical ID |
| `email` | event data | → canonical email |
| `env` (40+ fields) | event data | → entire object replaced |
| `process.constrainedMemory` | event data (base64) | → canonical RAM |
| `rss`, `heapUsed` | event data (base64) | → randomized in range |
| `User-Agent` | HTTP header | → canonical version |
| `x-anthropic-billing-header` | HTTP header + system prompt | → canonical fingerprint |
| `Platform`, `Shell`, `OS Version` | system prompt `<env>` block | → canonical values |
| `Working directory` | system prompt | → canonical path |
| `/Users/xxx/`, `/home/xxx/` | anywhere in prompt text | → canonical home path |
| `baseUrl` | event data (ANTHROPIC_BASE_URL leak) | → stripped |
| `Authorization` | HTTP header | → replaced with real OAuth token |

## Architecture

```
Client env vars:
  ANTHROPIC_BASE_URL=https://gateway:8443
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1  ← kills Datadog, GrowthBook, updates
  CLAUDE_CODE_OAUTH_TOKEN=gateway-managed      ← skips browser login
  ANTHROPIC_CUSTOM_HEADERS=Proxy-Authorization: Bearer <token>

Traffic flow:
  /v1/messages             → gateway rewrites body + headers → api.anthropic.com
  /api/event_logging/batch → gateway rewrites all events     → api.anthropic.com
  /api/claude_code/*       → gateway rewrites identity       → api.anthropic.com
  platform.claude.com      → NOT contacted (OAUTH_TOKEN skips it)
  datadoghq.com            → NOT contacted (DISABLE_NONESSENTIAL)
  mcp-proxy.anthropic.com  → NOT contacted (don't use MCP)
```

## Caveats

- **MCP**: If clients use official MCP servers, `mcp-proxy.anthropic.com` is contacted directly (hardcoded, doesn't follow `ANTHROPIC_BASE_URL`). Avoid MCP or use Clash to block it.
- **CC updates**: When Claude Code updates, new telemetry fields or endpoints may appear. Monitor the Clash REJECT logs for unexpected connection attempts.
- **Token expiry**: The gateway auto-refreshes the OAuth token. If the refresh token itself expires (rare), re-run `extract-token.sh` on the admin machine.
