# Offline contextual model

The keyboard uses the case-sensitive English RoBERTa-base masked language model from Facebook AI. The frozen encoder reads both sides of a word. MonkeyBoard supplies spelling candidates and compares their model scores against the typed spelling. Its vocabulary, weights and tokenizer run locally. See the [checkpoint](https://huggingface.co/FacebookAI/roberta-base/tree/e2da8e2f811d1448a5b465c236feacd80ffbac7b) and [original paper](https://arxiv.org/abs/1907.11692).

The export uses the 12 pretrained blocks, 8-bit per-block weight quantization, and row-wise 8-bit quantization for the 50,265 tied input/output embeddings. Swift memory-maps these embeddings and scores the supplied candidates. The Core ML output includes unnormalized logits for a common vocabulary. Swift calculates their log-sum-exp in float32 using max subtraction. This avoids overflow in float16 GPU reductions.

The [licensing notice](NOTICE.txt) covers the encoder and the lexical frequency table. Its text is included in the shipped tokenizer resource.

## Reproduce

Run from the repository root on macOS with Python 3.11. The model download is only needed for export.

```sh
uv venv --python 3.11 /tmp/mb-context55
uv pip install --python /tmp/mb-context55/bin/python \
  'torch==2.7.1' 'transformers==4.55.4' 'coremltools==9.0' \
  'numpy==1.26.4' 'wordfreq==3.1.1'
mkdir -p /tmp/mb-roberta
checkpoint=https://huggingface.co/FacebookAI/roberta-base/resolve/e2da8e2f811d1448a5b465c236feacd80ffbac7b
for asset in config.json merges.txt vocab.json model.safetensors; do
  curl -fLsS "$checkpoint/$asset" -o "/tmp/mb-roberta/$asset" || exit 1
done
TOKENIZERS_PARALLELISM=false /tmp/mb-context55/bin/python \
  Benchmarks/build55/model/export.py /tmp/mb-roberta Keyboard/Resources --bits 8
```

The SHA-256 of the source safetensors file is `5bde1d28afb363d0103324efeb5afc8b2b397fe5e04beabb9b1ef355255ade81`. The converter uses the frozen weights without training on test sentences.
