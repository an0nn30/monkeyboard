"""Export common English gesture words; the existing words.tsv adds project vocabulary.
Source: wordfreq 3.1.1, Robyn Speer. See Benchmarks/build55/model/NOTICE.txt.
"""
import re
from pathlib import Path
from wordfreq import iter_wordlist, zipf_frequency

def main():
    path = Path(__file__).resolve().parents[1] / "model" / "glide-words.tsv"
    words = {}
    long_words = {}
    for token in iter_wordlist("en"):
        word = token.replace("’", "'")
        if re.fullmatch(r"[a-z]+(?:'[a-z]+)*", word) and 2 <= len(word) <= 24:
            if len(words) < 40000:
                words[word] = round(100 * zipf_frequency(token, "en"))
            elif len(word) >= 7 and word not in words:
                long_words[word] = round(100 * zipf_frequency(token, "en"))
                if len(long_words) >= 120000:
                    break
    for dest, entries in [(path, words), (path.with_name("glide-long.tsv"), long_words)]:
        with dest.open("w") as out:
            for word, frequency in sorted(entries.items()):
                print(word, frequency, sep="\t", file=out)

if __name__ == "__main__":
    main()
