"""Protect known single words where native spelling and lexical splitting may disagree."""
import argparse, hashlib
from pathlib import Path
from paired_text import engine

def collect(dictionary):
    wordlist={s.strip().lower() for s in dictionary.read_text(encoding='utf-8').splitlines()
              if s.isascii() and s.isalpha() and 4<=len(s)<=32}
    lex=set()
    for name in ('words.tsv','boundary-counts.tsv','decoder15m/decoder-vocab.tsv'):
        with (engine/'model'/name).open() as f:
            lex.update(k for line in f if (k:=line.split('\t')[0]).isascii() and k.isalpha())
    wordlist={s for s in wordlist if any(s[:i] in lex and s[i:] in lex for i in range(1,len(s)))}
    # Exact entries, no probabilistic membership. Standard plural/inflection
    # variants of gated nouns are recognized with a second lookup at runtime.
    return sorted(wordlist)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('wordlist',type=Path,default=Path('/usr/share/dict/web2'),nargs='?')
    src=p.parse_args().wordlist;words=collect(src);out=engine/'model/whole-compounds.txt'
    out.write_text('\n'.join(words)+'\n');print('source sha256',hashlib.sha256(src.read_bytes()).hexdigest(),'entries',len(words),'bytes',out.stat().st_size)
