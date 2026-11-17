# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current state

This is the [`procyon-creative/ollama-tunnel`](https://github.com/procyon-creative/ollama-tunnel)
repo checked out on branch **`feat/llama-backend`**. The feature being added:
make the backend **selectable between Ollama and llama.cpp (`llama-server`)**.
The upstream files (`docker-compose.yml`, `.env.example`, `ollama-entrypoint.sh`,
`tunnel-config.example.json`, `test.mjs`, `scripts/`) are the ollama-only
starting point — the work is to extend them, not build from scratch.

`todo.md` is the **design doc + task checklist** for this feature (untracked,
planning artifact). Read it in full before starting, and keep its checkboxes in
sync as things land. Note it predates reading the real repo, so verify its
assumptions against the actual files (see corrections below).

**Motivation:** Ollama can't run the Qwen3.6-27B VL model (needs a separate
`mmproj` vision file), so a `llama-server` backend is required for that case —
same tunnel, same auth, same OpenAI-compatible (`/v1/...`) client surface.

## Upstream baseline & where todo.md diverges

The todo was written before inspecting the repo; trust the real files over it:

- **Ollama store** is `${OLLAMA_DATA:-.ollama-data}` → `/root/.ollama` (a
  repo-local dir), **not** `${HOME}/.ollama` as the todo assumed.
- **`docker-compose.yml`** has no `profiles:` yet — adding the toggle means
  putting both backends behind profiles **without breaking the default
  `docker compose up`** (today it just starts ollama + cloudflared).
- **`tunnel-config.example.json`** hardcodes ingress to `http://ollama:11434`
  and shows **no** `"auth": {"apiKey": true}` field — the todo assumes that
  opt-in flag; confirm the cloudflare-tunnel-init schema actually supports it
  before relying on it.
- **`cloudflared` `depends_on: ollama` (healthy)** — this dependency and the
  ingress origin must follow whichever backend profile is active.
- Tests are a **Node harness** (`test.mjs` using the `ai` /
  `@ai-sdk/openai-compatible` SDK), plus `test-curl.sh`.

## Architecture (intended design)

Three concerns, wired together by Compose:

1. **Backend selection via Compose profiles.** `--profile ollama` or
   `--profile llama` (set `COMPOSE_PROFILES` in `.env`); only one backend runs.
   - `ollama`: `ollama/ollama:latest`, port `11434`, store at
     `${OLLAMA_DATA:-.ollama-data}` → `/root/.ollama` (ollama's own blob format,
     **not** the shared HF cache; the todo's `OLLAMA_MODELS_DIR`/`${HOME}/.ollama`
     is a *proposed* rename, not the current var).
   - `llama`: `ghcr.io/ggml-org/llama.cpp:server-cuda`, port `8080`, args like
     `--host 0.0.0.0 --port 8080 --api-key ${API_KEY} -ngl ${NGL:-99} -c ${CTX:-8192} -m ...`.

2. **Tunnel origin must follow the active backend.** `tunnel-config.json`
   hardcodes the origin service:port. Resolve this by giving both backends the
   same Compose **network alias** (e.g. `backend`) so `cloudflared` points at a
   stable target regardless of profile (preferred over templating the config).
   `cloudflared` reuses `ghcr.io/procyon-creative/cloudflare-tunnel-init:latest`.

3. **Auth is enforced at the Cloudflare edge, not a local proxy.** On startup
   tunnel-init creates a **WAF custom rule** (scoped to hostnames opted in with
   `"auth": { "apiKey": true }` in `tunnel-config.json`) that blocks any request
   lacking `Authorization: Bearer <API_KEY>` before it reaches the origin. This
   is **backend-agnostic** — both backends get it for free. Requires the CF
   token to have **Zone: Firewall Services (Write)**. `llama-server --api-key`
   is defense-in-depth for LAN access that bypasses Cloudflare (e.g. hitting
   `backend:8080` directly), and reuses the same `${API_KEY}`.

### Model storage — the key cross-cutting design

- **Shared HF cache via host bind mount, not named volumes.** Host
  `${HF_HOME:-${HOME}/.cache/huggingface}` → container `/hf` with `HF_HOME=/hf`.
  One cache shared across `llama`, the model-init sidecar, ComfyUI, and any
  HF-aware container so multi-GB downloads are dedup'd, not duplicated per drive.
  - The relevant var is **`HF_HOME`** (not the deprecated `HUGGINGFACE_HUB_CACHE`
    / `HF_HUB_CACHE` / `TRANSFORMERS_CACHE`).
  - `.env` does **not** expand `~` — use `${HOME}` or absolute paths.
- **Automated model fetch — no manual pre-download, ever.** A `model-init`
  sidecar (e.g. `python:3.12-slim` + `pip install huggingface_hub`) runs
  `hf download ${LLAMA_HF_REPO} ${LLAMA_HF_FILE}` (+ the mmproj) into the shared
  cache, then publishes **stable symlinks** (e.g. `/hf/llama-tunnel/model.gguf`,
  `.../mmproj.gguf`) so `llama-server` has a fixed `-m`/`--mmproj` target despite
  the hashed cache layout. `llama` uses
  `depends_on: { model-init: { condition: service_completed_successfully } }`.
  - The sidecar is the guaranteed default. Only collapse it into
    `llama-server -hf ...` if a test proves `:server-cuda` ships working libcurl
    `-hf` support (evidence is currently conflicting).
- ollama can import a GGUF from the shared cache via
  `ollama create -f Modelfile` (`FROM /hf/llama-tunnel/model.gguf`) — no
  re-download — but otherwise keeps its own store.

## Environment / config

`.env` (extend upstream's): keep Cloudflare vars
(`CLOUDFLARE_API_TOKEN`/`ACCOUNT_ID`/`ZONE_ID`, `TUNNEL_NAME`) and `API_KEY`
(the shared bearer key). Add: `COMPOSE_PROFILES`, `HF_HOME`,
`OLLAMA_MODELS_DIR`, `LLAMA_HF_REPO`, `LLAMA_HF_FILE`, `LLAMA_MMPROJ_FILE`,
`NGL`, `CTX`.

## Target deployment host (`ruby` = 192.168.1.97)

RTX 4060 Ti, **16 GB VRAM**, 31 GB RAM, ~83 GB free disk. Needs NVIDIA Container
Toolkit for GPU passthrough. Qwen3.6-27B-FP8 (~28–31 GB) will **not** fit 16 GB
— use a **Q4_K_M GGUF** (~16–17 GB, e.g. `unsloth/Qwen3.6-27B-GGUF`) with
partial CPU offload (tune `-ngl` down) plus the matching `mmproj`.

## Commands

- **Run (current):** `docker compose up` — starts ollama + cloudflared.
  **Run (target):** `docker compose --profile <ollama|llama> up`, or set
  `COMPOSE_PROFILES` in `.env`.
- **Test:** `npm test` (= `node test.mjs`) hits the tunnel hostname;
  `npm run test:local` (`node test.mjs --local`) hits the backend directly.
  Both use `Authorization: Bearer $API_KEY`. `test-curl.sh` is the shell
  equivalent. Verify the Qwen3.6-27B VL path end-to-end (text **and** image
  input) through the tunnel.
- **Config:** copy `.env.example` → `.env` and
  `tunnel-config.example.json` → `tunnel-config.json` (both gitignored).
