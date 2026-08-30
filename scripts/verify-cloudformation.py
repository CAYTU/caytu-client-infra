"""Check the customer access template before a customer runs it.

Every policy in it is a JSON string inside YAML, so a broken document parses
fine here and fails only when somebody creates the stack. This renders each
branch, parses it, and checks it against the IAM size limits, which is what
would otherwise be found by a customer.

Usage: python3 scripts/verify-cloudformation.py cloudformation/<file>.yaml
"""

import yaml, json, re, sys

class L(yaml.SafeLoader): pass
def keep(tag):
    def f(loader, node):
        if isinstance(node, yaml.ScalarNode):   return {tag: loader.construct_scalar(node)}
        if isinstance(node, yaml.SequenceNode): return {tag: loader.construct_sequence(node)}
        return {tag: loader.construct_mapping(node)}
    return f
for t in ('Ref','Sub','GetAtt','If','Equals','Not','And','Or','Select','Join','Split','ImportValue','FindInMap','Base64','Condition'):
    L.add_constructor('!'+t, keep(t))

d = yaml.load(open(sys.argv[1]), Loader=L)
render = lambda s: re.sub(r'\$\{[^}]+\}', 'X', s)
ok = True

b = d['Resources']['CaytuBoundary']['Properties']['PolicyDocument']['Sub']
tpl, br = b[0], b[1]['ClusterCeiling']['If']
sids = {}
for name, frag in (('cluster', br[1]), ('single', br[2])):
    try:
        parsed = json.loads(render(tpl.replace('${ClusterCeiling}', frag)))
        size = len(json.dumps(parsed, separators=(',',':')))
        sids[name] = [s['Sid'] for s in parsed['Statement']]
        print(f"boundary/{name:8} statements={len(parsed['Statement']):2} compact={size:5} {'OK' if size<=6144 else 'OVER 6144'}")
        ok &= size <= 6144
    except Exception as e:
        print(f"boundary/{name}: INVALID -> {e}"); ok = False

if 'cluster' in sids and 'single' in sids:
    extra = [s for s in sids['cluster'] if s not in sids['single']]
    print(f"  cluster adds: {extra or 'NOTHING — the fragment is not landing'}")
    ok &= bool(extra)

for p_ in d['Resources']['CaytuProvisionerRole']['Properties']['Policies']:
    cluster = 'If' in p_
    doc = p_['If'][1]['PolicyDocument']['Sub'] if cluster else p_['PolicyDocument']['Sub']
    parsed = json.loads(render(doc))
    size = len(json.dumps(parsed, separators=(',',':')))
    lbl = 'cluster-inline' if cluster else 'base-inline'
    print(f"role/{lbl:15} statements={len(parsed['Statement']):2} compact={size:5} {'OK' if size<=10240 else 'OVER 10240'}")
    ok &= size <= 10240

print("\nALL GOOD" if ok else "\nPROBLEMS FOUND")
sys.exit(0 if ok else 1)
