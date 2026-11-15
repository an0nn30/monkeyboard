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
// Restore an omitted apostrophe when the learned spelling wins against the literal.
int32_t mb_contraction_v1(const char *left, const char *word, const char *right, char *out, size_t capacity);
// Return a supported split or touch repair (1), no match (0), or a buffer/input error (-1).
int32_t mb_touch_repair_v1(const char *context, const char *word, const uint32_t *neighbor_masks, char *out, size_t capacity);
// One training-supported spelling (1), no evidence (0), or invalid input (-1).
int32_t mb_attested_v1(const char *context, const char *word, char *out, size_t capacity);
// Write up to four rows of context length and next-word counts. Returns byte count or -1.
int32_t mb_phrase_evidence_v1(const char *context, char *out, size_t capacity);
// Occurrence count in the built-in English lexicon. Zero for an absent word.
uint32_t mb_frequency_v1(const char *word);
// Learned safeguards and accidental internal space detector.
int32_t mb_keep_literal53_v1(const char *left, const char *typed, const char *right, const char *replacement);
int32_t mb_original_name54_v1(const char *typed);
int32_t mb_residual_name54_v1(const char *typed, const char *proposed);
int32_t mb_context53_v1(const char *left, const char *typed, const char *right, char *out, size_t capacity);
int32_t mb_rejoin53_v1(const char *first, const char *second);
// Score tab-separated lowercase candidates under the current sentence.
int32_t mb_sentence_scores_v1(const char *context, const char *candidates, float *out, size_t capacity);
// Additional evidence among candidates; -1 preserves the original spelling policy.
int32_t mb_refine_v1(const char *context, const char *typed, const char *baseline, const char *candidates);
// Missing-space candidate: 1 = commit, 2 = defer, 0 = abstain, -1 = invalid.
int32_t mb_boundary_v1(const char *previous, const char *word, char *out, size_t capacity);
int32_t mb_literal_supported_v1(const char *left, const char *typed, const char *right, const char *proposal);
int32_t mb_context_agrees_v1(const char *left, const char *typed, const char *right, const char *proposal);
int32_t mb_supported_opening_v1(const char *span, const char *proposed);
int32_t mb_midword_lowercase_v1(const char *word);
int32_t mb_uncorroborated_v1(const char *left, const char *typed, const char *right, const char *proposal);
int32_t mb_real25_v1(const char *left, const char *typed, const char *right, char *out, size_t capacity);
int32_t mb_textspell30_v1(const char *left, const char *typed, const char *right, char *out, size_t capacity);
int32_t mb_casual_keep_v1(const char *left, const char *typed, const char *suggestion);
int32_t mb_pipeline22_v1(const char *typed, char *out, size_t capacity);
int32_t mb_denoise22_v1(const char *typed, char *out, size_t capacity);
int32_t mb_spelling22_v1(const char *left, const char *typed, const char *right, char *out, size_t capacity);
int32_t mb_spelling22_known_v1(const char *typed);
int32_t mb_wordnet22_v1(const char *left, const char *typed, const char *right, int32_t accepted, char *out, size_t capacity);
int32_t mb_trained_split_v1(const char *previous, const char *word, char *out, size_t capacity);
uint32_t mb_pair_support_v1(const char *left, const char *right);
// Corroborate a native exact two-word guess. Zero for a known whole word.
int32_t mb_supports_split_v1(const char *previous, const char *word, const char *candidate, uint32_t rank);
// True for a known single word that can be analyzed as a compound.
int32_t mb_whole_compound_v1(const char *word);
// Short-word noisy channel: 1 = correction, 2 = await context, 0 = no review.
int32_t mb_short_word_v1(const char *left, const char *typed, const char *right, char *out, size_t capacity);
int32_t mb_short_new_readout_v1(const char *left, const char *typed, const char *right, const char *chosen);
int32_t mb_short_unseen_v1(const char *word);
int32_t mb_short_pool_v1(const char *word, char *out, size_t capacity);
// Joint spelling and missing-space ranker. 1 = write repair, 0 = keep, -1 = invalid.
int32_t mb_residual53_v1(const char *left, const char *typed, const char *right, char *out, size_t capacity);
// English letter centers in a..z order, expressed in the same key-pitch units
// as the touch samples. The output holds up to three tab-separated words.
typedef struct { float x, y; } MBKeyCenter;
typedef struct { float x, y, seconds; } MBGlideSample;
int32_t mb_glide_v1(const MBKeyCenter *keys, size_t key_count, const MBGlideSample *samples, size_t count,
                    const char *context, char *out, size_t capacity);
#endif
