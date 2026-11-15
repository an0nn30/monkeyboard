"""Verify product/fixture hashes, agreement of two scorers, and the three distinct release gates."""
import argparse,gzip,hashlib,json,sys
from pathlib import Path
D=Path(__file__).parent.resolve()
sys.path.insert(0,str(D));from metrics import evaluate,load_outputs
import importlib.util
spec=importlib.util.spec_from_file_location('blind_report', D/'holdout/score.py'); blind=importlib.util.module_from_spec(spec);spec.loader.exec_module(blind)
def sha(f):return hashlib.sha256(f.read_bytes()).hexdigest()
def report(fixture,output,candidate,freeze):
    manifest=json.load(open(fixture.parent/'freeze.json'))
    assert manifest['fixture_sha256']==sha(fixture)
    product=json.load(open(freeze))
    assert sha(fixture.parent/'freeze.json')==product['holdout_manifest_sha256']
    assert product['replay_sha256']==sha(candidate/'replay')
    ext=candidate/'dd/Build/Products/Debug-iphonesimulator/MonkeyBoard.app/PlugIns/MonkeyBoardKeyboard.appex'
    for k,v in product['candidate_extension_files'].items():assert sha(ext/k)==v,k
    rows=json.load(open(fixture)); ids={r['id'] for r in rows}
    old,new=[load_outputs([output/f],ids) for f in ('baseline.jsonl.gz','candidate.jsonl.gz')]
    summary=blind.compare(rows,old,new)
    records={tag:evaluate(rows,obs) for tag,obs in [('baseline',old),('candidate',new)]}
    result={**summary,'event_counts':records,'input_sha256':{k:sha(output/k) for k in ['baseline.jsonl.gz','candidate.jsonl.gz']},'fixture_sha256':sha(fixture),'freeze_sha256':sha(freeze)}
    for tag,m in records.items():
        assert m['all_fixed']==summary['events_fixed']['all'][tag] and m['real-word_fixed']==summary['events_fixed']['real-word'][tag]
    m=records['candidate']
    result['at_least_80_percent']={a:m[a]*5>=m[b]*4 for a,b in [('all_fixed','all'),('real-word_fixed','real-word'),('noisy_exact','noisy')]}
    return result
if __name__=='__main__':
    a=argparse.ArgumentParser()
    for k in ['fixture','output','candidate','freeze']:a.add_argument(k,type=Path)
    p=a.parse_args();r=report(p.fixture,p.output,p.candidate,p.freeze);(p.output/'report.json').write_text(json.dumps(r,indent=2,sort_keys=True)+'\n')
    print(json.dumps({'counts':r['event_counts'],'gates':r['at_least_80_percent']},sort_keys=True))
