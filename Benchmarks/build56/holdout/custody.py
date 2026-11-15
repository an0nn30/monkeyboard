"""Verify the escrow against the frozen hashes, or materialize a separately authorized release."""
import argparse
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("reserve_fixture", HERE / "freeze.py")
reserve = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reserve)


def read_custody_record(escrow, sessions):
    files = list(sessions.rglob("*" + escrow["thread"] + "*.jsonl"))
    if len(files) != 1:
        raise ValueError("Original curator task archive unavailable or ambiguous")
    with files[0].open() as stream:
        for line in stream:
            item = json.loads(line).get("payload", {})
            if item.get("type") == "custom_tool_call" and item.get("call_id") == escrow["call_id"]:
                return item["input"]
    raise ValueError("Original curator task record missing")


class AnnotatedText:
    def __init__(self, source):
        self.source = source

    def read_text(self):
        return self.source.decode("utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sessions", type=Path, default=Path.home() / ".codex/sessions")
    parser.add_argument("--release", action="store_true", help="requires coordinator authorization")
    args = parser.parse_args()
    manifest = json.loads((HERE / "freeze.json").read_bytes())
    escrow = json.loads((HERE / "custody.json").read_bytes())
    sealed = (HERE / "authored.recovery.sealed").read_bytes()
    assert reserve.fixture.sha(sealed) == escrow["ciphertext_sha256"]
    record = read_custody_record(escrow, args.sessions)
    key = hashlib.sha256((escrow["salt"] + record).encode()).hexdigest()
    rd, wr = os.pipe()
    try:
        with os.fdopen(wr, "wb") as pipe:
            pipe.write(key.encode() + b"\n")
        cmd = ["openssl", "enc", "-d", "-aes-256-cbc", "-pbkdf2", "-iter", "250000",
               "-md", "sha256", "-pass", f"fd:{rd}"]
        source = subprocess.run(cmd, input=sealed, pass_fds=(rd,), stdout=subprocess.PIPE, check=True).stdout
    finally:
        os.close(rd)
    assert reserve.fixture.sha(source) == manifest["source_annotation_sha256"]
    data = reserve.fixture.encoded(reserve.fixture.make_pairs(AnnotatedText(source), "reserve56"))
    assert reserve.fixture.sha(data) == manifest["fixture_sha256"]
    if args.release:
        for path, content in ((HERE / "authored.txt", source), (HERE / "cases.json", data)):
            if not path.exists():
                with path.open("xb") as file:
                    file.write(content)
            assert path.read_bytes() == content
    print("Verified original source and fixture SHA-256. Release requested:", args.release)


if __name__ == "__main__":
    main()
