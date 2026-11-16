"""Correlate host transitions with the simulator's keyboard extension logs."""
import json
from datetime import datetime, timedelta
from pathlib import Path
from check_exits import ABNORMAL_EXIT, EXTENSION


def write_report(directory: Path, simulator: str):
    transcript = (directory / "typing.log").read_text(errors="replace")
    events = []
    for line in transcript.splitlines():
        if line.startswith("HOSTSOAK "):
            events.append(dict(pair.split("=", 1) for pair in line.split()[1:] if "=" in pair))
    (directory / "checkpoints.json").write_text(json.dumps(events, indent=2) + "\n")
    has_complete = any(e["state"] == "complete" for e in events)
    passed = "** TEST EXECUTE SUCCEEDED **" in transcript
    status = ("passed" if has_complete and passed else
              "typing-complete-test-failed" if has_complete else "incomplete" if events else "setup-failed")
    if not events:
        (directory / "summary.json").write_text(json.dumps({"simulator": simulator, "status": status,
            "first": None, "last": None, "incidents": []}, indent=2) + "\n")
        return

    def timestamp(event):
        return datetime.fromisoformat(event["time"].replace("Z", "+00:00")).astimezone()

    start = timestamp(events[0])
    end = timestamp(events[-1]) + timedelta(seconds=1)
    incidents = [e for e in events if e["state"] in {
        "apple-fallback", "keyboard-missing", "draft-mismatch", "process-changed-during-typing", "failure"}]
    windows = [(timestamp(e) - timedelta(seconds=15), timestamp(e) + timedelta(seconds=15)) for e in incidents]
    context, abnormal, unknown = [], [], []
    for line in (directory / "extension.log").read_text(errors="replace").splitlines():
        if not EXTENSION.search(line):
            continue
        try:
            local = datetime.strptime(line[:23], "%Y-%m-%d %H:%M:%S.%f").astimezone()
        except ValueError:
            continue
        if any(lo <= local <= hi for lo, hi in windows):
            context.append(line)
        if start <= local <= end:
            if ABNORMAL_EXIT.search(line):
                abnormal.append(line)
            elif "SIGKILL" in line.upper():
                unknown.append(line)
    if incidents:
        (directory / "incident.log").write_text("\n".join(context) + "\n")
    reports = []
    for report in (Path.home() / "Library/Logs/DiagnosticReports").rglob("MonkeyBoardKeyboard*.ips"):
        if start.timestamp() <= report.stat().st_mtime and simulator in report.read_text(errors="replace"):
            reports.append(str(report))
    result = {"simulator": simulator, "status": status, "first": events[0], "last": events[-1], "incidents": incidents,
              "refocusEvents": sum(e["state"] == "refocus" for e in events),
              "observedPIDs": sorted({e["pid"] for e in events if e["pid"] != "unavailable"}),
              "abnormalExitLines": abnormal, "unclassifiedKills": unknown, "crashReports": reports}
    (directory / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
