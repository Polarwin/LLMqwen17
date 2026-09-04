#!/usr/bin/env bash
# Install the static chat UI (chat/index.html) into /opt/llm/chat and
# serve it via the homeserver nginx block at /chat/.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
nginx_conf=/etc/nginx/sites-available/homeserver

sudo install -d -m 0755 /opt/llm/chat
sudo install -m 0644 "$here/chat/index.html" /opt/llm/chat/index.html

if sudo grep -q "# chat-begin" "$nginx_conf"; then
    echo "nginx /chat/ location already present, skipping"
else
    [[ $(sudo tail -n 1 "$nginx_conf") == "}" ]] \
        || { echo "unexpected nginx file ending, refusing to edit" >&2; exit 1; }
    tmp=$(mktemp)
    sudo sh -c "head -n -1 '$nginx_conf'" > "$tmp"
    cat "$here/nginx-chat-snippet.conf" >> "$tmp"
    echo "}" >> "$tmp"
    sudo install -m 0644 "$tmp" "$nginx_conf"
    rm -f "$tmp"
    sudo nginx -t
    sudo systemctl reload nginx
    echo "nginx: /chat/ -> /opt/llm/chat installed"
fi

echo "chat UI: https://192.168.0.9/chat/"
