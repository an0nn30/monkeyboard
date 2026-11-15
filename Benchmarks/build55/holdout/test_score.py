"""Regression tests on made-up scorer examples outside either benchmark."""
import unittest

from score import compare


class MetricsTest(unittest.TestCase):
    def test_join_requires_adjacent_words_and_message_includes_punctuation(self):
        row = dict(
            id="sample", kind="mixed", typed="Ina movedtwo bocks!", expected="Ina moved two boxes!",
            edits=[dict(category="missing-space", expected="moved two", expected_index=1),
                   dict(category="ordinary", expected="boxes", expected_index=3)],
            protected=[dict(category="name", expected_index=0)],
        )
        for output in ("Ina moved three boxes!", "Ina moved just two boxes!"):
            report = compare([row], {"sample": row["expected"]}, {"sample": output})
            self.assertEqual(report["events_fixed"]["missing-space"]["lost"], 1)
            self.assertEqual(report["events_fixed"]["ordinary"]["candidate"], 1)
            self.assertEqual(report["messages_exact"]["noisy"]["candidate"], 0)
        report = compare([row], {"sample": row["typed"]}, {"sample": row["expected"][:-1]})
        self.assertEqual(report["events_fixed"]["all"]["gained"], 2)
        self.assertEqual(report["messages_exact"]["noisy"]["candidate"], 0)

    def test_protected_positions_tolerate_other_insertions_but_require_exact_case(self):
        row = dict(
            id="sample", kind="clean", expected="The card says Ina.", typed="The card says Ina.",
            edits=[], protected=[dict(category="name", expected_index=3)],
        )
        report = compare([row], {"sample": "Actually the card says Ina."}, {"sample": "The card says ina."})
        self.assertEqual(report["protected_preserved"]["name"]["lost"], 1)
        self.assertEqual(report["originally_correct_words_preserved"]["lost"], 1)
        self.assertEqual(report["messages_exact"]["clean"]["total"], 1)
        self.assertEqual(report["messages_exact"]["clean"]["candidate"], 0)


if __name__ == "__main__":
    unittest.main()
