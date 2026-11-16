"""Identify extension crashes and memory kills in one simulator test run."""

import json
import re
import sys
from pathlib import Path


# A normal dismissal often ends in SIGTERM. SIGKILL without an OS reason is
# ambiguous. Keep those lines in the process log without calling them crashes.
ABNORMAL_EXIT = re.compile(
    r"code:SIG(?:SEGV|ABRT|BUS|ILL|FPE|TRAP)\b|"
    r"per[-_ ]?process[-_ ]?limit|JETSAM_REASON_MEMORY|"
    r"memorystatus: killing|domain:watchdog|0x8badf00d",
    re.IGNORECASE,
)
EXTENSION = re.compile(r"dev\.dustin\.monkeyboard\.keyboard\b|MonkeyBoardKeyboard\b", re.I)


def findings(output, devices, reports_root):
    since = (output / "start").stat().st_mtime
    findings_by_device = {}
    for device in devices:
        log = output / f"{device}-process.log"
        extension_lines = [line for line in log.read_text().splitlines() if EXTENSION.search(line)]
        failures = [line for line in extension_lines if ABNORMAL_EXIT.search(line)]
        kills = [line for line in extension_lines if "SIGKILL" in line.upper() and not ABNORMAL_EXIT.search(line)]
        findings_by_device[device] = {
            "abnormalExitLines": failures, "unclassifiedKillLines": kills, "crashReports": []
        }

    for path in reports_root.rglob("MonkeyBoardKeyboard*.ips"):
        if path.stat().st_mtime < since:
            continue
        text = path.read_text(errors="replace")
        for device in devices:
            if device in text:
                findings_by_device[device]["crashReports"].append(str(path))
    return findings_by_device


if __name__ == "__main__":
    output = Path(sys.argv[1])
    result = findings(output, sys.argv[2:], Path.home() / "Library/Logs/DiagnosticReports")
    (output / "extension-exits.json").write_text(json.dumps(result, indent=2) + "\n")
    for device, evidence in result.items():
        print(f"{device}: {len(evidence['abnormalExitLines'])} abnormal exit log entries, "
              f"{len(evidence['crashReports'])} matching crash reports, "
              f"{len(evidence['unclassifiedKillLines'])} SIGKILL log entries without a recognized cause")
    sys.exit(any(evidence["abnormalExitLines"] or evidence["crashReports"] for evidence in result.values()))
