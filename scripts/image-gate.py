import json
from pathlib import Path
r=json.loads(Path('reports/trivy.json').read_text())
if not isinstance(r.get('Results'),list): raise SystemExit('Invalid Trivy report; blocked')
findings=[v for result in r['Results'] for v in (result.get('Vulnerabilities') or []) if v.get('Severity') in ('HIGH','CRITICAL')]
print('Blocking image vulnerabilities:',len(findings))
if findings: raise SystemExit(1)
