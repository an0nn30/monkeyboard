"""Check every previous long-word loss and gain against simulator predictions."""
import argparse
import json
from pathlib import Path
from cohorts import records

def verify(cohort, current, baseline):
    previous = json.loads((Path(__file__).resolve().parents[1] / "build59/results.json").read_bytes())
    expected_ids = [r["id"] for r in records(cohort)]
    outputs = {}
    for build, path in ((59, baseline), (60, current)):
        rows = list(records(path))
        assert [r["id"] for r in rows] == expected_ids and len(expected_ids) == len(set(expected_ids)) == 66
        outputs[build] = {r["id"]: r["words"] for r in rows}
    report = {}
    for name, source in (("recovered", "long_lost"), ("retained", "long_gained")):
        examples = []
        for row in previous[source]:
            identifier, word = row["id"], row["word"]
            assert outputs[59][identifier] == row["build59"], "Build 59 replay differs from the recorded comparison"
            guesses = outputs[60][identifier]
            examples.append(dict(id=identifier, word=word, build59=row["build59"], build60=guesses))
        report[name] = {"correct": sum(r["build60"][:1] == [r["word"]] for r in examples),
                        "count": len(examples), "examples": examples}
    return report

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ("cohort", "current", "baseline"):
        parser.add_argument(name, type=Path)
    print(json.dumps(verify(**vars(parser.parse_args())), indent=2))
