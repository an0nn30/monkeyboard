"""Refresh the source vocabulary of text-message spellings from English Wiktionary."""
import json
from pathlib import Path
import re
import urllib.parse
import urllib.request

CATEGORIES = ('Category:English text messaging slang', 'Category:English internet slang')


def category_words(category):
    params = dict(action='query', list='categorymembers', cmtitle=category, cmnamespace=0, cmlimit=500, format='json')
    words = set()
    while True:
        url = 'https://en.wiktionary.org/w/api.php?' + urllib.parse.urlencode(params)
        request = urllib.request.Request(url, headers={'User-Agent': 'MonkeyBoardLexiconBuilder/1.0 (offline mobile keyboard)'})
        with urllib.request.urlopen(request, timeout=30) as response:
            obj = json.load(response)
        for entry in obj['query']['categorymembers']:
            word = entry['title'].lower()
            if re.fullmatch(r"[a-z]+(?:'[a-z]+)*", word):
                words.add(word)
        if 'continue' not in obj:
            break
        params.update(obj['continue'])
    return words


def fetch():
    words = set.union(*(category_words(category) for category in CATEGORIES))
    target = Path(__file__).with_name('texting-words.txt')
    target.write_text('# Lowercase headwords only. English Wiktionary contributors, CC BY-SA 4.0\n'
                      '# https://en.wiktionary.org/wiki/Category:English_text_messaging_slang\n'
                      '# https://en.wiktionary.org/wiki/Category:English_internet_slang\n'
                      + '\n'.join(sorted(words)) + '\n')
    print(len(words), 'text-message spellings')


if __name__ == '__main__':
    fetch()
