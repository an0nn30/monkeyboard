# Personal typing preferences — planned, not active in build 8

Goal: make MonkeyBoard sound more like the individual typing and stop repeating corrections they reject. Keep the shared English model reproducible; layer preferences over its candidates on device. Build 8 stores no typing examples or preference counters.

Start with two explicit signals in ordinary English fields:

- Choosing a next-word suggestion can boost that word in a similar context. Only count an explicit selection; merely displaying a suggestion or inserting our own replacement is not acceptance.
- Immediately undoing a correction, or choosing the literal spelling, can lower the priority of that specific replacement. One rejection restores the word immediately; repeated rejections should eventually make the pair suggestion-only. A later explicit choice can reverse that preference.

First prototype with *synthetic* event replay: two profiles choose different words for the same prompt; one repeatedly rejects the same spelling change. Measure fewer repeated bad corrections, better top-three ranking for that profile, and no regression on new messages. Evaluate majority vs minority styles separately. Keep base safety checks and never let a preference edit across the caret or override a field that disables correction.

Before retaining any real signal: provide an explicit opt-in and a “Reset learned typing” control. Retain only bounded, decaying counts for eligible word IDs and replacement pairs locally; exclude sensitive fields, handles, URLs, identifiers and personal lexicon entries. Never store message bodies, ordered event streams, or raw touch traces. Avoid hashing arbitrary typed strings as a substitute for these limits. Learning unknown names or entirely new words needs a separate explicit user action/design. Turning learning off should disable use and collection; resetting should erase counts. No device upload or global retraining is part of this design.
