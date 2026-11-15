"""Export evidence for disagreeing long-word candidates using the development-only Rust ABI."""
import argparse
import ctypes as C
from concurrent.futures import ProcessPoolExecutor
import json
import math
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from score import Point, Sample
from cohorts import label, records

def setup(library, layout):
    global keys, decode
    keys = (Point * 26)()
    for k in json.loads(layout.read_bytes())["keys"]:
        keys[ord(k["letter"]) - 97] = Point(k["cx"] * 10, k["cy"] * 3)
    decode = C.CDLL(str(library.resolve())).mb_glide_training_pair
    decode.argtypes = [C.POINTER(Point), C.POINTER(Sample), C.c_size_t,
                       C.POINTER(C.c_float), C.POINTER(C.c_char)]

def evidence(row):
    trace = row["data"]
    if len(trace) > 256:
        trace = [trace[round(i * (len(trace) - 1) / 255)] for i in range(256)]
    if len(trace) < 2:
        return None
    points = [(p["x"] * 10, p["y"] * 3, (p["t"] - trace[0]["t"]) / 1000) for p in trace]
    if max(math.dist(p[:2], points[0][:2]) for p in points) < 1.3:
        return None
    values = (C.c_float * 64)()
    names = C.create_string_buffer(64)
    count = decode(keys, (Sample * len(points))(*(Sample(*p) for p in points)), len(points), values, names)
    if count < 0:
        raise ValueError(f"Invalid input for gesture {row['id']}")
    if count:
        return dict(id=row["id"], word=label(row), pair=names.value.decode().split(), features=list(values[:count]))
    return None

if __name__ == "__main__":
    parser=argparse.ArgumentParser()
    for name in ("library", "layout", "cohort", "output"):
        parser.add_argument(name, type=Path)
    parser.add_argument("--workers", type=int, default=4)
    args=parser.parse_args()
    with ProcessPoolExecutor(args.workers, initializer=setup, initargs=(args.library, args.layout)) as pool:
        with args.output.open("w") as output:
            for row in pool.map(evidence, records(args.cohort), chunksize=32):
                if row is not None:
                    print(json.dumps(row, separators=(",", ":")), file=output)
