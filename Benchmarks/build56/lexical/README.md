# Lexical search and name preservation

Build 56 uses the original typed word, its capitalization, and neighboring words to recognize likely names. An ambiguous lowercase given name must occupy a noun slot in the original sentence before the name tagger is consulted with an initial capital. This also supports names serving as the object of one verb and the subject of the following verb. An unknown capitalized word can be preserved when Apple's named-entity tagger identifies it as a person. This check works on the original occurrence, including names previously expanded to multiple words.

The spelling channel admits a trailing neighboring key, two adjacent transpositions, or one doubled key plus an adjacent transposition. A directly transposed dictionary word loses fewer competitions with unsupported two-word splits. Rare closed words also compete with their direct splits when WordNet attests their hyphenated form. Case and apostrophes are preserved across exact splits.

Common, established spellings have additional suggestions for the contextual ranker. The generator computes groups of words whose CMUdict pronunciations differ at exactly one phoneme, constrains orthographic distance and common ends, and adds nonadjacent letter exchanges. Each source contributes up to 24 additional alternatives. The compact adjacency section is read on demand from the mapped lexical resource. The standalone spelling channel never commits a change to an established word based only on its pronunciation. Three-edit spelling alternatives can reach the neural model if the source and replacement are verified single-phoneme alternatives.

## Reproduction

Start with the [build 55 lexical resources](../../build55/lexical/README.md). Run the augmentation using the same CMUdict, WordNet and SSA snapshots. The generator is idempotent. The expected Python environment adds `rapidfuzz==3.14.6` to the dependencies of the earlier lexical builder. The same licenses cover the augmented data. [Source attribution and notices](NOTICE.txt)

```sh
python Benchmarks/build56/lexical/build.py --names "$SSA_RDA" --wordnet "$WORDNET_3" --cmu "$CMU_DICT"
swiftc -O Keyboard/Lexical55.swift Benchmarks/build56/lexical/main.swift -o /tmp/lexical56
python Benchmarks/build56/lexical/evaluate.py /tmp/lexical56
```

[Development measurements](development.json) compare isolated decisions on released historical fixtures. The input and previously displayed word are aligned to the reference. A protected original replaces an existing edit at that position, otherwise a lexical repair overrides it when available. The table omits interactions between consecutive neural decisions. The [phonetic evaluation](phonetic-ab-development.json) compares the same native iterative finisher on the 276 released build 55 inputs with and without the peer index, using the previous controller's captured display as input. Independent evaluation requires the installed keyboard replay on the frozen confirmation fixture.

The verified build 56 lexical source SHA-256 is `d359c2e81b4f810170f6f5e3b0cdd0e360468790b13109f590c5223da06db5c1`. The binary SHA-256 is `38d367e5c9f21f15d0a183f291d14f6572fab74c7317f6926bcdbe506d9b9a71`. The build 55 TSV keeps SHA-256 `d0a2acceb9cb0fab430e91558df41b80bff1a93bf69547876f84c72fc0b9f8f3`.
