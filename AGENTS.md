Run tests on simulators. Do not run tests on the physical Duo unless Dustin expressly requests on-device testing. If the simulator cannot cover a case, report that limitation. A request to install a build authorizes installation and version verification only.

Use the existing `main` checkout for MonkeyBoard device builds. Release work from other sessions is incorporated from `origin/main`. Keep local changes that already shipped, including app and keyboard-extension changes; do not reset or stash another session's work to make a release.

Fetch `origin/main` at the start of device work, again during longer changes, and immediately before each installation. If the branch advances, integrate it, rebuild and rerun the relevant checks. Use `python3 Scripts/install_main.py --help` for the guarded install. It checks both bundle versions and verifies the installed version on the phone. A device deployment request is not a request to publish local work to GitHub.

Use simulators for testing. Run a test on Dustin’s physical Duo only when he explicitly requests or approves that specific run. If the host app is unavailable on the simulator, report the coverage gap.
