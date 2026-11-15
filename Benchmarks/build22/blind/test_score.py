"""Small alignment regressions that affect reported keyboard safety metrics."""
import unittest
from score import observe, scan, score_sentence


def metrics(gold, typed, out):
    ref = scan(gold)
    return score_sentence({'expected':gold, 'typed':typed}, out, ref,
                          observe(ref, scan(typed)), observe(ref, ref).punctuation)


class ScoreTests(unittest.TestCase):
    def test_correct_repair_preserves_other_words(self):
        s = metrics("I'll bring the red cups.", "I'll bring teh red cups.", "I'll bring the red cups.")
        self.assertEqual((s['fixed_slots'], s['intended_words'], s['collateral_words'], s['exact']), (1, 4, 0, 1))

    def test_valid_but_wrong_substitution_and_collateral(self):
        s = metrics("Bo drove the van.", "Bo dreve the van.", "Be drive the van.")
        self.assertEqual((s['wrong_replacement_slots'], s['collateral_words'], s['output_word_edits']), (1, 1, 2))

    def test_counts_new_and_removed_insertions(self):
        s = metrics("bring coats today", "bring big coats today", "bring coats here today")
        self.assertEqual((s['input_inserted_words'], s['removed_input_insertions'],
                          s['new_inserted_words'], s['output_inserted_words']), (1, 1, 1, 1))

    def test_counts_new_deletions(self):
        s = metrics("I found Meg there.", "I found Meg there.", "I found there.")
        self.assertEqual((s['collateral_words'], s['newly_deleted_intended_words'], s['output_deleted_words']), (1, 1, 1))

    def test_punctuation_and_case_score_even_when_words_match(self):
        s = metrics("Ren, will you go?", "Ren, will you go?", "ren will, you go?")
        self.assertEqual((s['output_case_only_substitutions'], s['exact'], s['new_punctuation_damage_rows'],
                          s['output_punctuation_mismatch_sites']), (1, 0, 1, 2))

    def test_internal_apostrophe_change(self):
        s = metrics("Aren't you going?", "Arent you going?", "Aren't you going?")
        self.assertEqual((s['punctuation_recovered_rows'], s['fixed_slots'], s['exact']), (1,1,1))

    def test_insertions_do_not_move_later_punctuation(self):
        s = metrics("Hi Jo, thanks!", "Hi Jo, thanks!", "Hi there Jo, thanks!")
        self.assertEqual((s['output_punctuation_exact'], s['output_inserted_words']), (1,1))

    def test_damaged_slots_decompose_with_missing_word(self):
        s = metrics("Are you two there?", "Are too ther?", "Are too this?")
        self.assertEqual(s['damaged_slots'], s['fixed_slots'] + s['missed_unchanged_slots'] + s['wrong_replacement_slots'])
        self.assertEqual(s['input_deleted_words'], 1)

    def test_whitespace_counts_for_exact(self):
        s = metrics("See  you soon!", "See  you soon!", "See you soon!")
        self.assertEqual((s['clean_exact'], s['output_punctuation_exact'], s['output_word_edits']), (0,1,0))


if __name__ == '__main__':
    unittest.main()
