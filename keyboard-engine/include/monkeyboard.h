#ifndef MONKEYBOARD_ENGINE_H
#define MONKEYBOARD_ENGINE_H
#include <stddef.h>
#include <stdint.h>
// v1. All pointers borrowed for this call only. Input is NUL-terminated UTF-8.
// Result is a NUL-terminated list separated by tabs in caller-owned output;
// 1 = first candidate qualifies for automatic replacement, 0 = display only,
// -1 = invalid request or insufficient output capacity. No text is retained.
// For correction, context ends *before* the word; the scorer considers up to four preceding words.
// neighbor_masks: optional 26-element array. Bit j in row i means adjacent
// rendered key centers; null disables geometric weighting.
int32_t mb_rank_v1(const char *context, const char *word, const uint32_t *neighbor_masks, char *out, size_t capacity);
// Return a supported split or touch repair (1), no match (0), or a buffer/input error (-1).
int32_t mb_touch_repair_v1(const char *context, const char *word, const uint32_t *neighbor_masks, char *out, size_t capacity);
// One training-supported spelling (1), no evidence (0), or invalid input (-1).
int32_t mb_attested_v1(const char *context, const char *word, char *out, size_t capacity);
// Write up to four rows of context length and next-word counts. Returns byte count or -1.
int32_t mb_phrase_evidence_v1(const char *context, char *out, size_t capacity);
// Occurrence count in the built-in English lexicon. Zero for an absent word.
uint32_t mb_frequency_v1(const char *word);
// Score tab-separated lowercase candidates under the current sentence.
int32_t mb_sentence_scores_v1(const char *context, const char *candidates, float *out, size_t capacity);
// Additional evidence among candidates; -1 preserves the original spelling policy.
int32_t mb_refine_v1(const char *context, const char *typed, const char *baseline, const char *candidates);
// Missing-space candidate: 1 = commit, 2 = defer, 0 = abstain, -1 = invalid.
int32_t mb_boundary_v1(const char *previous, const char *word, char *out, size_t capacity);
uint32_t mb_pair_support_v1(const char *left, const char *right);
// Corroborate a native exact two-word guess. Zero for a known whole word.
int32_t mb_supports_split_v1(const char *previous, const char *word, const char *candidate, uint32_t rank);
#endif
