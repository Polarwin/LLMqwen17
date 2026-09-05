#!/usr/bin/env bash
# Install Qwen3-1.7B as a system-wide on-demand local LLM service:
# a small gateway starts llama-server on demand behind 127.0.0.1:8349; LAN HTTPS via
# the existing homeserver nginx block at https://192.168.0.9/llm/v1.
# Engine and model live in /opt/llm so any app on this host can use them.
set -euo pipefail
trap 'echo "ERROR: installation failed at line $LINENO" >&2' ERR

step() {
    printf '\n==> %s\n' "$1"
}

here=$(cd "$(dirname "$0")" && pwd)
unit_target=/etc/systemd/system/llama-cli-wrapper.service
models=(
    Qwen3.5-2B-Q4_K_M.gguf
    qwen2.5-coder-3b-instruct-q4_k_m.gguf
    Qwen2.5-Math-1.5B-Instruct-Q4_K_M.gguf
    granite-3.3-2b-instruct-Q4_K_M.gguf
    Qwen3-1.7B-Q4_K_M.gguf
    SmolLM3-Q4_K_M.gguf
)
model_urls=(
    "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf"
    "https://huggingface.co/Qwen/Qwen2.5-Coder-3B-Instruct-GGUF/resolve/main/qwen2.5-coder-3b-instruct-q4_k_m.gguf"
    "https://huggingface.co/second-state/Qwen2.5-Math-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-Math-1.5B-Instruct-Q4_K_M.gguf"
    "https://huggingface.co/ibm-granite/granite-3.3-2b-instruct-GGUF/resolve/main/granite-3.3-2b-instruct-Q4_K_M.gguf"
    "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf"
    "https://huggingface.co/ggml-org/SmolLM3-3B-GGUF/resolve/main/SmolLM3-Q4_K_M.gguf"
)
engine_url="https://github.com/ggml-org/llama.cpp/releases/download/b10797/llama-b10797-bin-ubuntu-vulkan-x64.tar.gz"

step "Checking llama.cpp engine"
# engine: llama-b10797 prebuilt Vulkan binaries must be here (see README)
if [[ ! -f "$here/llama.cpp/llama-server" ]]; then
    echo "Downloading llama.cpp b10797 Vulkan build"
    curl -fL --progress-bar "$engine_url" | tar -xz -C "$here"
    mv "$here/llama-b10797" "$here/llama.cpp"
else
    echo "Found local llama.cpp engine"
fi

step "Checking model files"
# models: download any that are neither staged here nor already installed
mkdir -p "$here/models"
for i in "${!models[@]}"; do
    model=${models[$i]}
    model_url=${model_urls[$i]}
    if [[ ! -f "$here/models/$model" && ! -f "/opt/llm/models/$model" ]]; then
        echo "Downloading $model"
        partial="$here/models/$model.part"
        rm -f "$partial"
        if curl -fL --retry 3 --progress-bar -o "$partial" "$model_url"; then
            mv "$partial" "$here/models/$model"
        else
            rm -f "$partial"
            echo "Download failed: $model" >&2
            exit 1
        fi
    elif [[ -f "/opt/llm/models/$model" ]]; then
        echo "Already installed: $model"
    else
        echo "Ready to install: $model"
    fi
done

step "Installing engine, models, gateway, and web UI"
sudo install -d -m 0755 /opt/llm /opt/llm/models /opt/llm/chat
# engine: copy (keeps colocated .so files working via rpath $ORIGIN)
sudo cp -a "$here/llama.cpp" /opt/llm/llama.cpp
# models: move staged GGUFs into /opt/llm (no reason to keep two copies)
for model in "${models[@]}"; do
    if [[ -f "$here/models/$model" ]]; then
        sudo mv "$here/models/$model" "/opt/llm/models/$model"
    fi
done
sudo install -m 0755 "$here/llama-cli-backend.py" /opt/llm/llama-cli-backend.py
sudo install -m 0644 "$here/chat/index.html" /opt/llm/chat/index.html
sudo install -m 0644 "$here/llama-cli-wrapper.service" "$unit_target"

step "Starting the on-demand gateway"
sudo systemctl daemon-reload
sudo systemctl disable --now llama-server.service 2>/dev/null || true
sudo systemctl enable llama-cli-wrapper.service
# restart, not just "enable --now": a rerun must pick up changed flags —
# "enable --now" leaves an already-active service on the old command line
sudo systemctl restart llama-cli-wrapper.service

step "Configuring nginx"
# LAN HTTPS access via the existing homeserver nginx block (mkcert CA):
# append the /llm/ proxy snippet before the closing brace of the 443 server
# (the closing brace is the last line of that file; verified by the guard).
nginx_conf=/etc/nginx/sites-available/homeserver
if sudo grep -q "# llm-begin" "$nginx_conf"; then
    echo "Existing nginx /llm/ location found"
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
    echo "Installed nginx route: /llm/ -> 127.0.0.1:8349"
    echo "Nginx backup: $nginx_conf.bak-llm"
fi

step "Installation complete"
printf 'Gateway service: %s\n' "$(systemctl is-active llama-cli-wrapper.service)"
printf 'Local API:       http://127.0.0.1:8349/v1\n'
printf 'LAN API:         https://192.168.0.9/llm/v1\n'
printf 'Web chat:        https://192.168.0.9/chat/\n'
echo "Installed models:"
for model in "${models[@]}"; do
    printf '  %-34s %s\n' "$model" "$(du -h "/opt/llm/models/$model" | cut -f1)"
done
echo "The model loads on the first chat request and unloads after 300 seconds idle."
