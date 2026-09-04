# LLMqwen17 — Qwen3-1.7B local LLM service

System-wide local LLM on this Ubuntu host (not tied to any single project).
llama.cpp serves **Qwen3-1.7B Q4_K_M** as an OpenAI-compatible API:

- local apps: `http://127.0.0.1:8349/v1`
- LAN devices: `https://192.168.0.9/llm/v1` (nginx + mkcert cert)
- Tailscale devices: reachable through the tailnet like any other service

## Hardware / OS requirements

- x86_64 Linux with systemd (developed on Ubuntu 26.04)
- **≥ 4 GB free RAM** (model 1.1 GB + context + OS headroom)
- Optional GPU offload: any Vulkan-capable GPU with **≥ 2 GB VRAM**
  (developed on a GeForce MX350, NVIDIA driver 580). Without a GPU the
  same setup runs CPU-only — change `-ngl 99` to `-ngl 0` in
  `llama-server.service`, expect roughly half the speed.

## Required packages

| package | why |
|---|---|
| `curl` | installer downloads engine/model if missing |
| `libvulkan1` | Vulkan runtime used by the prebuilt llama.cpp binaries |
| `nvidia-driver-580` | optional, GPU offload on the MX350 |
| `nginx` | optional, LAN HTTPS exposure (`/llm/` location) |
| `systemd` | service management |

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
2. installs and starts `llama-server.service` (port **8349**, localhost only;
   never use port 8000 on this host — 8000/8347/8349 are taken)
3. appends an `/llm/` proxy location to the existing `homeserver` nginx
   server block (backup at `…/homeserver.bak-llm`, `nginx -t` checked,
   hot reload — other apps are not interrupted)

## Use it

```bash
curl http://127.0.0.1:8349/v1/chat/completions -H "Content-Type: application/json" -d '{
  "messages": [{"role": "user", "content": "你好，介绍一下你自己。 /no_think"}],
  "chat_template_kwargs": {"enable_thinking": false},
  "max_tokens": 200
}'
```

Notes for good results with a 1.7B model:

- **`/no_think`** (or `chat_template_kwargs.enable_thinking=false`) —
  thinking mode is slow and unnecessary for simple tasks
- **JSON Schema** (`response_format`) to force structured output — llama.cpp
  enforces it via constrained decoding
- annotate closed-set candidate lists with **pinyin** when matching
  Chinese speech transcripts
- the server caches the prompt prefix — keep the static part of the prompt
  first for much faster repeat calls

Measured on this host (i5-10210U + MX350): ~3 s for a 200-token parse call.

## Manage

```bash
systemctl status llama-server
sudo systemctl restart llama-server
journalctl -u llama-server -f
```

## Uninstall

```bash
sudo systemctl disable --now llama-server.service
sudo rm /etc/systemd/system/llama-server.service
sudo systemctl daemon-reload
sudo rm -rf /opt/llm
# then remove the block between "# llm-begin" and "# llm-end" in
# /etc/nginx/sites-available/homeserver (or restore homeserver.bak-llm),
# sudo nginx -t && sudo systemctl reload nginx
```
