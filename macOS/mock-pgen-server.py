#!/usr/bin/env python3
"""Stand-in for a PGenerator+ unit, so the macOS Patch Companion can be
exercised without the Pi.

It speaks the subset of the companion protocol the client actually uses:
pairing, the poll/ack loop, and the Install & Apply push. Everything the real
unit does around those - measuring, fitting, the WebUI - is out of scope.

    python3 mock-pgen-server.py [--port 8080] [--deny] [--manual]

Then start the Companion against it:

    PGenPatchCompanion.app/Contents/MacOS/PGenPatchCompanion --server=http://127.0.0.1:8080

Type `help` at the prompt for the command list.

Quirks of the real protocol that this reproduces deliberately, because the
client depends on them:

  - The client finds the poll status with a literal substring match on
    `"status":"patch"`, so the JSON must be compact - no space after the colon.
  - `sequence` is milliseconds since the epoch and must increase. The client
    ignores a sequence it has already seen or already has pending, so a command
    is re-sent on every poll until it is acked.
  - Pairing approval is one-shot: the request is dropped the moment the client
    reads `approved`, and the token is only ever sent once.
  - The token is exactly 64 lowercase hex characters; the client rejects
    anything else.
"""

import argparse
import json
import os
import re
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PATCH_SIZES = (2, 5, 10, 18, 25, 50, 75, 100, 105, 110, 118, 125, 150)


def now_ms():
    return int(time.time() * 1000)


class State:
    """Everything the handler threads and the console thread share."""

    def __init__(self, auto_approve, approve_decision):
        self.lock = threading.Lock()
        self.auto_approve = auto_approve
        self.approve_decision = approve_decision

        self.pair_requests = {}          # request id -> dict
        self.token = None

        self.command = None              # the patch/align dict currently being served
        self.last_sequence = 0
        self.acked_sequence = 0
        self.last_ack = None

        self.settings_revision = 1
        self.window_mode = "window"
        self.display_size = 100
        self.correction_mode = "system"
        self.correction_signal_mode = "sdr"

        self.install = None              # dict(job, file, path, result)
        self.client = {}                 # last poll's reported state

    # -- settings fragment merged into every poll response ------------------
    def settings_fields(self):
        return {
            "window_mode": self.window_mode,
            "display_size": self.display_size,
            "settings_revision": self.settings_revision,
            "correction_mode": self.correction_mode,
            "correction_signal_mode": self.correction_signal_mode,
        }

    def next_sequence(self):
        seq = now_ms()
        if seq <= self.last_sequence:
            seq = self.last_sequence + 1
        self.last_sequence = seq
        return seq

    def set_command(self, command):
        command["sequence"] = self.next_sequence()
        self.command = command
        return command["sequence"]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    state: State = None          # injected below
    _last_rejected_token = [""]  # shared, so the warning prints once per token

    # Quiet the default one-line-per-request logging; the console is the UI.
    def log_message(self, fmt, *args):
        pass

    # -- helpers -----------------------------------------------------------
    def _send(self, status, payload, content_type="application/json"):
        if isinstance(payload, (dict, list)):
            # Compact separators matter: the client substring-matches
            # `"status":"patch"` with no space.
            body = json.dumps(payload, separators=(",", ":")).encode()
        elif isinstance(payload, str):
            body = payload.encode()
        else:
            body = payload
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return {}

    def _authorized(self, query):
        token = (query.get("token") or [""])[0]
        return self.state.token is not None and token == self.state.token

    # -- routing -----------------------------------------------------------
    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        route = url.path

        if route == "/api/icc/companion/pair-status":
            return self._pair_status(query)
        if route == "/api/icc/companion/poll":
            return self._poll(query)
        if route == "/api/icc/companion/profile-install-data":
            return self._install_data(query)
        if route.startswith("/mock/"):
            return self._control(route[len("/mock/"):], query)
        return self._send(404, {"status": "error", "message": "no such route"})

    # -- scriptable control surface ---------------------------------------
    # The console is for driving this by hand; these routes are the same
    # commands for a test script, so the verification steps can run unattended.
    def _control(self, action, query):
        def number(key, fallback):
            try:
                return int((query.get(key) or [fallback])[0])
            except ValueError:
                return fallback

        state = self.state
        if action == "state":
            with state.lock:
                return self._send(200, {"client": state.client,
                                        "acked": state.acked_sequence,
                                        "last_ack": state.last_ack,
                                        "paired": state.token is not None,
                                        "settings": state.settings_fields()})
        if action == "patch":
            with state.lock:
                sequence = state.set_command({
                    "status": "patch",
                    "r": number("r", 255), "g": number("g", 255), "b": number("b", 255),
                    "size": number("size", state.display_size),
                    "input_max": 255, "code_min": 0, "code_max": 255,
                    "signal_mode": (query.get("signal_mode") or ["sdr"])[0],
                    "max_luma": 0, "min_luma": 0, "max_cll": 0, "max_fall": 0,
                })
            return self._send(200, {"status": "ok", "sequence": sequence})

        if action == "align":
            with state.lock:
                sequence = state.set_command({"status": "align"})
            return self._send(200, {"status": "ok", "sequence": sequence})

        if action == "settings":
            with state.lock:
                for key in ("window_mode", "correction_mode",
                            "correction_signal_mode"):
                    if key in query:
                        setattr(state, key, query[key][0])
                if "display_size" in query:
                    state.display_size = number("display_size", state.display_size)
                state.settings_revision += 1
                return self._send(200, {"status": "ok",
                                        "settings": state.settings_fields()})

        if action == "install":
            path = (query.get("path") or [""])[0]
            if not os.path.isfile(path):
                return self._send(404, {"status": "error", "message": "no such file"})
            with state.lock:
                state.install = {"job": f"{now_ms()}-{os.getpid()}",
                                 "file": os.path.basename(path),
                                 "path": path, "result": None}
                state.correction_mode = "system"
                state.settings_revision += 1
                return self._send(200, {"status": "ok", "job": state.install["job"]})

        if action == "install-status":
            with state.lock:
                install = state.install
            if install is None:
                return self._send(404, {"status": "error", "message": "no install"})
            return self._send(200, {"status": install["result"] or "pending",
                                    "job": install["job"], "file": install["file"]})

        return self._send(404, {"status": "error", "message": f"no such control: {action}"})

    def do_POST(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        route = url.path

        if route == "/api/icc/companion/pair-request":
            return self._pair_request()
        if route == "/api/icc/companion/ack":
            return self._ack()
        if route == "/api/icc/companion/profile-install-result":
            return self._install_result(query)
        if route == "/api/icc/companion/build-result":
            # The mock never offloads a colprof fit, but answer politely if asked.
            return self._send(200, {"status": "ok"})
        return self._send(404, {"status": "error", "message": "no such route"})

    # -- pairing -----------------------------------------------------------
    def _pair_request(self):
        body = self._body()
        client = str(body.get("client", ""))
        platform = str(body.get("platform", ""))
        version = str(body.get("version", ""))

        # The real unit restricts platform to (windows|linux); we accept macos
        # too, which is exactly the widening the Pi-side patch makes.
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", client) or \
           not re.fullmatch(r"windows|linux|macos", platform) or \
           not re.fullmatch(r"[0-9.]{1,16}", version):
            print(f"\n  [pair] REJECTED client={client!r} platform={platform!r} "
                  f"version={version!r}")
            return self._send(400, {"status": "error",
                                    "message": "Invalid pairing request"})

        with self.state.lock:
            # A retry from the same client returns the same id and code.
            for rid, entry in self.state.pair_requests.items():
                if entry["client"] == client and entry["status"] == "pending":
                    return self._send(200, {"status": "pending", "request": rid,
                                            "code": entry["code"],
                                            "expires_in": 180})
            rid = secrets.token_hex(16)
            code = f"{secrets.randbelow(1000000):06d}"
            self.state.pair_requests[rid] = {
                "client": client, "platform": platform, "version": version,
                "code": code, "status": "pending", "created": time.time(),
                "ip": self.client_address[0],
            }
            auto = self.state.auto_approve
            decision = self.state.approve_decision

        print(f"\n  [pair] {client} ({platform} {version}) from {self.client_address[0]}")
        print(f"  [pair] code {code}", flush=True)
        if auto:
            print(f"  [pair] auto-{decision}", flush=True)
            with self.state.lock:
                self.state.pair_requests[rid]["status"] = decision
        else:
            print("  [pair] type `approve` or `deny`", flush=True)

        return self._send(200, {"status": "pending", "request": rid,
                                "code": code, "expires_in": 180})

    def _pair_status(self, query):
        rid = (query.get("request") or [""])[0]
        with self.state.lock:
            entry = self.state.pair_requests.get(rid)
            if entry is None:
                return self._send(200, {"status": "expired"})
            if entry["status"] == "pending":
                return self._send(200, {"status": "pending"})
            # approved/denied are one-shot: drop the request as it is read.
            del self.state.pair_requests[rid]
            if entry["status"] == "denied":
                return self._send(200, {"status": "denied"})
            self.state.token = secrets.token_hex(32)
            token = self.state.token
        print(f"  [pair] approved, token issued", flush=True)
        return self._send(200, {"status": "approved", "token": token})

    # -- poll / ack --------------------------------------------------------
    def _poll(self, query):
        if not self._authorized(query):
            # Worth shouting about. The client retries a rejected token
            # indefinitely without surfacing anything, so a stale
            # PGenPatchCompanion.conf looks exactly like a dead server.
            token = (query.get("token") or [""])[0]
            if token != self._last_rejected_token[0]:
                self._last_rejected_token[0] = token
                print(f"  [poll] REJECTED token {token[:8]}... - this client is "
                      f"paired with a different server. Delete its "
                      f"PGenPatchCompanion.conf and restart it.", flush=True)
            return self._send(403, {"status": "unauthorized"})

        def one(key):
            return (query.get(key) or [""])[0]

        def unhex(key):
            raw = one(key)
            try:
                return bytes.fromhex(raw).decode("utf-8", "replace") if raw else ""
            except ValueError:
                return ""

        with self.state.lock:
            self.state.client = {
                "client": one("client"), "version": one("version"),
                "build": one("build"), "platform": one("platform"),
                "renderer": one("renderer"), "hdr": one("hdr") == "1",
                "profile": unhex("profile_hex"), "display": unhex("display_hex"),
                "swapchain_cs": one("swapchain_cs"),
                "presentation": one("presentation"),
                "output_max": one("output_max"), "output_bits": one("output_bits"),
                "transform": one("transform"),
                "transform_ready": one("transform_ready") == "1",
                "transform_note": unhex("transform_note_hex"),
                "source": (one("source_r"), one("source_g"), one("source_b")),
                "submitted": (one("submitted_r"), one("submitted_g"), one("submitted_b")),
                "build_argyll": one("build_argyll"),
                "seen": time.time(),
            }

            response = dict(self.state.settings_fields())

            install = self.state.install
            if install is not None and install["result"] is None:
                response.update({"status": "install", "install_job": install["job"],
                                 "file": install["file"]})
                return self._send(200, response)

            command = self.state.command
            if command is not None and command["sequence"] != self.state.acked_sequence:
                response.update(command)
                return self._send(200, response)

            response.update({"status": "idle", "poll_ms": 500})
            return self._send(200, response)

    def _ack(self):
        body = self._body()
        if self.state.token is None or body.get("token") != self.state.token:
            return self._send(403, {"status": "unauthorized"})
        sequence = int(body.get("sequence") or 0)
        with self.state.lock:
            self.state.acked_sequence = sequence
            self.state.last_ack = body
        status = body.get("status", "?")
        message = body.get("message") or ""
        mark = "ok " if status == "ok" else "ERR"
        print(f"  [ack] {mark} seq={sequence} renderer={body.get('renderer','')} "
              f"hdr={body.get('hdr_active')}" + (f" - {message}" if message else ""),
              flush=True)
        return self._send(200, {"status": "ok"})

    # -- install & apply ---------------------------------------------------
    def _install_data(self, query):
        if not self._authorized(query):
            return self._send(403, {"status": "unauthorized"})
        job = (query.get("job") or [""])[0]
        with self.state.lock:
            install = self.state.install
        if install is None or install["job"] != job:
            return self._send(404, {"status": "error", "message": "no such job"})
        try:
            with open(install["path"], "rb") as handle:
                data = handle.read()
        except OSError as error:
            return self._send(500, {"status": "error", "message": str(error)})
        if len(data) < 132 or data[36:40] != b"acsp":
            return self._send(400, {"status": "error", "message": "not an ICC profile"})
        print(f"  [install] sent {len(data)} bytes of {install['file']}", flush=True)
        return self._send(200, data, content_type="application/vnd.iccprofile")

    def _install_result(self, query):
        if not self._authorized(query):
            return self._send(403, {"status": "unauthorized"})
        job = (query.get("job") or [""])[0]
        ok = (query.get("ok") or ["0"])[0] == "1"
        raw = (query.get("message_hex") or [""])[0]
        try:
            message = bytes.fromhex(raw).decode("utf-8", "replace") if raw else ""
        except ValueError:
            message = ""
        with self.state.lock:
            install = self.state.install
            if install is not None and install["job"] == job:
                install["result"] = "ok" if ok else "error"
        print(f"  [install] {'ok' if ok else 'FAILED'}" +
              (f" - {message}" if message else ""), flush=True)
        return self._send(200, {"status": "ok"})


CONSOLE_HELP = """
  patch R G B [size]   send a patch, 0-255 per channel, size from
                       2 5 10 18 25 50 75 100 105 110 118 125 150 (default 100)
  ramp [steps]         walk a neutral ramp, one patch per Enter (default 11)
  align                show the alignment crosshair
  window | fullscreen  set the window mode
  size N               set the patch size percentage
  mode M               correction mode: system | none | clut | matrix
  signal S             correction signal mode: sdr | hdr10
  install PATH.icc     push a profile through Install & Apply
  approve | deny       decide a pending pairing request
  status               show what the client last reported
  help                 this list
  quit                 stop the server
"""


def console(state, server):
    print(CONSOLE_HELP, flush=True)
    while True:
        try:
            line = input("mock> ").strip()
        except (EOFError, KeyboardInterrupt):
            server.shutdown()
            return
        if not line:
            continue
        parts = line.split()
        command, args = parts[0].lower(), parts[1:]

        try:
            if command in ("quit", "exit"):
                server.shutdown()
                return

            if command == "help":
                print(CONSOLE_HELP, flush=True)

            elif command == "patch":
                if len(args) < 3:
                    print("  need R G B")
                    continue
                r, g, b = (int(v) for v in args[:3])
                size = int(args[3]) if len(args) > 3 else state.display_size
                if size not in PATCH_SIZES:
                    print(f"  size must be one of {PATCH_SIZES}")
                    continue
                with state.lock:
                    seq = state.set_command({
                        "status": "patch", "r": r, "g": g, "b": b, "size": size,
                        "input_max": 255, "code_min": 0, "code_max": 255,
                        "signal_mode": "sdr", "max_luma": 0, "min_luma": 0,
                        "max_cll": 0, "max_fall": 0,
                    })
                print(f"  -> patch {r},{g},{b} size {size} seq {seq}")

            elif command == "ramp":
                steps = int(args[0]) if args else 11
                for index in range(steps):
                    value = round(255 * index / (steps - 1))
                    with state.lock:
                        seq = state.set_command({
                            "status": "patch", "r": value, "g": value, "b": value,
                            "size": state.display_size,
                            "input_max": 255, "code_min": 0, "code_max": 255,
                            "signal_mode": "sdr", "max_luma": 0, "min_luma": 0,
                            "max_cll": 0, "max_fall": 0,
                        })
                    print(f"  -> {value:3d},{value:3d},{value:3d} seq {seq}  "
                          f"[Enter for next, Ctrl-C to stop]", end="")
                    input()

            elif command == "align":
                with state.lock:
                    seq = state.set_command({"status": "align"})
                print(f"  -> alignment seq {seq}")

            elif command in ("window", "fullscreen"):
                with state.lock:
                    state.window_mode = command
                    state.settings_revision += 1
                print(f"  -> window_mode {command}")

            elif command == "size":
                size = int(args[0])
                if size not in PATCH_SIZES:
                    print(f"  size must be one of {PATCH_SIZES}")
                    continue
                with state.lock:
                    state.display_size = size
                    state.settings_revision += 1
                print(f"  -> display_size {size}")

            elif command == "mode":
                mode = args[0]
                if mode not in ("system", "none", "clut", "matrix"):
                    print("  mode must be system, none, clut or matrix")
                    continue
                with state.lock:
                    state.correction_mode = mode
                    state.settings_revision += 1
                print(f"  -> correction_mode {mode}")

            elif command == "signal":
                signal = args[0]
                if signal not in ("sdr", "hdr10"):
                    print("  signal must be sdr or hdr10")
                    continue
                with state.lock:
                    state.correction_signal_mode = signal
                    state.settings_revision += 1
                print(f"  -> correction_signal_mode {signal}")

            elif command == "install":
                path = os.path.expanduser(" ".join(args))
                if not os.path.isfile(path):
                    print(f"  no such file: {path}")
                    continue
                with state.lock:
                    state.install = {
                        "job": f"{now_ms()}-{os.getpid()}",
                        "file": os.path.basename(path),
                        "path": path, "result": None,
                    }
                    # The real server forces system correction first so the
                    # client stops double-correcting during the install.
                    state.correction_mode = "system"
                    state.settings_revision += 1
                    job = state.install["job"]
                print(f"  -> install job {job} ({os.path.basename(path)})")

            elif command in ("approve", "deny"):
                with state.lock:
                    pending = [rid for rid, entry in state.pair_requests.items()
                               if entry["status"] == "pending"]
                    if not pending:
                        print("  no pending pairing request")
                        continue
                    decision = "approved" if command == "approve" else "denied"
                    for rid in pending:
                        state.pair_requests[rid]["status"] = decision
                print(f"  -> {command}d {len(pending)} request(s)")

            elif command == "status":
                with state.lock:
                    client = dict(state.client)
                    token = state.token
                    acked = state.acked_sequence
                if not client:
                    print("  no client has polled yet"
                          + ("" if token else " (and nothing is paired)"))
                    continue
                age = time.time() - client["seen"]
                print(f"  client       {client['client']} {client['version']} "
                      f"({client['platform']})  last seen {age:.1f}s ago")
                print(f"  renderer     {client['renderer']}  hdr={client['hdr']}  "
                      f"swapchain={client['swapchain_cs']}  "
                      f"presentation={client['presentation']}")
                print(f"  display      {client['display']}")
                print(f"  profile      {client['profile'] or '(none reported)'}")
                print(f"  transform    {client['transform']} "
                      f"ready={client['transform_ready']} "
                      f"{client['transform_note']}")
                print(f"  source       {client['source']}")
                print(f"  submitted    {client['submitted']}")
                print(f"  argyll       {client['build_argyll'] or '(not offered)'}")
                print(f"  acked seq    {acked}")

            else:
                print(f"  unknown command: {command}  (try `help`)")

        except (ValueError, IndexError) as error:
            print(f"  bad arguments: {error}")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--manual", action="store_true",
                        help="wait for an `approve`/`deny` command instead of "
                             "deciding pairing automatically")
    parser.add_argument("--deny", action="store_true",
                        help="auto-deny pairing, to exercise the client's "
                             "rejection path")
    parser.add_argument("--no-console", action="store_true",
                        help="serve without the interactive prompt, for "
                             "scripted tests")
    args = parser.parse_args()

    state = State(auto_approve=not args.manual,
                  approve_decision="denied" if args.deny else "approved")
    Handler.state = state

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True

    print(f"mock PGenerator+ on http://{args.host}:{args.port}")
    print("start the Companion with "
          f"--server=http://{args.host}:{args.port}", flush=True)

    if args.no_console:
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            server.server_close()
        return 0

    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        console(state, server)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
