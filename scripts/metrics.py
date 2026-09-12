import json, os, sys, time
from pathlib import Path
from http.server import BaseHTTPRequestHandler, HTTPServer

def render(state):
    lines=[]
    for key,value in state.items():
        if isinstance(value,(int,float)):
            kind='counter' if key.endswith('_total') else 'gauge'
            lines.extend([f'# TYPE {key} {kind}',f'{key} {value}'])
    return ('\n'.join(lines)+'\n').encode()

def update(directory, result, duration):
    directory.mkdir(parents=True,exist_ok=True)
    path=directory/'state.json'
    state=json.loads(path.read_text()) if path.exists() else {}
    state['devsecops_builds_total']=state.get('devsecops_builds_total',0)+1
    success=int(result=='SUCCESS')
    state['devsecops_build_successes_total']=state.get('devsecops_build_successes_total',0)+success
    state['devsecops_last_build_success']=success
    state['devsecops_last_build_duration_seconds']=float(duration)
    state['devsecops_last_build_timestamp_seconds']=time.time()
    if Path('reports/promoted').exists():
        state['devsecops_deployments_total']=state.get('devsecops_deployments_total',0)+1
    scan=Path('reports/trivy.json')
    if scan.exists():
        data=json.loads(scan.read_text())
        # A completed scanner marker prevents failed/truncated scans from looking clean.
        if Path('reports/trivy-complete').exists():
            for severity in ('HIGH','CRITICAL'):
                state['devsecops_image_'+severity.lower()+'_findings']=sum(
                    v.get('Severity')==severity for r in data.get('Results',[]) for v in (r.get('Vulnerabilities') or []))
            state['devsecops_last_image_scan_timestamp_seconds']=time.time()
    temp=directory/'state.json.tmp'
    temp.write_text(json.dumps(state));os.replace(temp,path)

if __name__=='__main__':
    directory=Path(sys.argv[2])
    if sys.argv[1]=='update': update(directory,sys.argv[3],sys.argv[4])
    elif sys.argv[1]=='serve':
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path!='/metrics': self.send_error(404);return
                path=directory/'state.json'
                try: body=render(json.loads(path.read_text()) if path.exists() else {})
                except (ValueError,OSError): self.send_error(503);return
                self.send_response(200)
                self.send_header('Content-Type','text/plain; version=0.0.4')
                self.end_headers();self.wfile.write(body)
        HTTPServer(('0.0.0.0',9101),Handler).serve_forever()
    else: raise SystemExit('Expected serve or update')
