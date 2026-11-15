"""Diagnostic target-level and sentence-level slices; never used in training."""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).parent / 'blind'))
from score import scan, observe, load_outputs


def compare(inputs, baseline, candidate):
    rows=json.loads(inputs.read_bytes())
    ids={row['id'] for row in rows}
    if len(ids)!=len(rows): raise ValueError('Duplicate case ID')
    outputs={k:load_outputs([f],ids) for k,f in [('build21',baseline),('candidate',candidate)]}
    result={k:defaultdict(Counter) for k in outputs}
    for row in rows:
        expected=row['expected']
        ref=scan(expected)
        typed=observe(ref,scan(row['typed']))
        errors=[i for i,(a,b) in enumerate(zip(typed.slots,ref.words)) if a!=b]
        for label,predictions in outputs.items():
            pred=predictions[row['id']]
            final=observe(ref,scan(pred))
            for j in errors:
                src, gold, output=typed.slots[j],ref.words[j],final.slots[j]
                # This bucket is defined by the length of the intended word
                # (including joins/deletions), not dictionary acceptance.
                kind='target_2_to_3' if 2<=len(gold)<=3 else 'other_length'
                for key in [kind, row['split']+'/'+kind]:
                    c=result[label][key];c['damaged']+=1;c['recovered']+=output==gold
                    c['wrong_replacement']+=output!=gold and output!=src
            if len(errors)>=2:
                for key in ['multi_target_sentence',row['split']+'/multi_target_sentence']:
                    c=result[label][key];c['sentences']+=1;c['exact']+=pred==expected
                    c['damaged']+=len(errors);c['recovered']+=sum(final.slots[j]==ref.words[j] for j in errors)
            c=result[label]['whole_file']
            c['exact_excluding_terminal_punctuation_only']+=pred.rstrip('.!?')==expected.rstrip('.!?')
            c['exact_all_words']+=scan(pred).words==ref.words
            c['terminal_punctuation_only_miss']+=pred!=expected and pred.rstrip('.!?')==expected.rstrip('.!?')
    return result


if __name__=='__main__':
    cli=argparse.ArgumentParser(description=__doc__)
    for name in ('inputs','baseline','candidate','out'): cli.add_argument(name,type=Path)
    args=cli.parse_args()
    args.out.write_text(json.dumps(compare(args.inputs,args.baseline,args.candidate),indent=2,sort_keys=True)+'\n')
