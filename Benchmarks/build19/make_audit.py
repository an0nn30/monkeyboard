"""Final disjoint audit from remaining reserved messages, including short public utterances."""
import bz2,csv,re,sys
from pathlib import Path
from make_cases import here,root,read,sha,key,pairs

def audit(source):
    used=set()
    for n in (15,16):
        for r in read(here.parent/f'build{n}/cases.tsv'):
            used.add(key(' '.join([r['left'],r['gold'].split('|')[0],r['right']])))
    for file in ['build17/sentences','build17/confirmation','build18/sentences','build18/challenge',
                 'build19/sentences','build19/confirmation']:
        for r in read(here.parent/(file+'.tsv')): used.update([key(r['expected']),key(r['typed'])])
    controls = [
        'Her papermaking workshop starts at noon.', 'We saw the shoemaker on the way home.',
        'Put the headphones next to the paperweight.', 'I found my notebook under the newspaper.',
        'The bookbinder fixed the spine for me.', 'She does woodworking on the weekends.',
        'A caregiver will meet the housekeeper downstairs.', 'The copywriter changed the headline.',
        'Our neighborhood has a glassmaking studio.', 'The shopkeeper found a bookmark behind the counter.',
        'I left the snowshoes in the mudroom.', 'Her screenwriting class starts tomorrow.',
        'Pick up the cheesecake on your way downtown.', 'I finally made it to the lighthouse.',
        'The code is papertrail for the afternoon group.', 'The account name is PaperTrail on that site.',
    ]
    used.update(map(key,controls))
    pools={'paired':{},'public':{}}
    user=set()
    for src,ref in pairs(source):
        k=key(ref);user.update((k,key(src)))
        if k not in used and sha(k)[0]<38:pools['paired'][k]=ref
    with bz2.open(root/'keyboard-engine/training/eng_sentences_CC0.tsv.bz2','rt') as f:
        for line in f:
            _,lang,ref,_=line.rstrip('\n').split('\t',3);k=key(ref)
            if lang=='eng' and k not in used and k not in user and sha(k)[0]<26:pools['public'][k]=ref
    for group,pool in pools.items():
        n=0
        for k in sorted(pool,key=lambda k:sha('final audit/'+k)):
            ref=pool[k]
            if not 3<=len(k.split())<=32 or not ref.isprintable() or len(ref)>220:continue
            matches=list(re.finditer(r"(?<![A-Za-z'’])([A-Za-z]+)( )(?=[A-Za-z]+\b)",ref))
            if not matches:continue
            gap=matches[int.from_bytes(sha('audit gap/'+k)[:2],'big')%len(matches)].start(2)
            noisy=n%3!=2; typed=ref[:gap]+ref[gap+1:] if noisy else ref
            if key(typed) in used:continue
            yield [group+str(n),group,'noisy' if noisy else 'clean',typed,ref,gap if noisy else '']
            used.update((key(typed),k));n+=1
            if n==300:break
        assert n>=90,(group,n)
    for i,ref in enumerate(controls):yield [f'lit{i}','authored','clean',ref,ref,'']
if __name__=='__main__':
    with (here/'audit.tsv').open('w') as f:
        w=csv.writer(f,delimiter='\t',lineterminator='\n');w.writerow(['id','split','kind','typed','expected','gap']);w.writerows(audit(Path(sys.argv[1])))
