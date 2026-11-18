#!/usr/bin/env python3
"""Generate the dependency inventory and bundled notices from the locked local dependencies."""
import argparse, hashlib, json, os, re, subprocess
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(); parser.add_argument('--check', action='store_true'); args = parser.parse_args()
cache = Path(os.environ.get('CONCH_BUILD_CACHE', ROOT / '.build-cache'))
cargo = Path.home() / '.cargo/bin/cargo'
meta = json.loads(subprocess.check_output([str(cargo), 'metadata', '--locked', '--offline', '--format-version', '1', '--filter-platform', 'aarch64-apple-darwin'], cwd=ROOT/'core'))
nodes = {n['id']: n for n in meta['resolve']['nodes']}
packages = {p['id']: p for p in meta['packages']}
root = next(p['id'] for p in packages.values() if p['name'] == 'conch_core')
queue = [root]; used = set()
while queue:
    key = queue.pop()
    if key in used: continue
    used.add(key); queue.extend(d['pkg'] for d in nodes[key]['deps'])
records = []; texts = {}; missing = []
def notice(text):
    text = text.strip() + '\n'
    key = hashlib.sha256(text.encode()).hexdigest()[:16]
    texts[key] = text
    return key
for key in sorted(used, key=lambda k:(packages[k]['name'], packages[k]['version'])):
    p=packages[key]
    if not p.get('source'): continue
    folder=Path(p['manifest_path']).parent
    files=[f for f in folder.iterdir() if f.is_file() and f.name.upper().startswith(('LICENSE','COPYING','NOTICE','UNLICENSE'))]
    if p.get('license_file') and (folder/p['license_file']).is_file(): files.append(folder/p['license_file'])
    ids=[notice(f.read_text(errors='replace')) for f in sorted(set(files))]
    selected=p.get('license') or 'SEE SOURCE'
    if not ids:
        fallback='MPL-2.0.txt' if selected=='MPL-2.0' else 'Apache-2.0.txt' if 'Apache-2.0' in selected else None
        if not fallback: missing.append(p['name']); continue
        ids.append(notice((ROOT/'docs/licenses'/fallback).read_text()))
        selected='MPL-2.0' if fallback.startswith('MPL') else 'Apache-2.0'
        copyrights=set()
        for f in (folder/'src').rglob('*.rs'):
            for line in f.read_text(errors='replace').splitlines():
                if re.search(r'copyright\s',line,re.I) and len(line)<300: copyrights.add(line.strip(' /*'))
        if copyrights: ids.append(notice('\n'.join(sorted(copyrights))))
    records.append({'name':p['name'],'version':p['version'],'declared_license':p.get('license'),'notice_license':selected,
                    'source':f"https://crates.io/api/v1/crates/{p['name']}/{p['version']}/download",'notices':sorted(set(ids))})
resolved=json.loads((ROOT/'app/Package.resolved').read_text())
for p in resolved['pins']:
    folder=cache/'swiftpm/checkouts'/p['identity']
    files=[f for f in folder.glob('*') if f.is_file() and f.name.upper().startswith(('LICENSE','COPYING','NOTICE'))]
    if not files: missing.append(p['identity']);continue
    records.append({'name':p['identity'],'version':p['state'].get('version',p['state']['revision']),
                    'revision':p['state']['revision'],'source':p['location']+'/tree/'+p['state']['revision'],
                    'notices':[notice(f.read_text(errors='replace')) for f in sorted(files)]})
if missing: raise SystemExit('Missing license material: '+', '.join(missing))
header='Conch third-party notices\nGenerated from Cargo.lock and Package.resolved. Includes runtime and build-time dependencies for Apple silicon macOS.\n\n'
body=header+'DEPENDENCY INVENTORY\n'+json.dumps(records,ensure_ascii=False,indent=2)+'\n\nLICENSE AND COPYRIGHT TEXTS\n'
for key,text in sorted(texts.items()): body+='\n'+'='*72+'\nNOTICE '+key+'\n'+'='*72+'\n'+text
out=ROOT/'docs/THIRD_PARTY_NOTICES.txt'
if args.check:
    if not out.exists() or out.read_text()!=body: raise SystemExit('Notices are out of date; run scripts/third-party-notices.py')
else: out.write_text(body)
print(f'{len(records)} dependencies, {len(texts)} notice texts; '+('verified' if args.check else 'generated'))
