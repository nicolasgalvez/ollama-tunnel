import 'dotenv/config';
import { createOpenAICompatible } from '@ai-sdk/openai-compatible';
import { streamText } from 'ai';

// Works against either backend (ollama or llama.cpp) — both are OpenAI-compatible
// on :11434 and gated by the same Authorization: Bearer <API_KEY>.
const isLocal = process.argv.includes('--local');

const backend = createOpenAICompatible({
  name: 'llm-tunnel',
  baseURL: isLocal
    ? 'http://localhost:11434/v1'
    : `https://${process.env.OLLAMA_HOSTNAME}/v1`,
  apiKey: isLocal ? 'unused' : process.env.API_KEY,
});

// For ollama the model name selects the model; llama.cpp serves whatever was
// loaded and ignores the value, so any string works there.
const model = backend(process.env.MODEL || process.env.OLLAMA_MODEL || 'tinyllama');

const { textStream } = streamText({
  model,
  prompt: 'Explain quantum tunneling in one paragraph.',
});

for await (const chunk of textStream) {
  process.stdout.write(chunk);
}
console.log();
