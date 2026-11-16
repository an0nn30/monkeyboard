#!/usr/bin/env python3
"""Build from main, check for incoming changes again, install, and verify."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ("App", "Keyboard", "Shared", "Configuration", "MonkeyBoard.xcodeproj", "keyboard-engine")
PROJECT = ["-project", "MonkeyBoard.xcodeproj", "-scheme", "MonkeyBoard", "-configuration", "Debug"]


def output(*cmd):
    return subprocess.check_output(cmd, cwd=ROOT)


def git(*args):
    return output("git", *args).decode().strip()


def sync_main():
    if git("branch", "--show-current") != "main":
        raise SystemExit("Device installs must start on main.")
    subprocess.run(["git", "fetch", "--quiet", "origin", "refs/heads/main:refs/remotes/origin/main"],
                   cwd=ROOT, check=True)
    # --ff-only will not discard working files or silently merge a diverged main.
    git("merge", "--ff-only", "origin/main")
    head = git("rev-parse", "HEAD")
    subprocess.run(["git", "merge-base", "--is-ancestor", "origin/main", head], cwd=ROOT, check=True)
    return head


def snapshot(head):
    """A commit alone cannot identify a development build with local changes."""
    tracked = output("git", "diff", "--no-renames", "--name-only", "-z", "HEAD", "--", *SOURCE)
    extra = output("git", "ls-files", "--others", "--exclude-standard", "-z", "--", *SOURCE)
    changes = {}
    for name in sorted(set((tracked + extra).split(b"\0")) - {b""}):
        path = ROOT / os.fsdecode(name)
        changes[os.fsdecode(name)] = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
    return {"head": head, "localSource": changes}


def logged(cmd, path):
    print(f"Running {cmd[1]}; log: {path}", flush=True)
    with path.open("w") as log:
        status = subprocess.run(cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    if status.returncode:
        raise SystemExit(f"{cmd[1]} failed:\n" + "\n".join(path.read_text(errors="replace").splitlines()[-25:]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device", help="physical iPhone UDID")
    parser.add_argument("build", help="expected project build number (app and keyboard)")
    parser.add_argument("--simulator", help="booted simulator UDID for targeted UI smoke tests")
    parser.add_argument("--test", action="append", default=[], help="test identifier; repeat as needed")
    args = parser.parse_args()
    if bool(args.simulator) != bool(args.test):
        parser.error("Supply --simulator and --test together.")
    work = Path(tempfile.mkdtemp(prefix=f"monkeyboard-{args.build}-"))
    print(f"Release records: {work}", flush=True)
    for attempt in range(1, 5):
        before = snapshot(sync_main())
        print(f"Building main {before['head'][:12]} for device build {args.build}.", flush=True)
        derived = work / "device"
        logged(["xcodebuild", "build", *PROJECT, "-destination", f"id={args.device}",
                "-derivedDataPath", str(derived)], work / f"device-{attempt}.log")
        app = derived / "Build/Products/Debug-iphoneos/MonkeyBoard.app"
        extension = app / "PlugIns/MonkeyBoardKeyboard.appex"
        for bundle in (app, extension):
            info = plistlib.loads((bundle / "Info.plist").read_bytes())
            if info["CFBundleVersion"] != args.build or info["DTPlatformName"] != "iphoneos":
                raise SystemExit(f"Wrong build or platform in {bundle.name}; not installing.")
        bundle_id = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"]
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        if args.test:
            logged(["xcodebuild", "test", *PROJECT, "-destination", f"platform=iOS Simulator,id={args.simulator}",
                    "-derivedDataPath", str(work / "simulator"), "-parallel-testing-enabled", "NO",
                    "-resultBundlePath", str(work / f"smoke-{attempt}.xcresult"),
                    *(f"-only-testing:{test}" for test in args.test)], work / f"smoke-{attempt}.log")

        if before != snapshot(sync_main()):
            print("Main or local build inputs changed. Rebuilding before installation.", flush=True)
            continue
        receipt = dict(before, remoteMain=git("rev-parse", "origin/main"), build=args.build, bundle=bundle_id)
        (work / "source.json").write_text(json.dumps(receipt, indent=2) + "\n")
        subprocess.run(["xcrun", "devicectl", "device", "install", "app", "--device", args.device,
                        "--json-output", str(work / "install.json"), str(app)], check=True)
        verified = work / "verified.json"
        subprocess.run(["xcrun", "devicectl", "device", "info", "apps", "--device", args.device,
                        "--filter", f"bundleIdentifier == '{bundle_id}'", "--json-output", str(verified)], check=True)
        apps = json.loads(verified.read_text())["result"]["apps"]
        if not any(a["bundleIdentifier"] == bundle_id and a["bundleVersion"] == args.build for a in apps):
            raise SystemExit("Installation returned, but the requested version was not verified.")
        print(f"Verified build {args.build} on the phone, including main {receipt['remoteMain'][:12]}.")
        return
    raise SystemExit("Build inputs kept changing. Nothing was installed.")


if __name__ == "__main__":
    main()
