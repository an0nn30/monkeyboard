# Keyboard extension memory pressure (build 66)

Two build 65 exits on the Duo at 16:33:38 and 16:34:10 local time on November 15 were recorded by iOS as `JETSAM_REASON_MEMORY_PERPROCESSLIMIT`. In the second instance UIKit delivered memory warnings about 25 seconds before termination. iOS also logged that it had reached its quota for saved memory reports. Looking only for a new keyboard crash file missed the cause.

The keyboard now cancels optional prediction work on a warning, releases both Core ML models on their owning queues, and continues with ordinary word correction and suggestions. The reduced-memory mode lasts for the process, including a new host controller. No preference or learned spelling is changed. Physical devices also check their current process memory allowance before optional prediction: 48 MiB of remaining space for next-word or short review work, 144 MiB for a cold full-sentence review and 32 MiB once it is loaded. At less than 24 MiB remaining the keyboard takes the same path as a warning. These are conservative admission budgets, not a claim about the Duo's memory ceiling.

Run the regression on a booted simulator with the app installed:

```sh
SIMULATOR_UDID=<simulator-uuid> Benchmarks/stability/pressure.sh
```

The runner substitutes a local text document for the host and uses the real key handlers, workers and compiled models. It warms both models, calls UIKit's memory-warning callback, checks that both are released, and exercises correction, Undo, repeated messages and a second host. With build 65 the sentence model remained loaded after the warning. Simulator memory figures describe the test process; they do not measure physical-device headroom or establish a crash rate. Installed-extension UI coverage also exercises sentence correction and Undo, switching Safari fields, and glide typing.

Run UI tests of unpersonalized behavior on a fresh simulator. The correction test deliberately undoes “goes” and the glide test picks “too” instead of “to”; repeated runs can teach those exact preferences. We verified both preferences on the reused test simulator without resetting any spelling memory. A personalized keyboard preserving those choices is expected.

In the build 66 synthetic pressure replay the process footprint was 110 MiB with both models loaded and 102 MiB just after releasing them. The runner separately verifies object release and continued typing; the memory allocator and framework caches need not return every byte immediately.
