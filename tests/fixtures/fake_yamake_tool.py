#!/usr/bin/env python3
import json
import os
import pathlib
import sys


def append_log(message):
    with open(os.environ["ARC_LSP_TEST_LOG"], "a", encoding="utf-8") as stream:
        stream.write(message + "\n")


def send(message):
    payload = json.dumps(message, separators=(",", ":")).encode()
    sys.stdout.buffer.write(f"Content-Length: {len(payload)}\r\n\r\n".encode() + payload)
    sys.stdout.buffer.flush()


def read_message():
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        name, value = line.decode().split(":", 1)
        if name.lower() == "content-length":
            length = int(value.strip())
    return json.loads(sys.stdin.buffer.read(length)) if length is not None else None


def run_lsp():
    append_log("lsp:" + os.getcwd())
    while True:
        message = read_message()
        if message is None:
            return 0
        method = message.get("method")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": message["id"], "result": {"capabilities": {}}})
        elif method == "shutdown":
            send({"jsonrpc": "2.0", "id": message["id"], "result": None})
        elif method == "exit":
            return 0


tool = pathlib.Path(sys.argv[0]).name
if tool == "arc" and sys.argv[1:2] == ["log"]:
    append_log("arc-log:" + os.getcwd() + ":" + " ".join(sys.argv[1:]))
    print(os.environ["ARC_LSP_TEST_REVISION"] + " test revision")
    sys.exit(0)
if tool == "arc" and sys.argv[1:2] == ["export"]:
    source = pathlib.Path(sys.argv[3])
    destination = pathlib.Path(sys.argv[sys.argv.index("--to") + 1]) / source
    destination.mkdir(parents=True)
    (destination / "package.json").write_text("{}", encoding="utf-8")
    append_log("arc-export:" + os.getcwd() + ":" + " ".join(sys.argv[1:]))
    sys.exit(0)
if tool == "npm" and sys.argv[1:] == ["install"]:
    if not pathlib.Path("package.json").is_file():
        print("package.json is missing", file=sys.stderr)
        sys.exit(1)
    append_log("npm-install:" + os.getcwd())
    sys.exit(0)
if tool == "npm" and sys.argv[1:] == ["run", "build"]:
    output = pathlib.Path("out")
    output.mkdir()
    (output / "ya-make-lsp.js").write_text("built", encoding="utf-8")
    append_log("npm-build:" + os.getcwd())
    sys.exit(0)
if tool == "node":
    sys.exit(run_lsp())
print("unexpected fake tool arguments", tool, sys.argv[1:], file=sys.stderr)
sys.exit(2)
