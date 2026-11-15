"""Refresh aggregate spellings from the direct male and female given-name classes in Wikidata (CC0)."""
import argparse
import json
import gzip
import io
from pathlib import Path
import unicodedata
import urllib.parse
import urllib.request

CLASSES = ('Q11879590', 'Q12308941')


def main(cache):
    names = set()
    for item in CLASSES:
        cached = cache / (item + '.json')
        if cached.exists():
            obj = json.loads(cached.read_bytes())
        else:
            query = f'SELECT DISTINCT ?label WHERE {{ ?name wdt:P31 wd:{item} ; rdfs:label ?label . FILTER(LANG(?label)="en") }}'
            url = 'https://query.wikidata.org/sparql?' + urllib.parse.urlencode({'query': query, 'format': 'json'})
            request = urllib.request.Request(url, headers={'User-Agent': 'MonkeyBoardLexiconBuilder/1.0', 'Accept': 'application/sparql-results+json'})
            with urllib.request.urlopen(request, timeout=90) as response:
                raw = response.read()
            obj = json.loads(raw)
            cached.write_bytes(raw)
        for row in obj['results']['bindings']:
            s = row['label']['value'].lower()
            folded = ''.join(c for c in unicodedata.normalize('NFD', s) if not unicodedata.combining(c))
            if 2 <= len(folded) <= 24 and folded.isascii() and folded.isalpha():
                names.add(folded)
    data = ('# Lowercased and accent-folded English labels of given names. Wikidata contributors, CC0.\n'
            + '\n'.join(sorted(names)) + '\n').encode()
    target = Path(__file__).with_name('given-names.txt.gz')
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode='wb', mtime=0) as zipped:
        zipped.write(data)
    target.write_bytes(buffer.getvalue())
    print(len(names), 'Wikidata name spellings')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cache', type=Path)
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    main(args.cache)
