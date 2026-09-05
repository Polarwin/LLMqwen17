# LLMqwen17 — on-demand Qwen3-1.7B local chat

System-wide local LLM on this Ubuntu host. A small Python gateway starts
`llama-server` for the first completion, proxies its native OpenAI-compatible
API, and stops it after five idle minutes. The model therefore does not occupy
RAM or VRAM continuously:

- local apps: `http://127.0.0.1:8349/v1`
- LAN devices: `https://192.168.0.9/llm/v1` (nginx + mkcert cert)
- Tailscale devices: reachable through the tailnet like any other service

The web UI presents task-focused modes while retaining a direct model selector:

| task | model | role |
|---|---|---|
| General chat | Qwen3.5-2B Q4_K_M | balanced everyday assistance |
| Code studio | Qwen2.5-Coder-3B Instruct Q4_K_M | coding and debugging |
| Math lab | Qwen2.5-Math-1.5B Instruct Q4_K_M | equations and mathematical reasoning |
| Document desk | Granite 3.3-2B Instruct Q4_K_M | analysis and extraction |
| Writing room | SmolLM3-3B Q4_K_M | prose and multilingual writing |
| Quick answer | Qwen3-1.7B Q4_K_M | low-latency simple requests |

Only the selected model is loaded. Changing tasks takes effect on the next
message and adds a small task-specific system instruction to that request.

## Hardware / OS requirements

- x86_64 Linux with systemd (developed on Ubuntu 26.04)
- **>= 4 GB free RAM while generating** (model 1.1 GB + context + OS headroom)
- Optional GPU offload: any Vulkan-capable GPU with **≥ 2 GB VRAM**
  (developed on a GeForce MX350, NVIDIA driver 580). Without a GPU the
  same setup runs CPU-only. `llama-server` uses automatic GPU offload, so it can
  fall back toward CPU if VRAM is already occupied.

## Required packages

| package | why |
|---|---|
| `curl` | installer downloads engine/model if missing |
| `libvulkan1` | Vulkan runtime used by the prebuilt llama.cpp binaries |
| `nvidia-driver-580` | optional, GPU offload on the MX350 |
| `nginx` | optional, LAN HTTPS exposure (`/llm/` location) |
| `python3` | dependency-free HTTP wrapper |
| `systemd` | wrapper service management |

Bundled in this directory (no build needed):

- `llama.cpp/` — prebuilt llama.cpp b10797 ubuntu-vulkan-x64 binaries
  (re-downloadable, see `engine_url` in `install.sh`)
- `models/Qwen3-1.7B-Q4_K_M.gguf` — the model (Apache 2.0), 1.1 GB
  (re-downloadable from unsloth/Qwen3-1.7B-GGUF, see `model_url`)

## Install

```bash
bash install.sh        # sudo is called inside where needed
```

The script:

1. copies the engine to `/opt/llm/llama.cpp`, moves the model to
   `/opt/llm/models/`
2. installs and starts the lightweight `llama-cli-wrapper.service` gateway on
   port **8349**, while disabling the old always-on `llama-server.service`
3. installs all six model GGUFs and deploys the chat page to
   `/opt/llm/chat/index.html`
4. appends an `/llm/` proxy location to the existing `homeserver` nginx
   server block (backup at `…/homeserver.bak-llm`, `nginx -t` checked,
   hot reload — other apps are not interrupted)

## Use it

```bash
curl http://127.0.0.1:8349/v1/chat/completions -H "Content-Type: application/json" -d '{
  "messages": [{"role": "user", "content": "Hello. Reply briefly. /no_think"}],
  "stream": true,
  "max_tokens": 200
}'
```

Notes for good results with a 1.7B model:

- **`/no_think`** in a prompt disables thinking when it is unnecessary.
- One generation runs at a time to avoid loading two model copies into the
  MX350's 2 GB VRAM. A concurrent request receives HTTP 429.
- The gateway lets `llama-server` apply the exact chat template from the GGUF;
  it does not parse REPL output or hand-build ChatML.
- Requests, including streaming SSE, are proxied without translating their
  OpenAI request or response bodies.
- The model stays warm for 300 seconds after a response, then the child server
  is terminated. Set `LLAMA_IDLE_TIMEOUT` in the systemd unit to change this.

Measured on this host (i5-10210U + MX350): ~3 s for a 200-token parse call.

## Manage

```bash
systemctl status llama-cli-wrapper
sudo systemctl restart llama-cli-wrapper
journalctl -u llama-cli-wrapper -f
```

## Uninstall

```bash
sudo systemctl disable --now llama-cli-wrapper.service
sudo rm /etc/systemd/system/llama-cli-wrapper.service
sudo systemctl daemon-reload
sudo rm -rf /opt/llm
# then remove the block between "# llm-begin" and "# llm-end" in
# /etc/nginx/sites-available/homeserver (or restore homeserver.bak-llm),
# sudo nginx -t && sudo systemctl reload nginx
```
