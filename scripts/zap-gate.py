import json, sys
from pathlib import Path
report=json.loads(Path(sys.argv[1]).read_text())
sites=report.get('site')
if not isinstance(sites,list) or not sites:
    raise SystemExit('ZAP report has no scanned sites; gate blocked')
counts={'HIGH':0,'MEDIUM':0,'LOW':0,'INFO':0}
for site in sites:
    if not isinstance(site.get('alerts'),list): raise SystemExit('Invalid ZAP alert schema')
    for alert in site['alerts']:
        risk=int(alert['riskcode'])
        severity={0:'INFO',1:'LOW',2:'MEDIUM',3:'HIGH'}[risk]
        counts[severity]+=1
Path('reports/zap-summary.json').write_text(json.dumps(counts))
print('ZAP alert types by severity:',counts)
if counts['HIGH'] or counts['MEDIUM']: raise SystemExit(1)
