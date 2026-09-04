# Audit findings — on-demand `llama-server` gateway (for Codex)

Scope: `llama-cli-backend.py` + `llama-cli-wrapper.service`, the rewrite that
spawns `llama-server` on demand and proxies `/v1/chat/completions` to it
instead of the earlier (broken) approach of parsing raw `llama-cli` stdout.

**The architecture itself is sound and was verified working end-to-end**
(cold start → real response, SSE streaming, concurrent-request 429, idle
auto-shutdown freeing VRAM, cold restart after shutdown — all tested live,
not just read). Two real issues remain, below, most severe first.

## 1. Orphaned `llama-server` child if the gateway exits without running its `finally` block

**Severity: real, demonstrated by testing — defeats the whole point of this rewrite in that failure mode.**

`llama-cli-backend.py`'s only cleanup path is the `finally` block at the
bottom of `__main__`, reached via `except KeyboardInterrupt` around
`server.serve_forever()`. There is no `signal.signal(signal.SIGTERM, ...)`
handler anywhere in the file.

Repro:
```bash
python3 llama-cli-backend.py &          # gateway pid, say 107043
curl -s http://127.0.0.1:8349/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":5}'   # engine starts
kill 107043                              # plain SIGTERM, not a group kill
pgrep -af llama-server                   # still running — orphaned, holding VRAM
```
Confirmed: the `llama-server` child kept running and holding ~1.2 GB VRAM
after the parent gateway process was gone, with nothing left alive to ever
stop it.

Why this is masked in the currently-deployed unit but not actually fixed:
`llama-cli-wrapper.service` sets `KillMode=control-group`, so a normal
`systemctl stop`/`restart` sends the kill signal to the whole cgroup
(gateway + engine together) and this specific gap doesn't surface. It does
surface for anything that kills only the gateway PID — the OOM killer
picking the smaller Python process over the multi-GB `llama-server`, a
`pkill python3`, running the script directly outside systemd (as in the
repro above), etc.

**Fix**: install a `SIGTERM` handler that sets `stop_event` (and/or calls
the same cleanup the `finally` block does) so cleanup runs regardless of
which signal asked the process to stop, not just `KeyboardInterrupt`/SIGINT.

## 2. KV cache is no longer quantized — regression vs. the previously-tuned config

**Severity: minor / performance, not correctness.**

The `llama-server` command line built in `start_engine()`:
```python
[
    LLAMA_SERVER, "-m", MODEL_PATH, "--alias", MODEL_NAME,
    "--host", ENGINE_HOST, "--port", str(ENGINE_PORT),
    "--ctx-size", str(CONTEXT_SIZE), "--parallel", "1",
    "--gpu-layers", "auto", "--no-webui",
]
```
drops `--cache-type-k q8_0 --cache-type-v q8_0`, which the original
`llama-server.service` on this host used specifically to reduce KV-cache
VRAM footprint on the MX350's 2 GB budget. Without them the KV cache
defaults to f16 — more VRAM per context token than before.

This isn't a functional bug — `--gpu-layers auto` self-corrects by
offloading fewer layers if VRAM is tighter — but it throws away a real,
already-validated tuning choice for this specific GPU, for no stated
reason. **Fix**: add `--cache-type-k q8_0 --cache-type-v q8_0` back to the
spawned command.

## Verified working (no action needed, listed so it isn't re-litigated)

- Cold start on first request: clean JSON response, no banner/echo
  contamination (the bug that killed the previous `llama-cli`-stdout
  approach is gone, because this version proxies `llama-server`'s real API
  instead of parsing a REPL's stdout).
- `stream:true` produces correct OpenAI-shaped SSE chunks.
- Two concurrent requests: one succeeds, the other gets a clean
  `429 another generation is already running` — no crash, no deadlock.
- Idle timeout: engine process is stopped after `LLAMA_IDLE_TIMEOUT`
  seconds of no active request, VRAM fully freed
  (`nvidia-smi` → 0 MiB), `/health` correctly reports `model_loaded:false`.
- Cold restart after an idle shutdown works cleanly.
- `--gpu-layers auto` (not hardcoded `-ngl 99`) correctly avoids failing
  when VRAM is partially occupied.
- Self-heals if the engine crashes mid-response: next request sees the
  dead PID via `poll()` and spawns a fresh one.
- `nginx-llm-snippet.conf`'s `proxy_buffering off` is correct and necessary
  for SSE to actually stream through nginx.
