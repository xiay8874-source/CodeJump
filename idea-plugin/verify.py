#!/usr/bin/env python3
"""Exercise the installed bridge without printing credentials. Optional navigation is explicit."""
import argparse, json, pathlib, urllib.request, urllib.error
p=argparse.ArgumentParser()
p.add_argument('--project', required=True)
p.add_argument('--navigate', action='store_true')
args=p.parse_args()
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
if args.navigate:
    assert call('navigate',{'target':exact[0]['target']})[0]==200
    status,selected=call('selection')
    assert status==200 and any(r['project']==args.project and r['line']==exact[0]['line'] and r['path']==exact[0]['path'] for r in selected)
    result['navigation']={'verified':True,'line':exact[0]['line']}
print(json.dumps(result,ensure_ascii=False,indent=2))
