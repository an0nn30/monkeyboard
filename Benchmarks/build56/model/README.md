# Contextual wrong-word detector

Build 56 adds a learned detector to the existing offline RoBERTa-base encoder. It estimates whether a word belongs in its sentence by reading the sentence with the word visible. The keyboard obtains that estimate for the original spelling and plausible replacements. It combines these estimates with masked-word prediction, neighboring-word likelihood and the keyboard's phonetic candidates. The final acceptance decision uses a separate logistic model.

The detector pools the marked word's subword states from transformer layers 4, 8 and 12. A 192-unit hidden layer produces one corruption logit. The frozen transformer, shared input and output embeddings, and byte-pair tokenizer come from [Facebook AI RoBERTa-base, revision e2da8e2](https://huggingface.co/FacebookAI/roberta-base/tree/e2da8e2f811d1448a5b465c236feacd80ffbac7b). Masked-word normalization uses 8,193 common anchor tokens. The exported weights use 8-bit per-block quantization. The keyboard loads the Core ML package and vocabulary locally.

## Training and calibration

The detector trained on 42,000 paired examples. The trainer sampled a word from a public sentence, replaced it with a real word chosen from edit-distance neighbors or pronunciation matches, and evaluated both versions. It read English Tatoeba CC0 sentences and sampled utterances from Taskmaster-1 written dialogues. Candidate frequencies come from wordfreq 3.1.1, pronunciations from CMUdict. Sentence ordering, spelling sampling and optimizer initialization use seed 5613. The final 6% of shuffled pairs served as model-selection data. The selected epoch ranked the original above the synthetic replacement in 98.7% of those pairs. [Data attribution](NOTICE.txt) · [Encoder and word-frequency attribution](../../build55/model/NOTICE.txt)

The separate acceptance model used 766 numerical proposal records from released development fixtures 53, 54 and 55. Of these, 201 proposed replacements matched a needed correction. Each record contains the source cohort, binary label and ordered numerical features. Features cover masked-context score gain, candidate score, both detector logits, margin over the runner-up, raw typo provenance, noun tagging, word frequencies, edit distance, subword counts and word lengths. Logistic regression uses L2 regularization with `C=0.12`. The keyboard accepts a proposal above log odds −0.55. Results on these three fixtures measure development performance. The build 56 confirmation fixture was excluded from model training, calibration and development inspection.

## Reproduce the export

Use the [build 55 checkpoint download and Python environment](../../build55/model/README.md) from the repository root, then install the training and calibration dependencies. Exporting from the supplied detector recreates the encoder and acceptance coefficients.

```sh
uv pip install --python /tmp/mb-context55/bin/python \
  'cmudict==1.1.3' 'rapidfuzz==3.14.6' 'scikit-learn==1.9.1'
mkdir -p /tmp/mb56-export
TOKENIZERS_PARALLELISM=false OMP_NUM_THREADS=4 /tmp/mb-context55/bin/python \
  Benchmarks/build56/model/export.py /tmp/mb-roberta \
  Benchmarks/build56/model/detector.pt /tmp/mb56-export/MBMaskedEncoder.mlpackage
```

An independent export from the supplied model inputs reproduced the weights and vocabulary byte for byte. Their SHA-256 digests are `3f5f3f7121252902a2dfcde4debb109c96d7de3c13a3160004582e5b1a19220a` and `322114dc2a7d9314e57b893b505fea725b90c6227e66dc5e1257471f0995d02b`. The detector checkpoint digest is `facb384dea79c67a417629fcbc1f803a12e495005920cd3e724c43cfde53b442`.

To refit the detector on an Apple Silicon Mac equipped with MPS, use the pinned Taskmaster source and the repository's English CC0 corpus.

```sh
curl -fLsS https://raw.githubusercontent.com/google-research-datasets/Taskmaster/d92cb6af3005f1dc09c39e75e7daf4a04905e00b/TM-1-2019/self-dialogs.json \
  -o /tmp/mb-taskmaster-self-dialogs.json
TOKENIZERS_PARALLELISM=false /tmp/mb-context55/bin/python \
  Benchmarks/build56/model/train_detector.py /tmp/mb-roberta \
  keyboard-engine/training/eng_sentences_CC0.tsv.bz2 /tmp/mb56-fit \
  --dialogue /tmp/mb-taskmaster-self-dialogs.json
```

The Taskmaster file SHA-256 is `1e590ed0ccee279e40c2fb9e083d3b9417477c6bfe35ce5b2277167698dd858d`. The compressed Tatoeba file SHA-256 is `c2e2edd063a31cbbc8e416a4858225e934bbb0afff485031821e59f230ccf1ca`.
