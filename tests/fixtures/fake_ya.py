#!/usr/bin/env python3
import json
import os
import pathlib
import sys


def append_log(message):
    with open(os.environ["ARC_LSP_TEST_LOG"], "a", encoding="utf-8") as stream:
        stream.write(message + "\n")


def dump_compile_commands():
    if pathlib.Path(".fake_ya_fail").exists():
        print("requested failure", file=sys.stderr)
        return 1
    output_arg = next(arg for arg in sys.argv if arg.startswith("--output-file="))
    output = pathlib.Path(output_arg.split("=", 1)[1])
    source = pathlib.Path(".fake_compile_commands")
    contents = source.read_text(encoding="utf-8") if source.exists() else "[]"
    output.write_text(contents, encoding="utf-8")
    append_log("dump:" + os.getcwd())
    return 0


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


def run_clangd():
    append_log("clangd:" + os.getcwd())
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


if sys.argv[1:3] == ["dump", "compile-commands"]:
    sys.exit(dump_compile_commands())
if sys.argv[1:3] == ["tool", "clangd"]:
    sys.exit(run_clangd())
print("unexpected fake ya arguments", sys.argv[1:], file=sys.stderr)
sys.exit(2)

