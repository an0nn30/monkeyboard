"""Full-document paired comparison, including named/shorthand token annotations."""
import gzip,importlib.util,json,re,sys
from collections import Counter
from pathlib import Path
HERE=Path(__file__).resolve().parent
# Load reference scorer under its original name (this script is also named score).
sys.path.insert(0,str(HERE.parent/'build22/blind'))
spec=importlib.util.spec_from_file_location('compare_builds', HERE.parent/'build44/compare.py')
cmp=importlib.util.module_from_spec(spec);spec.loader.exec_module(cmp)
from score import WORD

def evaluate(fixture,baseline,candidate,version="53"):
    rows=json.loads(fixture.read_bytes())
    ids={r['id'] for r in rows}
    report=cmp.compare(fixture,{'52':baseline,version:candidate},version)
    old,new=[cmp.load_outputs([p],ids) for p in (baseline,candidate)]
    metrics=Counter(); protected={}; differences=[]
    for r in rows:
        i=r['id']; labels=r.get('protected',[])
        ref=cmp.scan(r['expected'])
        t,a,b=[cmp.observe(ref,cmp.scan(t)).slots for t in (r['typed'],old[i],new[i])]
        spans=list(WORD.finditer(r['expected']))
        # Annotations index whitespace tokens, but model scoring ignores punctuation
        # outside words. Translate by character offset so insertions before a name
        # never make its score depend on the wrong token.
        boundaries=list(re.finditer(r'\S+',r['expected']))
        for item in labels:
            j=item['expected_index']; match=boundaries[j]
            positions=[k for k,m in enumerate(spans) if match.start()<=m.start()<match.end()]
            assert positions and all(t[k]==ref.words[k] for k in positions),(i,item)
            tags=protected.setdefault(item['category'],Counter())
            for obj in (tags,metrics):
                obj['intended_tokens']+=1
                keep_a=all(a[k]==ref.words[k] for k in positions)
                keep_b=all(b[k]==ref.words[k] for k in positions)
                obj['kept_52']+=keep_a
                obj['kept_'+version]+=keep_b
                obj['newly_harmed']+=keep_a and not keep_b
                obj['restored']+=keep_b and not keep_a
        if old[i]!=new[i]:
            differences.append({'id':i,'typed':r['typed'],'expected':r['expected'],'build52':old[i],'build'+version:new[i]})
    report.update(protected_by_kind=protected, protected_total=metrics, differences=differences)
    return report
if __name__=='__main__':
    fixture,base,new,out=map(Path,sys.argv[1:5])
    version = sys.argv[5] if len(sys.argv)>5 else '53'
    out.write_text(json.dumps(evaluate(fixture,base,new,version),indent=2,ensure_ascii=False)+'\n')
