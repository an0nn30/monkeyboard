"""Evaluate the shipping C decoder on a fixed sample of recorded gestures."""
import argparse
import ctypes as C
import hashlib
import json
import math
import re
import statistics
import time
from pathlib import Path


class Point(C.Structure):
    _fields_ = [("x", C.c_float), ("y", C.c_float)]


class Sample(C.Structure):
    _fields_ = Point._fields_ + [("seconds", C.c_float)]


def test_cases(data):
    rows = []
    for line in data.splitlines(keepends=True):
        if not line.endswith(b"\n"):
            continue  # The byte range can end inside a record.
        row = json.loads(line)
        word = row["word"].strip('.,:;!?“”"()').lower().replace("’", "'")
        if 2 <= len(word) <= 24 and re.fullmatch("[a-z]+(?:'[a-z]+)*", word):
            identifier = hashlib.sha256(str(row["id"]).encode()).digest()
            rows.append((identifier, word, row))
    rows.sort(key=lambda case: case[0])
    return rows[:512]


def score_gesture(decoder, keys, path):
    if len(path) > 256:
        path = [path[round(i * (len(path) - 1) / 255)] for i in range(256)]
    if len(path) < 2:
        return []
    start = path[0]
    points = [(p["x"] * 10, p["y"] * 3, (p["t"] - start["t"]) / 1000) for p in path]
    if max(math.dist(p[:2], points[0][:2]) for p in points) < 1.3:
        return []  # The keyboard reserves short slides for correcting a tap.
    samples = (Sample * len(points))(*(Sample(*p) for p in points))
    output = C.create_string_buffer(128)
    count = decoder(keys, 26, samples, len(samples), b"", output, len(output))
    if count < 0:
        raise ValueError("Glide decoder rejected the benchmark input")
    return output.value.decode().split()


def evaluate(library, layout, source):
    keys = (Point * 26)()
    for key in json.loads(layout.read_bytes())["keys"]:
        keys[ord(key["letter"]) - ord("a")] = Point(key["cx"] * 10, key["cy"] * 3)
    decoder = C.CDLL(str(library.resolve())).mb_glide_v1
    decoder.argtypes = [C.POINTER(Point), C.c_size_t, C.POINTER(Sample), C.c_size_t,
                        C.c_char_p, C.POINTER(C.c_char), C.c_size_t]
    data = source.read_bytes()
    cases = test_cases(data)
    if not cases:
        raise ValueError("No complete, eligible gestures in the supplied data")
    lengths = {name: dict(gestures=0, top1=0, top3=0) for name in ("2-3", "4-6", "7+")}
    times = []
    sessions = set()
    no_guess = 0
    for _, expected, row in cases:
        sessions.add(row["session"])
        tick = time.perf_counter()
        guesses = score_gesture(decoder, keys, row["data"])
        times.append((time.perf_counter() - tick) * 1000)
        group = "2-3" if len(expected) <= 3 else "4-6" if len(expected) <= 6 else "7+"
        lengths[group]["gestures"] += 1
        lengths[group]["top1"] += guesses[:1] == [expected]
        lengths[group]["top3"] += expected in guesses
        no_guess += not guesses
    return dict(gestures=len(cases), sessions=len(sessions),
                top1=sum(r["top1"] for r in lengths.values()),
                top3=sum(r["top3"] for r in lengths.values()), no_guess=no_guess,
                by_word_length=lengths, median_ms=round(statistics.median(times), 2),
                p95_ms=round(sorted(times)[math.ceil(0.95 * len(times)) - 1], 2),
                prefix_sha256=hashlib.sha256(data).hexdigest())


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ["library", "layout", "source"]:
        parser.add_argument(name, type=Path)
    print(json.dumps(evaluate(**vars(parser.parse_args())), indent=2))
