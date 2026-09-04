# Local LLM Web Chat — rebuild on `llama-cli` (design notes for Codex)

## Goal

Replace the current `llama-server` (always-on HTTP daemon) backend with
`llama-cli` (spawned on demand) as the engine behind the web chat UI, so the
model is only loaded into RAM/VRAM while actually being used, not 24/7.

The existing two-column chat page (`chat/index.html`) should be preserved —
left sidebar of saved conversations (collapsible, `localStorage`-backed),
right pane the live chat — just repointed at whatever new backend replaces
`llama-server`'s HTTP API.

## Current state

- `llama-server.service` is **stopped and disabled** (was `-ngl 99 -c 8192`
  on port 8349, OpenAI-compatible API). It is not coming back automatically;
  treat port 8349 as free.
- `chat/index.html` (this repo) is deployed as static files to
  `/opt/llm/chat/` and served by nginx at `https://192.168.0.9/chat/`
  (`alias /opt/llm/chat/;` in `/etc/nginx/sites-available/homeserver`,
  `chat-begin`/`chat-end` markers). It currently calls a hardcoded
  `/llm/v1/chat/completions` / `/llm/v1/models` path, which nginx proxies to
  `127.0.0.1:8349` — that proxy target won't be running anymore, so either
  the frontend's API base or the nginx `llm-begin`/`llm-end` block needs to
  point at whatever new backend replaces it.
- Engine + model live in `/opt/llm/llama.cpp/` and `/opt/llm/models/`:
  - `/opt/llm/llama.cpp/llama-cli`
  - `/opt/llm/llama.cpp/llama-server` (still installed, just not running —
    keep it around as a fallback / for comparison)
  - `/opt/llm/models/Qwen3-1.7B-Q4_K_M.gguf`
- `llama.cpp` build: b10797 (commit 832fd6f17), Vulkan backend.

## Hardware constraints (why this matters)

- CPU: i5-10210U (4C/8T). RAM: 14 GB total.
- GPU: NVIDIA MX350, **2048 MiB VRAM total** — this is the tight resource.
  With nothing else loaded, a fresh `llama-cli` process auto-offloads to
  ~1.2 GB VRAM for this model (measured). Don't assume more headroom than
  that is available; a second concurrent instance (e.g. testing while an
  old one is still open) will make `-ngl auto` back off and fall back
  toward CPU, which is much slower.
- Single-user, LAN-only tool. No need to design for concurrent multi-user
  load — one active generation at a time is fine.

## `llama-cli` reference (verified on this build)

Basic invocation:

```bash
/opt/llm/llama.cpp/llama-cli -m /opt/llm/models/Qwen3-1.7B-Q4_K_M.gguf
```

Things confirmed by testing, not assumed:

- **No HTTP/JSON API.** It's an interactive stdin/stdout REPL. Any web
  backend has to spawn it as a child process and talk to it over pipes —
  there is nothing to `curl`.
- **Conversation mode is effectively always on** in this build — there is
  no `-cnv`/`-no-cnv` flag anymore (checked `--help`; not present). What
  *is* available:
  - `-st, --single-turn` — run one turn (using `--prompt`/`-p` as the
    first user message) and exit, instead of dropping into the REPL.
    Good for a stateless, one-shot request/response.
  - `--jinja` / `--no-jinja` (jinja template application, **default
    enabled**) — with `--no-jinja`, `-p` is used as the raw prompt text
    with no chat-template wrapping applied. This is the mechanism to use
    for feeding a full multi-turn conversation in one shot (see below).
  - `-sys, --system-prompt PROMPT` / `-sysf, --system-prompt-file FNAME`.
  - `--reasoning-format FORMAT` — controls whether `<think>…</think>`
    content is emitted/extracted; worth using instead of the frontend's
    current manual regex-split-and-dim approach (check `--help` for the
    exact accepted values on this build before wiring it up).
- **No session/KV-cache persistence flag.** Older llama.cpp had
  `--prompt-cache <file>` to save/restore exact KV-cache state between
  runs; this build's `llama-cli --help` has no such flag (checked — only
  cache-related flags are `--cache-type-k/v`, `--cache-ram`,
  `--cache-list`, none of which persist conversation state to disk).
  **Consequence: there is no cheap way to instantly resume a past
  conversation's exact model state across process restarts.** Resuming a
  saved conversation means re-feeding its transcript as text, which costs
  prompt-eval time proportional to that transcript's length (prompt eval
  was ~34 tok/s vs ~14 tok/s generation in an earlier CPU-fallback test;
  expect better on GPU, but it's not free, and it grows with history).
- **Raw stdout is not clean output.** A run prints REPL furniture around
  the reply: an initial banner (build/model/modalities + available
  slash-commands), a `>` prompt echoing the input, a `[Start thinking]`
  marker before reasoning content, and a trailing
  `[ Prompt: N t/s | Generation: N t/s ]` timing footer. Whatever spawns
  this needs to parse/strip that, not forward it verbatim.
- Built-in slash-commands in the REPL: `/exit`, `/regen`, `/clear`,
  `/read <file>`, `/glob <pattern>`.
- Default `-ngl` is `auto` (fits layers to free VRAM at startup) — do not
  hardcode `-ngl 99` the way `llama-server.service` did, since a wrapper
  process may start while VRAM is partially occupied by a prior
  still-shutting-down instance; `auto` degrades gracefully (falls back
  toward CPU) instead of failing.

## Backend architecture needed

A browser can't spawn processes, so something has to sit between
`chat/index.html` and `llama-cli`. Two viable shapes — pick one, don't try
to do both:

### Option A — stateless, spawn-per-message (recommended for this project)

For each user message, the backend:
1. Takes the full conversation array as already stored by the frontend in
   `localStorage` (this repo's UI already keeps this — see below).
2. Renders it to Qwen's ChatML-style prompt text itself (system + each
   turn as `<|im_start|>role\n...<|im_end|>\n`, ending in
   `<|im_start|>assistant\n`) — check the model's actual chat template
   (`gguf` metadata, or diff against what `--jinja` produces once) to get
   the format exactly right rather than guessing.
3. Spawns `llama-cli -m <model> --no-jinja -st -p "<rendered prompt>"`,
   captures stdout, strips the REPL furniture described above, streams the
   remaining generated text back to the browser as it arrives.

Pros: matches how the current localStorage-based multi-conversation
sidebar already works (state lives in the browser, not the process) —
switching conversations in the sidebar is just switching which stored
array gets sent next time, no server-side session to manage. Simple
process lifecycle: one spawn, one exit, no long-lived state to leak.

Cons: reprocesses the whole growing transcript every turn (cost grows
with conversation length — acceptable for a casual-use tool, not for long
sessions), and pays a ~1-2s model-load cost per message (measured cold
start) unless `--cache-ram`/OS page cache keeps the gguf hot between runs
(likely, since it's the same 1.1 GB file each time).

### Option B — one long-lived process, piped stdin

Keep a single `llama-cli` process open per active conversation, feed
messages into its stdin, read replies off stdout by watching for the `>`
prompt to reappear (end of turn).

Pros: no model reload per message, no manual prompt templating (native
`-cnv`-style flow handles it).
Cons: only one live conversation at a time per process; switching to a
different saved conversation in the sidebar means either killing/relaunching
(losing the KV-cache advantage anyway, back to Option A's cost) or running
one process per conversation (VRAM does not have room for more than one
loaded model instance on this GPU — see hardware section). More fragile:
has to parse a live interactive stream instead of a single bounded output.

**Recommendation: Option A.** It's the better fit for the sidebar-of-saved-
conversations UI that already exists, it's far simpler to implement
correctly, and the performance cost is fine for occasional practice-chat
use — this was never meant to be a production chat service.

## Frontend (`chat/index.html`) — what to keep vs change

Already implemented, keep as-is:
- Two-column layout, collapsible left sidebar (`☰` toggle,
  `localStorage` key `qwenChat.sidebarCollapsed`).
- Conversations persisted client-side: `qwenChat.conversations` (array of
  `{id, title, messages: [{role, content}, ...]}`) and
  `qwenChat.activeId`. Title auto-derived from the first message.
- New chat / delete chat / switch chat UI and guards against doing those
  while a response is streaming.
- `<think>…</think>` dimming in rendered bubbles.

Needs to change:
- `API` constant and the two `fetch()` calls currently hit
  `/llm/v1/chat/completions` and `/llm/v1/models` (OpenAI-shaped). Point
  these at whatever the new backend exposes instead. If the new backend
  keeps an OpenAI-compatible shape (`{messages: [...]}` in,
  `data: {...}` SSE chunks with `choices[0].delta.content` out), the
  frontend needs **no other changes** — that compatibility is worth
  preserving specifically to avoid touching this file further.
- The `/v1/models` call is just used to populate the header's model-name
  label — fine to hardcode or drop if the new backend doesn't bother
  implementing that endpoint.

## Deployment

- Keep serving the static page from `/opt/llm/chat/` via the existing
  nginx `alias` (`chat-begin`/`chat-end` block) — no change needed there.
- The new backend needs *some* port and an nginx location to reach it from
  the LAN over HTTPS, the same way `llm-begin`/`llm-end` proxied to
  `127.0.0.1:8349`. Reusing port 8349 for the new backend keeps that nginx
  block unchanged; picking a new port means editing the `proxy_pass`
  target in `/etc/nginx/sites-available/homeserver`.
- Whether the new backend runs as a systemd service (always-on, defeats
  part of the point of moving off `llama-server`) or is itself spawned
  on-demand (e.g. by a tiny always-on process manager that only spawns
  `llama-cli` per request, per Option A) is an open choice — the
  *lightweight, always-on* part should be a small wrapper (Node/Python/Go,
  whatever), not the LLM engine itself.

## Open items to verify before/while implementing

1. Confirm Qwen3's exact chat-template format from the gguf metadata
   (don't hand-guess ChatML tags) — e.g. run once with `--jinja` and
   `--verbose`/`--special` logging to see the literal templated prompt
   `llama-cli` builds, and mirror that in the wrapper.
2. Confirm the accepted values for `--reasoning-format` on this build and
   decide whether to let `llama-cli` strip `<think>` blocks server-side
   instead of the frontend's current regex approach.
3. Decide the new backend's port and update the nginx `llm-begin` block's
   `proxy_pass` accordingly (or keep 8349 to avoid touching nginx).
4. `install.sh` currently only installs/manages `llama-server.service` and
   never touches `chat/` at all (that was deployed manually) — once the
   new backend exists, decide whether `install.sh` should be updated to
   install/manage it too, or if this stays a manual/dev setup.
