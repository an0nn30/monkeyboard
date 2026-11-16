"""Run a real-key Firefox typing session against an installed Fennec simulator build."""
import argparse
import hashlib
import http.server
import json
from urllib.parse import urlsplit, parse_qs
from pathlib import Path
import plistlib
import subprocess
import tempfile
import threading

from host_session_report import write_report


PAGE = b"""<!doctype html><html lang="en"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Typing test</title><label for="draft">MonkeyBoard test draft</label>
<textarea autocapitalize="sentences" id="draft" rows="7" style="width:95%;font:20px system-ui"></textarea></html>"""
PREDICATE = ('(process == "runningboardd" OR process == "ReportCrash" OR process == "kernel" OR '
             'process == "SpringBoard") AND (eventMessage CONTAINS[c] "monkeyboard.keyboard" OR '
             'eventMessage CONTAINS[c] "MonkeyBoardKeyboard")')


class DraftPage(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(self.path)
        if url.path != "/":
            self.send_error(404)
            return
        mode = parse_qs(url.query).get("correction", ["on"])[0]
        attributes = b'autocorrect="off" spellcheck="false"' if mode == "off" else b'autocorrect="on"'
        page = PAGE.replace(b"<textarea ", b"<textarea " + attributes + b" ")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.end_headers()
        self.wfile.write(page)

    def log_message(self, *args):
        pass


def install_replay_keyboard(simulator, runfile, config):
    # XCTest opens Firefox directly, so it can leave a different build's input extension running.
    product = Path(config["UITargetAppPath"].replace("__TESTROOT__", str(runfile.resolve().parent)))
    info = plistlib.loads((product / "Info.plist").read_bytes())
    bundle = info["CFBundleIdentifier"]
    subprocess.run(["xcrun", "simctl", "install", simulator, str(product)], check=True)
    installed = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", simulator, bundle, "app"], text=True).strip())
    extension = next((product / "PlugIns").glob("*.appex"))
    executable = plistlib.loads((extension / "Info.plist").read_bytes())["CFBundleExecutable"]
    binaries = [extension / executable, *extension.glob("*.debug.dylib")]
    digests = {}
    for source in binaries:
        relative = source.relative_to(product)
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        if hashlib.sha256((installed / relative).read_bytes()).hexdigest() != digest:
            raise RuntimeError("Installed simulator extension differs from " + str(source))
        digests[str(relative)] = digest
    # End any process retaining the old executable image before collecting taps.
    subprocess.run(["xcrun", "simctl", "shutdown", simulator], check=True)
    subprocess.run(["xcrun", "simctl", "boot", simulator], check=True)
    subprocess.run(["xcrun", "simctl", "bootstatus", simulator, "-b"], check=True, stdout=subprocess.DEVNULL)
    return {"simulator": simulator, "build": info["CFBundleVersion"], "sha256": digests}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator")
    parser.add_argument("xctestrun", type=Path, help="Simulator build-for-testing result")
    parser.add_argument("output", type=Path, help="A new directory for the run")
    parser.add_argument("--seconds", type=int, default=600, choices=range(1, 901), metavar="1..900")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--with-messages", action="store_true", help="Switch between Messages and Firefox mid-sentence")
    group.add_argument("--finger-replay", type=Path, help="Replay the traces in the finger geometry benchmark JSON")
    args = parser.parse_args()
    session = "messages-firefox" if args.with_messages else "firefox"
    test = "testMessagesFirefoxMidSentence" if args.with_messages else "testFirefoxTypingSession"
    subprocess.run(["xcrun", "simctl", "get_app_container", args.simulator, "org.mozilla.ios.Fennec"], check=True)
    config = plistlib.loads(args.xctestrun.read_bytes())
    config["MonkeyBoardUITests"]["EnvironmentVariables"].update(
        MONKEYBOARD_HOST_SESSION=session, MONKEYBOARD_HOST_SECONDS=str(args.seconds))
    if args.finger_replay:
        fixtures = json.loads(args.finger_replay.read_text())["fixtures"]
        env = config["MonkeyBoardUITests"]["EnvironmentVariables"]
        env.update(MONKEYBOARD_HOST_SESSION="finger", MONKEYBOARD_FINGER_CASES=json.dumps(fixtures, separators=(",", ":")))
        test = "testFingerReplay"
    # Paths inside Xcode's property list are relative to its Products directory.
    with http.server.HTTPServer(("127.0.0.1", 0), DraftPage) as server, tempfile.NamedTemporaryFile(
            suffix=".xctestrun", dir=args.xctestrun.resolve().parent) as run:
        config["MonkeyBoardUITests"]["EnvironmentVariables"]["MONKEYBOARD_DRAFT_PORT"] = str(server.server_port)
        args.output.mkdir(parents=True, exist_ok=False)
        if args.finger_replay:
            receipt = install_replay_keyboard(args.simulator, args.xctestrun, config["MonkeyBoardUITests"])
            (args.output / "installed.json").write_text(json.dumps(receipt, indent=2) + "\n")
        plistlib.dump(config, run)
        run.flush()
        threading.Thread(target=server.serve_forever, daemon=True).start()
        with (args.output / "extension.log").open("w") as trace, (args.output / "typing.log").open("w") as log:
            capture = subprocess.Popen(["xcrun", "simctl", "spawn", args.simulator, "log", "stream", "--style",
                                        "compact", "--level", "info", "--predicate", PREDICATE],
                                       stdout=trace, stderr=subprocess.STDOUT)
            try:
                subprocess.run(["xcodebuild", "test-without-building", "-xctestrun", run.name,
                                "-destination", "platform=iOS Simulator,id=" + args.simulator,
                                "-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "YES",
                                "-default-test-execution-time-allowance", str(args.seconds + 180),
                                "-maximum-test-execution-time-allowance", str(args.seconds + 180),
                                "-resultBundlePath", str(args.output / "typing.xcresult"),
                                "-only-testing:MonkeyBoardUITests/HostTypingSessionTests/" + test],
                               stdout=log, stderr=subprocess.STDOUT, check=True)
                if capture.poll() is not None:
                    raise RuntimeError("Simulator log capture stopped during the session")
            finally:
                capture.terminate()
                capture.wait()
                server.shutdown()
                if args.with_messages:
                    trace.flush()
                    log.flush()
                    write_report(args.output, args.simulator)
    events = [line for line in (args.output / "typing.log").read_text().splitlines() if line.startswith("HOSTSOAK ")]
    if not events or "state=complete" not in events[-1]:
        raise RuntimeError("No completed typing session; inspect typing.log")
    print(events[-1])


if __name__ == "__main__":
    main()
