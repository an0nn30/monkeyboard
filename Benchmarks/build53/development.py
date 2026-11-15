"""Audit the previously disclosed failures by ID and aligned reference position."""
import gzip, json, sys
from pathlib import Path
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'build22/blind'))
from score import load_outputs, observe, scan

def extract():
    dev, failed, changed = [], [], []
    for suite in ('fresh', 'public'):
        rows = json.loads((HERE.parent/f'build51/{suite}.json').read_bytes())
        outputs = load_outputs([HERE.parent/f'build52/{suite}-52.jsonl.gz'], {r['id'] for r in rows})
        for row in rows:
            row = dict(row)
            output = outputs[row['id']]
            row['id'] = suite + ':' + row['id']
            dev.append(row)
            ref = scan(row['expected'])
            before, after = [observe(ref, scan(s)).slots for s in [row['typed'],output]]
            for i, (w,b,a) in enumerate(zip(ref.words,before,after)):
                if b != w and a != w:
                    failed.append(dict(id=row['id'], index=i, typed=b, target=w, actual=a))
            if row['expected'] == row['typed'] != output:
                changed.append(dict(id=row['id'], expected=row['expected'], actual=output))
    assert (len(dev),len(failed),len(changed)) == (196,69,15)
    return dev, dict(typos=failed, clean=changed)
if __name__ == '__main__':
    for filename, obj in zip(('development.json','old-failures.json'), extract()):
        (HERE/filename).write_text(json.dumps(obj, indent=2, ensure_ascii=False)+'\n')
