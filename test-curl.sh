#!/bin/sh
# Test the tunnel (either backend) with API key auth.
# Reads OLLAMA_HOSTNAME and API_KEY from .env if present.
set -e

if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

HOSTNAME="${OLLAMA_HOSTNAME:-llm.example.com}"
KEY="${API_KEY:-sk-change-me}"
MODEL="${MODEL:-${OLLAMA_MODEL:-tinyllama}}"

curl -s \
  -H "Authorization: Bearer ${KEY}" \
  -H "Content-Type: application/json" \
  "https://${HOSTNAME}/v1/chat/completions" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello\"}]}" | jq
