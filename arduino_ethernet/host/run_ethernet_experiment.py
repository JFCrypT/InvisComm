#!/usr/bin/env python3
from __future__ import annotations
import argparse, csv, queue, threading, time
from pathlib import Path
import serial

class Reader(threading.Thread):
    def __init__(self, port: str, node: str, q: queue.Queue, stop: threading.Event):
        super().__init__(daemon=True); self.port=port; self.node=node; self.q=q; self.stop=stop; self.dev=None; self.error=None
    def run(self):
        try:
            with serial.Serial(self.port,115200,timeout=0.2,write_timeout=2.0) as dev:
                self.dev=dev
                while not self.stop.is_set():
                    raw=dev.readline()
                    if raw: self.q.put((self,time.time(),raw.decode('utf-8',errors='replace').rstrip('\r\n')))
        except Exception as e: self.error=e; self.stop.set()
    def send(self,s: str):
        if not self.dev: raise RuntimeError(f'{self.port} no está listo')
        self.dev.write((s+'\r\n').encode()); self.dev.flush()

def main() -> int:
    p=argparse.ArgumentParser(); p.add_argument('--port-a',required=True); p.add_argument('--port-b',required=True); p.add_argument('--duration',type=float,default=60); p.add_argument('--output-dir',type=Path,required=True); a=p.parse_args()
    a.output_dir.mkdir(parents=True,exist_ok=True)
    q=queue.Queue(); stop=threading.Event(); readers=[Reader(a.port_a,'Alice',q,stop),Reader(a.port_b,'Bob',q,stop)]
    for r in readers:r.start()
    ready=set(); print('Esperando READY de Alice y Bob...',flush=True); deadline=time.time()+60
    while ready!={'Alice','Bob'} and time.time()<deadline and not stop.is_set():
        try:r,ts,line=q.get(timeout=.5)
        except queue.Empty:continue
        print(f'[{r.node}] {line}',flush=True)
        if line.startswith('READY,'):
            parts=line.split(',');
            if len(parts)>1: ready.add(parts[1]); print('READY:',parts[1],flush=True)
    if ready!={'Alice','Bob'}:
        stop.set(); print('ERROR: READY incompleto:',sorted(ready)); return 1
    sid=time.strftime('%Y%m%d_%H%M%S'); cmd=f'INVISCOMM_START,{sid},3000'
    for r in readers:r.send(cmd)
    print('START enviado:',sid,flush=True)
    start=time.time(); end=start+a.duration+3
    rows=[]; errors=0; tracebacks=0
    rawf=(a.output_dir/'serial_raw.log').open('w',encoding='utf-8',buffering=1)
    while time.time()<end and not stop.is_set():
        try:r,ts,line=q.get(timeout=.2)
        except queue.Empty:continue
        rawf.write(f'{ts:.6f},{r.port},{r.node},{line}\n')
        if ',ERROR,' in line: errors+=1
        if 'Traceback' in line: tracebacks+=1
        if not line.startswith('TEL,'):continue
        f=line.split(',')
        if len(f)!=7:continue
        _,seq,device_ts,direction,coord,typ,node=f
        try: coord_i=int(coord)
        except ValueError:continue
        rows.append({'timestamp':ts-start,'direction':direction,'encrypted_coord':coord_i,'type':typ,'node':node,'sequence':seq,'device_timestamp':device_ts,'host_timestamp':ts,'port':r.port,'transport':'ethernet'})
        if len(rows)%20==0:print('Registros:',len(rows),flush=True)
    rawf.close(); stop.set()
    for r in readers:r.join(timeout=2)
    rows.sort(key=lambda x:x['timestamp'])
    ext_cols=['timestamp','direction','encrypted_coord','type','node','sequence','device_timestamp','host_timestamp','port','transport']
    with (a.output_dir/'telemetria_extendida.csv').open('w',newline='',encoding='utf-8') as f:
        w=csv.DictWriter(f,fieldnames=ext_cols); w.writeheader(); w.writerows(rows)
    with (a.output_dir/'telemetria.csv').open('w',newline='',encoding='utf-8') as f:
        w=csv.DictWriter(f,fieldnames=['timestamp','direction','encrypted_coord','type']); w.writeheader(); w.writerows({k:r[k] for k in w.fieldnames} for r in rows)
    dirs={r['direction'] for r in rows}; infos=sum(r['type']=='Info' for r in rows)
    capture=bool(rows) and dirs=={'A-->B','B-->A'} and infos>0
    session=capture and errors==0 and tracebacks==0
    print('\n========================================'); print('RESUMEN'); print('========================================')
    print('Registros:',len(rows)); print('Direcciones:',sorted(dirs)); print('Tramas Info:',infos); print('Errores runtime:',errors); print('CSV:',a.output_dir/'telemetria.csv')
    print('CAPTURA:','PASS' if capture else 'FAIL'); print('SESIÓN:','PASS' if session else 'FAIL')
    return 0 if capture else 2
if __name__=='__main__': raise SystemExit(main())
