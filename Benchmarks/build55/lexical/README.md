# Lexical search for build 55

The keyboard generates candidate words by transposing adjacent characters, moving a character by up to three positions, inserting or deleting a character, replacing a letter, dividing the input into two known words, looking up identical pronunciations, and comparing common words at two Damerau edits when the first search is inconclusive. Near-key substitutions use staggered QWERTY key coordinates. The context score uses left, internal and right bigram counts from the existing training partition. Only the sentence ranker can authorize changing an established spelling on context alone.

The resource contains word frequency, WordNet lexical forms, homophones, aggregate name spellings and text-message headwords. Homophones are obtained by grouping CMUdict pronunciations after removing stress. The name guard excludes spellings with evidence of common-word usage. The compact binary stores sorted 64-bit word hashes, flags, frequencies, context vocabulary IDs and previously trained bigram counts. The generator checks for collisions. The extension maps the binary on demand, keeps two-character affix lists for the two-edit fallback, and caches the most recent candidate pools. It makes no network requests.

## Reproduce

Use Python 3 with `wordfreq==3.1.1` and `rdata==1.1.0`. Obtain WordNet 3.0 from [Princeton](https://wordnet.princeton.edu/download/current-version), `cmudict.dict` and `LICENSE` from [CMUdict commit 74790861](https://github.com/cmusphinx/cmudict/tree/74790861f652b15e4ac49015a90074ad62a27690), and `babynames.rda` from [Hadley Wickham’s CC0 SSA data package](https://github.com/hadley/babynames/tree/master/data). The checked-in Wiktionary and Wikidata spelling snapshots make reproduction independent of changes to those services. The resource builder verifies the pinned CMU and SSA files before use.

```sh
python Benchmarks/build55/lexical/build.py \
  --wordnet "$WORDNET_3" --cmu "$CMU_DICT" --cmu-license "$CMU_LICENSE" --names "$SSA_RDA"
swiftc -O Keyboard/Lexical55.swift Benchmarks/build55/lexical/main.swift -o /tmp/lexical55
python Benchmarks/build55/lexical/evaluate.py /tmp/lexical55
```

The evaluation uses only historical build 53 and 54 replay fixtures. “Overlay repairs” counts a lexical decision at the annotated source position when available, otherwise the frozen baseline result. It cannot account for changes in the sequence of earlier controller decisions. “In candidates” is an upper bound on the neural ranker's available alternatives at the requested limit. Saving an evaluation sentence or its target word as a correction rule is unnecessary.

## Redistribution

[NOTICE.txt](NOTICE.txt) contains attribution, license text and source links. The same notices are embedded in the deployed lexical TSV. The derived frequency and vocabulary data are redistributed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). The pairing model uses existing aggregate context counts. No training or test sentences are included in the lookup resources.
