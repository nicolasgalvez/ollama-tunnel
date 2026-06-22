#!/bin/sh
# Verify the vision (VL) path end-to-end: sends an image + text prompt to
# /v1/chat/completions. Only meaningful against the llama backend running a
# VL model with its mmproj (ollama can't serve the Qwen3.6 VL projector).
# Reads OLLAMA_HOSTNAME and API_KEY from .env if present.
set -e

if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

HOSTNAME="${OLLAMA_HOSTNAME:-llm.example.com}"
KEY="${API_KEY:-sk-change-me}"
MODEL="${MODEL:-qwen3.6}"
# A small, stable public image. Override with IMAGE_URL=...
IMAGE_URL="${IMAGE_URL:-https://raw.githubusercontent.com/ggml-org/llama.cpp/master/media/llama0-logo.png}"

curl -s \
  -H "Authorization: Bearer ${KEY}" \
  -H "Content-Type: application/json" \
  "https://${HOSTNAME}/v1/chat/completions" \
  -d "{
    \"model\": \"${MODEL}\",
    \"messages\": [{
      \"role\": \"user\",
      \"content\": [
        { \"type\": \"text\", \"text\": \"What is in this image? Describe it briefly.\" },
        { \"type\": \"image_url\", \"image_url\": { \"url\": \"${IMAGE_URL}\" } }
      ]
    }]
  }" | jq
