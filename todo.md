# llm-tunnel — todo

Goal: a docker-compose project, forked from
[`procyon-creative/ollama-tunnel`](https://github.com/procyon-creative/ollama-tunnel),
that can serve **either Ollama or llama.cpp (`llama-server`)** behind a
Cloudflare Tunnel with bearer-key auth. Backend is selectable; everything
downstream stays OpenAI-compatible (`/v1/...`), so clients don't change.

Motivation: Ollama can't run Qwen3.6-27B (VL model needs a separate `mmproj`
vision file), so we need a `llama-server` backend for that case. Same tunnel,
same auth, same client surface.

## Upstream structure (what we're forking)

`ollama-tunnel` compose has two services:
- `ollama` — `ollama/ollama:latest`, custom `ollama-entrypoint.sh` (serve → wait
  ready → `ollama pull $OLLAMA_MODEL`), port `11434`, GPU via
  `NVIDIA_VISIBLE_DEVICES=all`, models in `./.ollama-data`.
- `cloudflared` — `ghcr.io/procyon-creative/cloudflare-tunnel-init:latest`, reads
  `.env`, mounts `tunnel-config.json` (ro), `depends_on` ollama healthy.

`.env`: `CLOUDFLARE_API_TOKEN/ACCOUNT_ID/ZONE_ID`, `TUNNEL_NAME`, `API_KEY`
(bearer), `OLLAMA_MODEL`, `OLLAMA_HOSTNAME`.
Auth (bearer key) is enforced at the **Cloudflare edge**: on startup the
tunnel-init container creates a **WAF custom rule** (scoped to hostnames opted in
with `"auth": { "apiKey": true }` in `tunnel-config.json`) that blocks any
request lacking `Authorization: Bearer <API_KEY>` before it reaches the tunnel/
origin. No local proxy. Requires the CF token to have **Zone: Firewall Services
(Write)**. Implication: the check is backend-agnostic — ollama and llama-server
both get it for free once the hostname is opted in. `llama-server --api-key` is
only needed as **defense-in-depth** for LAN/local access that bypasses Cloudflare
(e.g. hitting `ruby:8080` directly).

## Design decisions

- [ ] **Backend toggle** via Docker Compose **profiles**: `--profile ollama` or
      `--profile llama` (set `COMPOSE_PROFILES` in `.env`). Only one backend runs.
- [ ] **Tunnel upstream must follow the backend.** `tunnel-config.json` hardcodes
      the origin service:port. Options:
      - templated config: `${BACKEND_URL}` → `http://ollama:11434` or
        `http://llama:8080`, rendered by tunnel-init; OR
      - give both backends the same compose **network alias** (e.g. `backend`) and
        a per-backend port var. Pick one — alias is simplest.
- [ ] **Reuse images, no custom Dockerfile if avoidable:**
      - ollama: `ollama/ollama:latest`
      - llama.cpp: `ghcr.io/ggml-org/llama.cpp:server-cuda` (CUDA 12;
        `:server-cuda13` for newer, `:server` for CPU-only)
      - tunnel: reuse `ghcr.io/procyon-creative/cloudflare-tunnel-init:latest`
- [ ] **Shared bearer key:** set `llama-server --api-key ${API_KEY}` so the key
      matches the ollama path. Decide whether auth lives at the tunnel, the
      backend, or both (defense in depth → both).
- [ ] **Shared model storage = host bind mount of the HF cache, not named
      volumes.** Host env var `HF_HOME` selects the dir and **defaults to the
      standard cache `${HOME}/.cache/huggingface`** — so downloads land in the same
      cache HF tools already populate, dedup'd and reused across llama, ComfyUI,
      and any HF-aware container. Bind-mounted into the containers as `HF_HOME=/hf`.
      (Compose interpolates `${HF_HOME:-${HOME}/.cache/huggingface}`; note `.env`
      itself doesn't expand `~`, so use `${HOME}`/absolute paths.)

## Tasks

### llama backend service
- [ ] Add `llama` service (profile `llama`), image `…/llama.cpp:server-cuda`.
- [ ] Command/args: `--host 0.0.0.0 --port 8080 --api-key ${API_KEY}
      -ngl ${NGL:-99} -c ${CTX:-8192}` + model selection.
- [ ] **Model fetch must be fully automated — no manual pre-download, ever.**
      Use a `model-init` sidecar that pulls the GGUF + mmproj from HF into a
      shared volume, then `llama-server` reads local files. Deterministic and
      independent of whether the image was built with curl/`-hf`.
      - `model-init`: tiny image with `hf`/`huggingface-cli` (e.g.
        `python:3.12-slim` + `pip install huggingface_hub`). With `HF_HOME=/hf`
        (the bind-mounted host cache) runs `hf download ${LLAMA_HF_REPO}
        ${LLAMA_HF_FILE}` (+ the mmproj) — lands in the **shared HF cache** (not a
        private `--local-dir`), idempotent, dedup'd with whatever ComfyUI/other
        tools already pulled.
      - Resolve the path: `hf download` prints the resolved cache path; capture it
        and publish a stable symlink (e.g. `/hf/llama-tunnel/model.gguf`,
        `…/mmproj.gguf`) so llama has a fixed `-m` target despite the hashed cache
        layout.
      - `llama` `depends_on: { model-init: { condition: service_completed_successfully } }`,
        `HF_HOME=/hf`, runs `-m /hf/llama-tunnel/model.gguf --mmproj /hf/llama-tunnel/mmproj.gguf`.
      - Optional simplification: if a one-line test shows `:server-cuda` *does*
        support `-hf`, collapse the sidecar and use `-hf ${LLAMA_HF_REPO}` +
        `LLAMA_ARG_HF_REPO` pointed at the same `HF_HOME=/hf` cache. Keep the
        sidecar as the default since it's guaranteed.
- [ ] GPU: `deploy.resources.reservations.devices` (nvidia) **and/or**
      `NVIDIA_VISIBLE_DEVICES=all` to match the ollama service.
- [ ] Healthcheck: `curl -fsS http://localhost:8080/health`.

### ollama backend service
- [ ] Move upstream `ollama` service under profile `ollama`.
- [ ] ollama keeps its **own** store (separate format, not the HF cache): host env
      `OLLAMA_MODELS_DIR` default `${HOME}/.ollama`, bind-mounted to `/root/.ollama`.
      ⚠️ it can't *directly* load a raw GGUF that llama uses, but it can import one
      from the shared cache via `ollama create -f Modelfile`
      (`FROM /hf/llama-tunnel/model.gguf`) — no re-download.

### shared model storage (bind mounts)
- [ ] **Core rationale:** one HF cache shared across all containers/VMs so drives
      don't each balloon with duplicate multi-GB downloads. ComfyUI nodes also pull
      via `huggingface_hub`, so they hit the same cache automatically.
- [ ] **HF cache** — host `${HF_HOME:-${HOME}/.cache/huggingface}` → container
      `/hf` with `HF_HOME=/hf`. Mounted into `model-init`, `llama`, and reused by
      ComfyUI etc. (point their `HF_HOME` at the same host dir). This is the one
      genuinely shared layout — anything speaking `huggingface_hub` dedups here.
      - Var is **`HF_HOME`** (current; defaults to `~/.cache/huggingface`). Setting
        it relocates hub blobs + xet + token together. NOT the deprecated
        `HUGGINGFACE_HUB_CACHE` → now `HF_HUB_CACHE` (only needed to split the hub
        cache out separately, which we don't). `TRANSFORMERS_CACHE` also deprecated.
      - Linux→Linux bind mounts: HF cache symlinks + our stable-path symlink work
        fine; no need for `HF_HUB_DISABLE_SYMLINKS` (that's for cross-OS NAS).
- [ ] **ollama store** — host `${OLLAMA_MODELS_DIR:-${HOME}/.ollama}`, its own
      mount/format (not dedup'd with HF, by ollama's design).
- [ ] Caveat to document: the bind mount shares *files & disk*, not a universal
      format — GGUF (llama) vs ollama blobs vs ComfyUI checkpoints differ. The HF
      cache is the shared win; ollama's own store is the unavoidable exception.

### tunnel / config
- [ ] Make `cloudflared` `depends_on` whichever backend is active (profiles handle
      this if both backends share the alias the tunnel points at).
- [ ] Update `tunnel-config.json` origin to the configurable backend URL.

### env + docs
- [ ] Extend `.env.example`: `COMPOSE_PROFILES`, `HF_HOME` (default
      `${HOME}/.cache/huggingface`), `OLLAMA_MODELS_DIR` (default `${HOME}/.ollama`),
      `LLAMA_HF_REPO`, `LLAMA_HF_FILE`, `LLAMA_MMPROJ_FILE`, `NGL`, `CTX`. Keep
      existing Cloudflare/`API_KEY` vars.
- [ ] README: document both backends, the Qwen3.6 VL + mmproj caveat, and the
      "Ollama can't do VL, use the llama profile" note.

### test
- [ ] Adapt `test-curl.sh` / `test.mjs` to hit `/v1/chat/completions` against
      whichever backend with `Authorization: Bearer $API_KEY`.
- [ ] Verify Qwen3.6-27B VL path end-to-end (text + image input) through the tunnel.

## Target host notes (ruby = 192.168.1.97)

- RTX 4060 Ti, **16 GB VRAM**; 31 GB RAM; ~83 GB free disk.
- Qwen3.6-27B-FP8 (~28–31 GB) will **not** fit 16 GB — use a **Q4_K_M GGUF**
  (~16–17 GB) with partial CPU offload (`-ngl` tuned down), plus the `mmproj`.
- Candidate GGUFs: `unsloth/Qwen3.6-27B-GGUF` (+ matching mmproj).
- Needs NVIDIA Container Toolkit installed on ruby for `--gpus`/device reservations.

## Open questions

- [x] Where does upstream enforce the bearer key? → Cloudflare WAF rule at the
      edge (created by tunnel-init), not a local proxy. Backend-agnostic.
- [~] Does `:server-cuda` ship `-hf`? Evidence conflicting (curl CLI + env
      support present, but build may omit libcurl). Decision: don't depend on it —
      `model-init` sidecar auto-downloads on `compose up`. Re-test later to maybe
      simplify.
- [ ] One tunnel hostname for both backends, or one per backend?
- [ ] Final home for this project (separate repo / fork of ollama-tunnel)?
