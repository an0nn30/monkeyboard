# iOS suggestion and baseline alignment

Dustin supplied Apple and MonkeyBoard screenshots and requested matching larger centered predictions, a lower keyboard, and word-related emoji suggestions. Continue the existing iOS style and Thumb reach; test and preview only on simulators. No device deployment or publishing was requested.

Use the existing UIKit layout, rather than a separate theme renderer. Remove the split-only blank prediction spacer and use 21pt system suggestion text with centered cells and subtle separators. Reclaim the hidden dismiss-footer space in portrait while keeping painted key sizes and Thumb reach geometry. Compare the resulting baseline with Apple in the Duo simulator before settling exact metrics.

Offer up to two emoji alongside two word candidates when the current word has a confident local match. Reuse the bundled English emoji data with a small exact-word index, without loading the large picker index or any extra model. Match whole words case-insensitively, allow common plurals, avoid fragment and function-word matches. A chosen emoji replaces the current word and leaves a separating space, with current document/context validation. Keep word correction learning separate, respect skin-tone preference where available, and suppress suggestions in numeric, secure, URL, selected-text and inside-word contexts. The standard theme may use the same emoji feature with its existing styling.

Alternatives considered: leaving predictions on the right fails the requested alignment; adding another model raises memory cost unnecessarily. Local keyword lookup and the existing suggestion pipeline meet the supplied examples. Exact equivalence to Apple's private contextual ranking is outside this implementation.
