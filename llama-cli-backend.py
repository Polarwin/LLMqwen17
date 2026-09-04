#!/usr/bin/env python3
"""OpenAI-compatible gateway that runs llama-server only while it is needed."""

import http.client
import json
import os
import signal
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


LLAMA_SERVER = os.environ.get("LLAMA_SERVER", "/opt/llm/llama.cpp/llama-server")
MODEL_DIR = os.environ.get("LLAMA_MODEL_DIR", "/opt/llm/models")
MODEL_FILES = (
    "Qwen3.5-2B-Q4_K_M.gguf",
    "Qwen3-1.7B-Q4_K_M.gguf",
    "SmolLM3-Q4_K_M.gguf",
)
MODELS = {name: os.path.join(MODEL_DIR, name) for name in MODEL_FILES}
DEFAULT_MODEL = os.environ.get("LLAMA_DEFAULT_MODEL", MODEL_FILES[0])
HOST = os.environ.get("LLAMA_HOST", "127.0.0.1")
PORT = int(os.environ.get("LLAMA_PORT", "8349"))
ENGINE_HOST = os.environ.get("LLAMA_ENGINE_HOST", "127.0.0.1")
ENGINE_PORT = int(os.environ.get("LLAMA_ENGINE_PORT", "8350"))
CONTEXT_SIZE = int(os.environ.get("LLAMA_CONTEXT_SIZE", "8192"))
IDLE_TIMEOUT = int(os.environ.get("LLAMA_IDLE_TIMEOUT", "300"))
START_TIMEOUT = int(os.environ.get("LLAMA_START_TIMEOUT", "120"))
MAX_REQUEST_BYTES = int(os.environ.get("LLAMA_MAX_REQUEST_BYTES", str(1024 * 1024)))

generation_lock = threading.Lock()
state_lock = threading.Lock()
stop_event = threading.Event()
engine_process = None
engine_model = None
active_requests = 0
last_activity = 0.0


class RequestError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def terminate_process(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def start_engine(model_name):
    global engine_process, engine_model

    process_to_stop = None
    with state_lock:
        if (
            engine_process is not None
            and engine_process.poll() is None
            and engine_model == model_name
        ):
            process = engine_process
        else:
            if engine_process is not None and engine_process.poll() is None:
                process_to_stop = engine_process
            engine_process = None
            engine_model = None

    if process_to_stop is not None:
        print(f"switching model from {process_to_stop.pid} to {model_name}", flush=True)
        terminate_process(process_to_stop)

    with state_lock:
        if engine_process is None:
            engine_process = subprocess.Popen([
                LLAMA_SERVER,
                "-m", MODELS[model_name],
                "--alias", model_name,
                "--host", ENGINE_HOST,
                "--port", str(ENGINE_PORT),
                "--ctx-size", str(CONTEXT_SIZE),
                "--parallel", "1",
                "--gpu-layers", "auto",
                "--cache-type-k", "q8_0",
                "--cache-type-v", "q8_0",
                "--no-webui",
            ])
            engine_model = model_name
            process = engine_process

    deadline = time.monotonic() + START_TIMEOUT
    last_error = None
    while time.monotonic() < deadline:
        return_code = process.poll()
        if return_code is not None:
            with state_lock:
                if engine_process is process:
                    engine_process = None
                    engine_model = None
            raise RuntimeError(f"llama-server exited during startup with status {return_code}")
        connection = None
        try:
            connection = http.client.HTTPConnection(ENGINE_HOST, ENGINE_PORT, timeout=1)
            connection.request("GET", "/health")
            response = connection.getresponse()
            response.read()
            if response.status == 200:
                return
            last_error = RuntimeError(f"health endpoint returned HTTP {response.status}")
        except (ConnectionError, OSError, http.client.HTTPException) as error:
            last_error = error
        finally:
            if connection is not None:
                connection.close()
        stop_event.wait(0.25)

    with state_lock:
        if engine_process is process:
            engine_process = None
            engine_model = None
    terminate_process(process)
    raise RuntimeError(f"llama-server did not become ready: {last_error}")


def idle_reaper():
    global engine_process, engine_model

    while not stop_event.wait(1):
        process_to_stop = None
        with state_lock:
            if engine_process is not None and engine_process.poll() is not None:
                engine_process = None
                engine_model = None
            elif (
                engine_process is not None
                and active_requests == 0
                and last_activity > 0
                and time.monotonic() - last_activity >= IDLE_TIMEOUT
            ):
                process_to_stop = engine_process
                engine_process = None
                engine_model = None
        if process_to_stop is not None:
            print(f"idle for {IDLE_TIMEOUT}s; stopping llama-server", flush=True)
            terminate_process(process_to_stop)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "llama-on-demand-gateway/1.0"

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} - {fmt % args}", flush=True)

    def send_json(self, status, body):
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def send_error_json(self, status, message):
        self.send_json(status, {"error": {"message": message, "type": "server_error"}})

    def do_GET(self):
        if self.path.rstrip("/") == "/v1/models":
            available = [name for name, path in MODELS.items() if os.path.isfile(path)]
            self.send_json(200, {
                "object": "list",
                "data": [{
                    "id": name,
                    "object": "model",
                    "created": 0,
                    "owned_by": "local",
                } for name in available],
            })
            return
        if self.path.rstrip("/") == "/health":
            with state_lock:
                running = engine_process is not None and engine_process.poll() is None
                loaded_model = engine_model if running else None
            self.send_json(200, {
                "status": "ok",
                "model_loaded": running,
                "model": loaded_model,
            })
            return
        self.send_error_json(404, "not found")

    def do_POST(self):
        global active_requests, last_activity

        if self.path.rstrip("/") != "/v1/chat/completions":
            self.send_error_json(404, "not found")
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > MAX_REQUEST_BYTES:
                raise RequestError(413, "request body is empty or too large")
            body = self.rfile.read(length)
            try:
                payload = json.loads(body)
            except (json.JSONDecodeError, UnicodeDecodeError):
                raise RequestError(400, "request body must be valid JSON") from None
            if not isinstance(payload, dict):
                raise RequestError(400, "request body must be a JSON object")
            if not isinstance(payload.get("messages"), list) or not payload["messages"]:
                raise RequestError(400, "messages must be a non-empty array")
            selected_model = payload.get("model", DEFAULT_MODEL)
            if selected_model not in MODELS:
                raise RequestError(400, f"unknown model: {selected_model!r}")
            if not os.path.isfile(MODELS[selected_model]):
                raise RequestError(400, f"model is not installed: {selected_model}")
            if not generation_lock.acquire(blocking=False):
                raise RequestError(429, "another generation is already running")
        except (RequestError, ValueError) as error:
            status = error.status if isinstance(error, RequestError) else 400
            self.send_error_json(status, str(error))
            return

        self._response_started = False
        with state_lock:
            active_requests += 1

        try:
            start_engine(selected_model)
            self.proxy_completion(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            if not self._response_started:
                self.send_error_json(502, f"llama-server request failed: {error}")
            else:
                self.log_error("upstream stream failed: %s", error)
        finally:
            with state_lock:
                active_requests -= 1
                last_activity = time.monotonic()
            generation_lock.release()

    def proxy_completion(self, body):
        connection = http.client.HTTPConnection(ENGINE_HOST, ENGINE_PORT, timeout=3600)
        try:
            connection.request(
                "POST",
                "/v1/chat/completions",
                body=body,
                headers={"Content-Type": "application/json"},
            )
            response = connection.getresponse()

            self.close_connection = True
            self.send_response(response.status, response.reason)
            content_type = response.getheader("Content-Type")
            if content_type:
                self.send_header("Content-Type", content_type)
            cache_control = response.getheader("Cache-Control")
            if cache_control:
                self.send_header("Cache-Control", cache_control)
            self.send_header("Connection", "close")
            self.send_header("X-Accel-Buffering", "no")
            self.end_headers()
            self._response_started = True

            while True:
                chunk = response.read1(4096)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        finally:
            connection.close()


if __name__ == "__main__":
    if DEFAULT_MODEL not in MODELS:
        raise SystemExit(f"LLAMA_DEFAULT_MODEL is not configured: {DEFAULT_MODEL}")
    threading.Thread(target=idle_reaper, daemon=True).start()
    server = ThreadingHTTPServer((HOST, PORT), Handler)

    def handle_sigterm(_signum, _frame):
        stop_event.set()
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, handle_sigterm)
    print(
        f"gateway listening on http://{HOST}:{PORT}; "
        f"llama-server starts on {ENGINE_HOST}:{ENGINE_PORT} and stops after {IDLE_TIMEOUT}s idle",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop_event.set()
        with state_lock:
            process = engine_process
            engine_process = None
            engine_model = None
        terminate_process(process)
        server.server_close()
