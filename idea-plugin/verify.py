#!/usr/bin/env python3
"""Exercise the installed bridge without printing credentials. Optional navigation is explicit."""
import argparse, json, pathlib, time, urllib.request, urllib.error
p=argparse.ArgumentParser()
p.add_argument('--project', required=True)
p.add_argument('--navigate', action='store_true')
p.add_argument('--require-focus', action='store_true', help='Also verify the target project frame becomes active and focused; requires --navigate')
p.add_argument('--bare-method', help='Check and optionally navigate an unqualified project method')
args=p.parse_args()
if args.require_focus and not args.navigate:
    p.error('--require-focus requires --navigate')
entries=list((pathlib.Path.home()/'Library/Application Support/CodeJump/idea').glob('*.json'))
assert entries, 'Start CodeJump Bridge in IDEA first'
e=json.loads(max(entries,key=lambda p:p.stat().st_mtime).read_text())
def call(path,body=None,auth=True,origin=False):
    headers={'Content-Type':'application/json'}
    if auth: headers['Authorization']='Bearer '+e['token']
    if origin: headers['Origin']='http://localhost'
    r=urllib.request.Request(f'http://127.0.0.1:{e["port"]}/{path}',data=json.dumps(body or {}).encode(),headers=headers)
    try:
        with urllib.request.urlopen(r,timeout=4) as response: return response.status,json.load(response)
    except urllib.error.HTTPError as error: return error.code,json.load(error)
assert call('projects',auth=False)[0]==401
assert call('projects',origin=True)[0]==401
assert call('navigate',{'target':'nonexistent'})[0]==409
assert call('resolve',{'project':args.project+'-missing','symbol':'java.lang.String.substring'})==(200,[])
status,overloads=call('resolve',{'project':args.project,'symbol':'java.lang.String.substring'})
assert status==200 and len(overloads)==2, overloads
status,exact=call('resolve',{'project':args.project,'symbol':'java.lang.String.substring','signature':'int, int'})
assert status==200 and len(exact)==1 and exact[0]['signature']=='substring(int, int)'
status,inherited=call('resolve',{'project':args.project,'symbol':'java.util.ArrayList.stream'})
assert status==200 and any(r['symbol']=='java.util.Collection#stream' for r in inherited)
status,batch=call('resolve',{'requests':[{'project':args.project,'symbol':'java.lang.String.substring','signature':'int'}]})
assert status==200 and len(batch)==1
result={'authentication':'passed','browserOrigin':'rejected','expiredTarget':'rejected','projectBoundary':'passed',
        'overloads':len(overloads),'signature':'substring(int, int)','inherited':'java.util.Collection#stream','batch':'passed'}
if args.bare_method:
    status,bare=call('resolve',{'project':args.project,'symbol':args.bare_method})
    assert status==200 and bare, bare
    assert all(r['symbol'].endswith('#'+args.bare_method) for r in bare)
    result['bareMethod']=[{k:r[k] for k in ['symbol','path','line']} for r in bare]
    if args.navigate:
        exact=[bare[0]]
if args.navigate:
    assert call('navigate',{'target':exact[0]['target']})[0]==200
    expected_path=pathlib.Path(exact[0]['path']).as_uri() if exact[0]['path'].startswith('/') else exact[0]['path']
    deadline=time.monotonic()+2
    while True:
        status,selected=call('selection')
        assert status==200, 'Cannot read current editor selection'
        match=next((r for r in selected if r['project']==args.project and r['line']==exact[0]['line'] and r['path']==expected_path),None)
        if match and (not args.require_focus or (match.get('frameActive') and match.get('frameFocused'))):
            break
        assert time.monotonic()<deadline, 'Target editor was not selected in its active, focused project frame' if args.require_focus else 'Target editor selection did not match'
        time.sleep(0.1)
    result['navigation']={'verified':True,'line':exact[0]['line']}
    if args.require_focus:
        result['navigation']['targetFrameActiveAndFocused']=True
print(json.dumps(result,ensure_ascii=False,indent=2))
