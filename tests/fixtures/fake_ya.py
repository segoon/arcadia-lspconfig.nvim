#!/usr/bin/env python3
import json
import os
import pathlib
import sys
import time


def append_log(message):
    with open(os.environ["ARC_LSP_TEST_LOG"], "a", encoding="utf-8") as stream:
        stream.write(message + "\n")


def synchronize(stage, other_stage):
    if not pathlib.Path(".fake_ya_require_parallel").exists():
        return True
    pathlib.Path(f".fake_{stage}_started").touch()
    other = pathlib.Path(f".fake_{other_stage}_started")
    deadline = time.monotonic() + 2
    while not other.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    if not other.exists():
        print(f"{other_stage} did not start in parallel", file=sys.stderr)
        return False
    return True


def dump_compile_commands():
    if not synchronize("dump", "make"):
        return 1
    if pathlib.Path(".fake_ya_fail").exists():
        print("requested failure", file=sys.stderr)
        return 1
    output_arg = next(arg for arg in sys.argv if arg.startswith("--output-file="))
    output = pathlib.Path(output_arg.split("=", 1)[1])
    source = pathlib.Path(".fake_compile_commands")
    contents = source.read_text(encoding="utf-8") if source.exists() else "[]"
    output.write_text(contents, encoding="utf-8")
    build_root_arg = next(arg for arg in sys.argv if arg.startswith("--cmd-build-root="))
    append_log("dump:" + os.getcwd() + ":" + build_root_arg)
    return 0


def make():
    if not synchronize("make", "dump"):
        return 1
    output_arg = next(arg for arg in sys.argv if arg.startswith("-o="))
    output = pathlib.Path(output_arg.split("=", 1)[1])
    output.mkdir(parents=True, exist_ok=True)
    append_log("make:" + os.getcwd() + ":" + " ".join(sys.argv[2:]))
    if pathlib.Path(".fake_ya_make_fail").exists():
        print("requested make failure", file=sys.stderr)
        return 1
    return 0


def ide_vscode():
    output_arg = next(arg for arg in sys.argv if arg.startswith("-P="))
    output = pathlib.Path(output_arg.split("=", 1)[1])
    output.mkdir(parents=True, exist_ok=True)
    append_log("ide:" + os.getcwd() + ":" + " ".join(sys.argv[2:]))
    if pathlib.Path(".fake_ya_ide_fail").exists():
        print("requested ide failure", file=sys.stderr)
        return 1
    links = output / ".links"
    links.mkdir(exist_ok=True)
    workspace = {
        "settings": {
            "python.analysis.extraPaths": [os.getcwd(), str(links)],
        }
    }
    (output / "arcadia-pyright.code-workspace").write_text(
        json.dumps(workspace), encoding="utf-8"
    )
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


def run_lsp(name):
    append_log(name + ":" + os.getcwd())
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
if sys.argv[1:2] == ["make"]:
    sys.exit(make())
if sys.argv[1:3] == ["ide", "vscode"]:
    sys.exit(ide_vscode())
if sys.argv[1:3] == ["tool", "clangd"]:
    sys.exit(run_lsp("clangd"))
if sys.argv[1:2] == ["fake-pyright"]:
    sys.exit(run_lsp("pyright"))
print("unexpected fake ya arguments", sys.argv[1:], file=sys.stderr)
sys.exit(2)

