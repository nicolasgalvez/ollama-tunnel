#!/bin/sh
# model-init: pre-download the llama.cpp GGUF + mmproj into the shared Hugging
# Face cache (HF_HOME=/hf) and publish stable symlinks at /hf/llama-tunnel/ so
# llama-server has a fixed -m / --mmproj path despite the hashed cache layout.
#
# Files land in the *shared* HF hub cache (/hf/hub/...), so they dedup with
# ComfyUI and anything else speaking huggingface_hub. The same /hf volume is
# mounted into the llama container, so the symlinks resolve there too.
set -e

pip install --quiet --no-cache-dir "huggingface_hub[hf_transfer]"

python3 - <<'PY'
import os
from huggingface_hub import hf_hub_download

repo        = os.environ["LLAMA_HF_REPO"]
model_file  = os.environ["LLAMA_HF_FILE"]
mmproj_file = os.environ.get("LLAMA_MMPROJ_FILE", "").strip()

out = "/hf/llama-tunnel"
os.makedirs(out, exist_ok=True)

def fetch_and_link(filename, link_name):
    # hf_hub_download returns the resolved snapshot path (a symlink into the
    # blob store); we point our own stable name at it.
    src = hf_hub_download(repo_id=repo, filename=filename)
    dst = os.path.join(out, link_name)
    if os.path.islink(dst) or os.path.exists(dst):
        os.remove(dst)
    os.symlink(src, dst)
    print(f"linked {dst} -> {src}", flush=True)

print(f"downloading {repo} / {model_file}", flush=True)
fetch_and_link(model_file, "model.gguf")

if mmproj_file:
    print(f"downloading {repo} / {mmproj_file}", flush=True)
    fetch_and_link(mmproj_file, "mmproj.gguf")
else:
    print("no LLAMA_MMPROJ_FILE set — skipping mmproj (text-only)", flush=True)

print("model-init done", flush=True)
PY
