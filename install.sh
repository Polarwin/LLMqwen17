#!/usr/bin/env bash
# Install Qwen3-1.7B as a system-wide on-demand local LLM service:
# a small gateway starts llama-server on demand behind 127.0.0.1:8349; LAN HTTPS via
# the existing homeserver nginx block at https://192.168.0.9/llm/v1.
# Engine and model live in /opt/llm so any app on this host can use them.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
unit_target=/etc/systemd/system/llama-cli-wrapper.service
model=Qwen3-1.7B-Q4_K_M.gguf
model_url="https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/$model"
engine_url="https://github.com/ggml-org/llama.cpp/releases/download/b10797/llama-b10797-bin-ubuntu-vulkan-x64.tar.gz"

# engine: llama-b10797 prebuilt Vulkan binaries must be here (see README)
if [[ ! -f "$here/llama.cpp/llama-server" ]]; then
    echo "llama.cpp engine missing, downloading from:" >&2
    echo "  $engine_url" >&2
    curl -fSL "$engine_url" | tar -xz -C "$here"
    mv "$here/llama-b10797" "$here/llama.cpp"
fi
# model: 1.1G; download if not shipped with this directory
if [[ ! -f "$here/models/$model" && ! -f "/opt/llm/models/$model" ]]; then
    echo "model $model missing, downloading from:" >&2
    echo "  $model_url" >&2
    mkdir -p "$here/models"
    curl -fSL -o "$here/models/$model" "$model_url"
fi

sudo install -d -m 0755 /opt/llm /opt/llm/models /opt/llm/chat
# engine: copy (keeps colocated .so files working via rpath $ORIGIN)
sudo cp -a "$here/llama.cpp" /opt/llm/llama.cpp
# model: move into /opt/llm (1.1G — no reason to keep two copies)
if [[ -f "$here/models/$model" ]]; then
    sudo mv "$here/models/$model" "/opt/llm/models/$model"
fi
sudo install -m 0755 "$here/llama-cli-backend.py" /opt/llm/llama-cli-backend.py
sudo install -m 0644 "$here/chat/index.html" /opt/llm/chat/index.html
sudo install -m 0644 "$here/llama-cli-wrapper.service" "$unit_target"
sudo systemctl daemon-reload
sudo systemctl disable --now llama-server.service 2>/dev/null || true
sudo systemctl enable llama-cli-wrapper.service
# restart, not just "enable --now": a rerun must pick up changed flags —
# "enable --now" leaves an already-active service on the old command line
sudo systemctl restart llama-cli-wrapper.service

# LAN HTTPS access via the existing homeserver nginx block (mkcert CA):
# append the /llm/ proxy snippet before the closing brace of the 443 server
# (the closing brace is the last line of that file; verified by the guard).
nginx_conf=/etc/nginx/sites-available/homeserver
if sudo grep -q "# llm-begin" "$nginx_conf"; then
    echo "nginx /llm/ location already present, skipping"
else
    [[ $(sudo tail -n 1 "$nginx_conf") == "}" ]] \
        || { echo "unexpected nginx file ending, refusing to edit" >&2;
             exit 1; }
    tmp=$(mktemp)
    sudo sh -c "head -n -1 '$nginx_conf'" > "$tmp"
    cat "$here/nginx-llm-snippet.conf" >> "$tmp"
    echo "}" >> "$tmp"
    sudo cp -a "$nginx_conf" "$nginx_conf.bak-llm"
    sudo install -m 0644 "$tmp" "$nginx_conf"
    rm -f "$tmp"
    sudo nginx -t
    sudo systemctl reload nginx
    echo "nginx: /llm/ -> 127.0.0.1:8349 installed (backup: $nginx_conf.bak-llm)"
fi

sudo systemctl --no-pager --full status llama-cli-wrapper.service
