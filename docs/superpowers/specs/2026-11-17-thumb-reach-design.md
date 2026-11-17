# Thumb reach

Dustin approved adding a Layout setting that moves the iOS split keyboard toward the edges while keeping key sizes and the iOS appearance. Install and test only on the Duo simulator.

## Approach
Move each bank outward, tighten horizontal gaps modestly, and reduce lower-row inward offsets. Preserve every painted key’s width, height, font, corner radius, and vertical position. The unused space becomes center space. Scaling would shrink keys; translating alone would help landscape much more than portrait, so use the combined approach approved in chat.

A 0–100% slider under Layout runs from Original to Closer to edges. Default 0 preserves existing layouts. Apply only to iOS split layouts, including symbols and emoji search; joined, one-handed, numeric keypad, and Default retain their geometry. Keep at least 6pt between painted keys. Share the preference using the existing local keychain setting mechanism. Appearance previews use the same value.

Use original frames as the source of dimensions, adjusting only horizontal origins before calculating touch regions and swipe centers. Clear cached swipe geometry when the preference changes. Save and reload through the normal settings lifecycle. Leave the Duo simulator with iOS style and a visible closer setting for Dustin to try.

Live simulator diagnostics confirm landscape hosts the extension in an 801pt-wide input view on the 951pt display, with zero horizontal safe-area insets. The remaining 75pt on each side is outside the extension. Apple controls custom keyboard width; preserve those host constraints and move keys within the available area. At maximum reach the inner left home-row key moves about 32pt outward on this layout. Do not force a wider host or put interactive keys outside it.
