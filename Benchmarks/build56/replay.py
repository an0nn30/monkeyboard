"""Independent fresh documents, submitted to concurrent instances of the same frozen Duo binary.
Pass only ID and actual keys; no reference answers enter simulator processes. Fail on missing or duplicate output.
"""
from concurrent.futures import ThreadPoolExecutor
import argparse,gzip,json,os,subprocess,tempfile,hashlib
from pathlib import Path
def run(args):
    rows=json.loads(args.fixture.read_bytes()); ids=[r['id'] for r in rows]
    assert len(set(ids))==len(ids)
    ext=args.build/'dd/Build/Products/Debug-iphonesimulator/MonkeyBoard.app/PlugIns/MonkeyBoardKeyboard.appex'
    bins=args.build/'replay'
    n=max(1,min(args.workers,len(rows)))
    with tempfile.TemporaryDirectory() as td:
        directory=Path(td)
        def part(index):
            chunk=rows[index::n]
            path=directory/f'{index}.json'
            path.write_text(json.dumps([{'id':r['id'],'typed':r['typed']} for r in chunk],ensure_ascii=False))
            env=os.environ.copy();env['SIMCTL_CHILD_MB_REPLAY_TIMING']='1'
            if args.require_model:env['SIMCTL_CHILD_MB_REQUIRE_SENTENCE_MODEL']='1'
            p=subprocess.run(['xcrun','simctl','spawn',args.sim,str(bins),str(ext),str(path)],capture_output=True,check=True,env=env)
            results=[json.loads(s) for s in p.stdout.splitlines()]
            assert len(results)==len(chunk) and [x['id'] for x in results]==[r['id'] for r in chunk]
            return results,p.stderr.decode(errors='replace')
        with ThreadPoolExecutor(max_workers=n) as pool: results=list(pool.map(part,range(n)))
        out={r['id']:r for chunk,_ in results for r in chunk}
        assert set(out)==set(ids) and all(isinstance(v['final'],str) for v in out.values())
        data=''.join(json.dumps(out[k],sort_keys=True,ensure_ascii=False,separators=(',',':'))+'\n' for k in ids)
        args.out.parent.mkdir(exist_ok=True,parents=True)
        args.out.write_bytes(gzip.compress(data.encode(),mtime=0))
        args.out.with_suffix('.run.json').write_text(json.dumps(dict(sim=args.sim,shards=n,replay_sha256=hashlib.sha256(bins.read_bytes()).hexdigest(),fixture_sha256=hashlib.sha256(args.fixture.read_bytes()).hexdigest(),stderr=[e for _,e in results]),indent=2)+'\n')
if __name__=='__main__':
    p=argparse.ArgumentParser()
    for a in ['build','fixture','out']:p.add_argument(a,type=Path)
    p.add_argument('--sim',default=os.environ.get('SIMULATOR_UDID','5B57DE6C-7FDE-4319-863A-F74D3FC4476B'))
    p.add_argument('--workers',type=int,default=3);p.add_argument('--require-model',action='store_true')
    run(p.parse_args())
