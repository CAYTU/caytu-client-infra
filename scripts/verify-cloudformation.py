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

# Absent in a fixture that is only exercising the size rules.
boundary = d['Resources'].get('CaytuBoundary')
b = boundary['Properties']['PolicyDocument']['Sub'] if boundary else None
tpl, br = (b[0], b[1]['ClusterCeiling']['If']) if b else (None, [None, None, None])
sids = {}
for name, frag in ((('cluster', br[1]), ('single', br[2])) if b else ()):
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

# A document is either JSON in a !Sub string or plain YAML. Both end up as the
# same JSON in IAM, which is what the limits are measured against.
def measure(doc):
    if isinstance(doc, dict) and 'Sub' in doc:
        doc = doc['Sub']
    parsed = json.loads(render(doc)) if isinstance(doc, str) else doc
    return parsed, len(json.dumps(parsed, separators=(',',':')))

# A managed policy stops at 6,144 on its own.
for name, r in d['Resources'].items():
    if r['Type'] != 'AWS::IAM::ManagedPolicy' or name == 'CaytuBoundary':
        continue
    parsed, size = measure(r['Properties']['PolicyDocument'])
    print(f"{name:30} statements={len(parsed['Statement']):2} compact={size:5} "
          f"{'OK, ' + str(6144-size) + ' spare' if size<=6144 else 'OVER 6144'}")
    ok &= size <= 6144

# Inline policies share one 10,240 budget across the whole role. Measuring them
# one at a time is what let two 5k policies pass here and fail on the customer's
# stack update with ServiceLimitExceeded.
for name, r in d['Resources'].items():
    if r['Type'] != 'AWS::IAM::Role':
        continue
    total = 0
    for p_ in r['Properties'].get('Policies', []):
        doc = p_['If'][1]['PolicyDocument'] if 'If' in p_ else p_['PolicyDocument']
        total += measure(doc)[1]
    if total:
        print(f"{name:30} inline total={total:5} "
              f"{'OK, ' + str(10240-total) + ' spare' if total<=10240 else 'OVER 10240'}")
        ok &= total <= 10240

print("\nALL GOOD" if ok else "\nPROBLEMS FOUND")
sys.exit(0 if ok else 1)
