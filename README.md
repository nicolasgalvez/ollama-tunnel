# llm-tunnel

Run **Ollama or llama.cpp** behind a Cloudflare Tunnel with API key auth. Expose
your local or remote GPU to any OpenAI-compatible client (Brave Leo, Continue,
LiteLLM, etc.) with just a URL and an API key. The backend is selectable; the
client surface (`/v1/...`, `Authorization: Bearer <key>`) is identical either way.

Uses [cloudflare-tunnel-init](https://github.com/procyon-creative/cloudflare-tunnel-init)
for automated tunnel + edge-auth setup.

## Why two backends

Ollama is the simplest path for text models. But it can't serve a vision-language
(VL) model that needs a separate `mmproj` projector file — e.g. **Qwen3.6-27B VL**.
For that, run the **llama.cpp** backend, which loads the GGUF + `mmproj` and speaks
the same OpenAI API. Same tunnel, same auth, same clients.

## How it works

- **Backend toggle** via Compose **profiles**: only `ollama` *or* `llama` runs.
  Both share the network alias `backend`, so the tunnel always targets a stable
  `http://backend:11434` and nothing else changes when you switch.
- **Auth at the Cloudflare edge.** On startup, tunnel-init creates a WAF custom
  rule (for each hostname opted in with `"auth": { "apiKey": true }`) that blocks
  any request lacking `Authorization: Bearer <API_KEY>` before it reaches the
  origin. Backend-agnostic. `llama-server --api-key` adds defense-in-depth for
  LAN access that bypasses the tunnel.
- **Automated model fetch (llama).** llama-server downloads the GGUF named by
  `LLAMA_ARG_HF_REPO`/`LLAMA_ARG_HF_FILE` (and its `mmproj`, when the repo has one)
  into the **shared Hugging Face cache** (`HF_HOME`), dedup'd with ComfyUI and other
  HF tools. Every server setting is an `LLAMA_ARG_*` variable in `.env`.

## Quick start

```sh
git clone git@github.com:nicolasgalvez/ollama-tunnel.git
cd ollama-tunnel
cp .env.example .env
cp tunnel-config.example.json tunnel-config.json
```

Edit `.env` (Cloudflare credentials, `API_KEY`, and `COMPOSE_PROFILES`) and
`tunnel-config.json` (your hostname). Then:

```sh
# Ollama backend (default; COMPOSE_PROFILES=ollama in .env)
docker compose up -d

# llama.cpp backend (downloads the model on first run)
docker compose --profile llama up -d   # or set COMPOSE_PROFILES=llama in .env
```

Use it:

- **URL:** `https://your-hostname.example.com/v1/chat/completions`
- **API key:** whatever you set in `API_KEY`
- **Model:** ollama → any pulled model (`tinyllama`, `qwen3:30b`, …);
  llama → the GGUF named by `LLAMA_ARG_HF_REPO` (the `model` field is ignored).

## Choosing a llama model

Defaults target a **16 GB GPU** (e.g. RTX 4060 Ti). Set in `.env`:

| Goal | `LLAMA_ARG_HF_REPO` / `LLAMA_ARG_HF_FILE` / `LLAMA_ARG_MMPROJ_AUTO` |
|------|--------------------------------------------------------|
| Qwen3.6-27B VL (default, dense, context-efficient) | `unsloth/Qwen3.6-27B-GGUF` · `Qwen3.6-27B-IQ4_XS.gguf` · `true` |
| Qwen3-VL-30B-A3B (MoE, faster on a constrained card) | `unsloth/Qwen3-VL-30B-A3B-Instruct-GGUF` · `Qwen3-VL-30B-A3B-Instruct-IQ4_XS.gguf` · `true` |

Tune `LLAMA_ARG_N_GPU_LAYERS` down if you hit OOM, and `LLAMA_ARG_CTX_SIZE` for context size. `HF_HOME` and `HF_TOKEN` come from the host's environment when `.env` doesn't set them (when both set one, Compose uses the host's).

> **llama.cpp build note:** Qwen3.6-27B needs a recent build (≥ `b8954`), and its
> low-bit quants can output gibberish on **CUDA 13.2** — this compose pins the
> **CUDA 12** image (`:server-cuda`). Pin a specific image digest in production.

## GPU support

Both backends request the GPU via the NVIDIA Container Toolkit. On Linux, set the
nvidia runtime as default:

```sh
sudo nvidia-ctk runtime configure --runtime=docker --set-as-default
sudo systemctl restart docker
```

The `llama` service also declares `deploy.resources.reservations.devices` for the
GPU. On Mac the env var is ignored and ollama runs on CPU; llama.cpp CUDA requires
an NVIDIA GPU.

## Model storage

- **llama (HF cache):** `HF_HOME` (default `~/.cache/huggingface`) bind-mounted to
  `/hf`. Shared with any HF-aware tool (ComfyUI, transformers, …) so multi-GB
  GGUFs aren't duplicated. `.env` does **not** expand `~` — use an absolute path.
- **ollama:** its own store at `OLLAMA_DATA` (default `.ollama-data/`) →
  `/root/.ollama`. Different on-disk format, not shared with the HF cache. Point
  it at a host install to reuse models: `OLLAMA_DATA=/usr/share/ollama/.ollama`.

## Shell integration

Wrap the `ollama` CLI to run through docker compose transparently:

```sh
./scripts/shell-setup.sh install
source ~/.zshrc   # or ~/.bashrc
ollama list / pull / run / ps   # services auto-start if not running
```

## Environment variables

| Variable               | Required | Default                     | Description |
|------------------------|----------|-----------------------------|-------------|
| `CLOUDFLARE_API_TOKEN` | Yes      |                             | Cloudflare API token |
| `CLOUDFLARE_ACCOUNT_ID`| Yes      |                             | Cloudflare account ID |
| `CLOUDFLARE_ZONE_ID`   | Yes      |                             | Zone ID for DNS |
| `TUNNEL_NAME`          | Yes      |                             | Name for the tunnel |
| `API_KEY`              | No       |                             | Bearer token (edge WAF + llama `--api-key`) |
| `COMPOSE_PROFILES`     | No       | `ollama`                    | Active backend: `ollama` or `llama` |
| `OLLAMA_HOSTNAME`      | No       | `llm.example.com`           | Public tunnel hostname (test scripts) |
| `OLLAMA_MODEL`         | No       | `tinyllama`                 | ollama: model to pull on start |
| `OLLAMA_DATA`          | No       | `.ollama-data`              | ollama: model store path |
| `HF_HOME`              | No       | `~/.cache/huggingface`      | llama: shared HF cache (absolute path) |
| `LLAMA_ARG_HF_REPO`    | Yes (llama) | `unsloth/Qwen3.6-27B-GGUF` | llama: HF repo to fetch |
| `LLAMA_ARG_HF_FILE`    | No       | `Qwen3.6-27B-IQ4_XS.gguf`   | llama: GGUF filename (overrides the repo's default quant) |
| `LLAMA_ARG_MMPROJ_AUTO` | No      | `true`                      | llama: fetch and load the repo's mmproj; `false` for text-only models |
| `LLAMA_ARG_N_GPU_LAYERS` | No     | `48`                        | llama: GPU layers to offload |
| `LLAMA_ARG_CTX_SIZE`   | No       | `16384`                     | llama: context size |
| `LLAMA_HOST_PORT`      | Yes (llama) | `11434`                  | llama: host port to publish |
| other `LLAMA_ARG_*`    | No       |                             | any llama-server option, per llama.cpp's `tools/server/README.md` |

## Testing

```sh
# Text, via curl (through the tunnel)
./test-curl.sh

# Vision (VL) path — image + text, llama backend only
./test-vision.sh

# Via AI SDK
npm install
npm run test:local    # direct to localhost:11434
npm test              # through the tunnel
```

## License

MIT
