#!/usr/bin/env python3
from __future__ import annotations
import argparse,hashlib,json,os,re,shutil,struct,subprocess,sys,tempfile
from pathlib import Path
FASTDL_ROOT=Path('/srv/hyper-cs16/fastdl'); SERVER_ROOT=Path('/srv/hyper-cs16/servers'); STATE_ROOT=Path('/var/lib/hyper-cs16/servers')
DOMAIN='old-zombie.ru'; DIRS=('maps','models','sound','sprites','gfx','resource','overviews','events','media'); CORE=Path('/usr/local/libexec/hyper-cs16-ctl-core-v8')
def run(c,check=True,timeout=None):
 p=subprocess.run(c,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,check=False,timeout=timeout)
 if check and p.returncode: raise RuntimeError((p.stdout or '').strip() or str(c))
 return p
def out(x,code=0): print(json.dumps(x,ensure_ascii=False,separators=(',',':'))); raise SystemExit(code)
def state(sid):
 p=STATE_ROOT/f'{sid}.json'
 try:return json.loads(p.read_text(encoding='utf-8'))
 except:return {'id':sid,'path':str(SERVER_ROOT/str(sid))}
def root(sid): return Path(state(sid).get('path') or SERVER_ROOT/str(sid))
def url(sid): return f'http://{DOMAIN}/fastdl/{sid}'
def bver(p):
 try:
  b=p.read_bytes()[:4]; return (struct.unpack('<I',b)[0] if len(b)==4 else None,b.hex())
 except:return (None,'')
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
 return h.hexdigest()
def cfg_fix(sid):
 p=root(sid)/'cstrike/server.cfg'; p.parent.mkdir(parents=True,exist_ok=True); t=p.read_text(encoding='utf-8',errors='ignore') if p.exists() else ''
 lit=t.count('\\n'); real=t.count('\n'); fixed=False
 if lit>=5 and real<=2: t=t.replace('\\r\\n','\n').replace('\\n','\n').replace('\\r','\n'); fixed=True
 t=t.replace('\r\n','\n').replace('\r','\n')
 t=re.sub(r'(?ims)^\s*// HYPER-HOST FASTDL BEGIN\s*$.*?^\s*// HYPER-HOST FASTDL END\s*$\n?','',t)
 managed={'sv_downloadurl','sv_allowdownload','sv_allowupload','sv_send_resources','sv_allow_dlfile'}; keep=[]
 for ln in t.splitlines():
  m=re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s+',ln)
  if m and m.group(1).lower() in managed: continue
  keep.append(ln)
 u=url(sid); block=['// HYPER-HOST FASTDL BEGIN','// Managed by HYPER-HOST FastDL v8.','sv_allowdownload 1','sv_allowupload 0','sv_send_resources 1','sv_allow_dlfile 1',f'sv_downloadurl "{u}"','// HYPER-HOST FASTDL END']
 c='\n'.join(keep).rstrip()+'\n\n'+'\n'.join(block)+'\n'; p.write_text(c,encoding='utf-8')
 helper='// Managed by HYPER-HOST FastDL v8\n'+'\n'.join(block[2:-1])+'\n'
 for n in ('fastdl.cfg','server_download_fix.cfg','SAFE_DOWNLOAD_MODE.cfg','ENABLE_FASTDL_AFTER_VERIFY.cfg'):
  try:(root(sid)/'cstrike'/n).write_text(helper,encoding='utf-8')
  except:pass
 return {'escaped_fixed':fixed,'literal_before':lit,'real_before':real,'real_after':c.count('\n'),'url':u}
def blocks(t):
 r=[]; rx=re.compile(r'\bserver\s*\{',re.I); i=0
 while 1:
  m=rx.search(t,i)
  if not m: break
  b=t.find('{',m.start()); d=0; q=None; esc=False; j=b
  while j<len(t):
   ch=t[j]
   if q:
    if esc: esc=False
    elif ch=='\\': esc=True
    elif ch==q:q=None
   else:
    if ch in ('"',"'"): q=ch
    elif ch=='{': d+=1
    elif ch=='}':
     d-=1
     if d==0: r.append((m.start(),j+1,t[m.start():j+1])); i=j+1; break
   j+=1
  else: break
 return r
def http_oldz(b):
 return bool(re.search(r'(?im)^\s*server_name\s+[^;]*\bold-zombie\.ru\b',b) and re.search(r'(?im)^\s*listen\s+(?:\[[^\]]+\]:)?80\b',b) and not re.search(r'(?im)^\s*listen\s+[^;]*\b443\b',b))
CAN='''server {\n    listen 80;\n    listen [::]:80;\n    server_name old-zombie.ru www.old-zombie.ru;\n    access_log /var/log/nginx/old-zombie-fastdl-access.log;\n    error_log /var/log/nginx/old-zombie-fastdl-error.log warn;\n    location ^~ /fastdl/ {\n        alias /srv/hyper-cs16/fastdl/;\n        autoindex off;\n        sendfile on;\n        default_type application/octet-stream;\n        add_header X-Hyper-FastDL "raw-v8" always;\n        add_header Cache-Control "public, max-age=86400" always;\n    }\n    location / { return 301 https://$host$request_uri; }\n}\n'''
def nginx_fix():
 canon=Path('/etc/nginx/conf.d/00-old-zombie-fastdl-http.conf'); touched=[]; seen=set()
 for pat in ('/etc/nginx/conf.d/*.conf','/etc/nginx/sites-enabled/*','/etc/nginx/hyper-host-managed/*.conf'):
  for p in sorted(Path('/').glob(pat.lstrip('/'))):
   try: rp=p.resolve()
   except: rp=p
   if rp in seen or p==canon or not p.is_file(): continue
   seen.add(rp)
   try:t=p.read_text(encoding='utf-8',errors='ignore')
   except:continue
   bs=[x for x in blocks(t) if http_oldz(x[2])]
   if not bs: continue
   n=t
   for a,b,_ in reversed(bs): n=n[:a]+n[b:]
   if n!=t:
    bak=p.with_name(p.name+'.fastdl-v8.bak')
    if not bak.exists(): shutil.copy2(p,bak)
    p.write_text(n,encoding='utf-8'); touched.append(str(p))
 canon.write_text(CAN,encoding='utf-8'); q=run(['nginx','-t'],False,30)
 if q.returncode: raise RuntimeError('nginx -t failed: '+(q.stdout or '')[-4000:])
 q=run(['systemctl','reload','nginx'],False,30)
 if q.returncode: raise RuntimeError('nginx reload failed: '+(q.stdout or '')[-3000:])
 return {'canonical':str(canon),'stripped':touched}
def srcmaps(sid):
 good=[]; bad=[]
 for p in sorted((root(sid)/'cstrike/maps').glob('*.bsp')):
  v,h=bver(p)
  (good if v==30 else bad).append(p.name if v==30 else {'map':p.name,'version':v,'head':h})
 return good,bad
def rs(src,dst):
 if not src.is_dir():
  if dst.exists(): shutil.rmtree(dst,ignore_errors=True)
  return
 dst.mkdir(parents=True,exist_ok=True); q=run(['rsync','-a','--delete','--safe-links',str(src)+'/',str(dst)+'/'],False,1200)
 if q.returncode: raise RuntimeError('rsync failed: '+(q.stdout or '')[-2500:])
def probe(sid,rel):
 tmp=Path(tempfile.mktemp()); hdr=Path(tempfile.mktemp())
 try:
  q=run(['curl','-sS','--connect-timeout','2','--max-time','8','-H','Host: old-zombie.ru','-H','Range: bytes=0-3','-D',str(hdr),'-o',str(tmp),'-w','%{http_code}',f'http://127.0.0.1/fastdl/{sid}/{rel}'],False,10)
  b=tmp.read_bytes() if tmp.exists() else b''; h=hdr.read_text(errors='ignore') if hdr.exists() else ''; code=int((q.stdout or '0')[-3:]) if (q.stdout or '').strip() else 0
  ver=struct.unpack('<I',b[:4])[0] if len(b)>=4 else None; marker='raw-v8' if re.search(r'(?im)^X-Hyper-FastDL:\s*raw-v8\s*$',h) else ''
  ct=(re.search(r'(?im)^Content-Type:\s*([^\r\n]+)',h) or [None,''])[1] if re.search(r'(?im)^Content-Type:\s*([^\r\n]+)',h) else ''
  return {'ok':code in (200,206) and ver==30 and marker=='raw-v8','http':code,'version':ver,'head':b[:8].hex(),'content_type':ct,'marker':marker}
 finally:
  tmp.unlink(missing_ok=True); hdr.unlink(missing_ok=True)
def verify(sid,dst):
 fails=[]; n=0
 for s in sorted((root(sid)/'cstrike/maps').glob('*.bsp')):
  d=dst/'maps'/s.name
  if not d.is_file(): fails.append({'map':s.name,'error':'missing'}); continue
  if bver(d)[0]!=30 or s.stat().st_size!=d.stat().st_size or sha(s)!=sha(d): fails.append({'map':s.name,'error':'mirror mismatch','head':bver(d)[1]}); continue
  p=probe(sid,'maps/'+s.name)
  if not p['ok']: fails.append({'map':s.name,**p}); continue
  n+=1
 if fails: raise RuntimeError('FastDL HTTP is not serving raw BSP bytes: '+json.dumps(fails[:50],ensure_ascii=False))
 return n
def rcon(sid,u):
 if not CORE.is_file(): return
 for c in ('sv_allowdownload 1','sv_allowupload 0','sv_send_resources 1','sv_allow_dlfile 1',f'sv_downloadurl "{u}"'):
  run([str(CORE),'rcon',str(sid),c],False,8)
def sync(sid,clean=False):
 good,bad=srcmaps(sid)
 if bad: raise RuntimeError('Bad source BSP: '+json.dumps(bad,ensure_ascii=False))
 ng=nginx_fix(); cf=cfg_fix(sid); cr=root(sid)/'cstrike'; dst=FASTDL_ROOT/str(sid); FASTDL_ROOT.mkdir(parents=True,exist_ok=True)
 if clean and dst.exists(): shutil.rmtree(dst)
 dst.mkdir(parents=True,exist_ok=True)
 for n in DIRS: rs(cr/n,dst/n)
 w={p.name:p for p in cr.glob('*.wad') if p.is_file()}
 for p in dst.glob('*.wad'):
  if p.name not in w:p.unlink(missing_ok=True)
 for n,p in w.items(): shutil.copy2(p,dst/n)
 for p in list(dst.rglob('*.ztmp')): p.unlink(missing_ok=True)
 run(['chown','-R','root:www-data',str(dst)],False); run(['find',str(dst),'-type','d','-exec','chmod','0755','{}','+'],False); run(['find',str(dst),'-type','f','-exec','chmod','0644','{}','+'],False)
 vn=verify(sid,dst); rcon(sid,url(sid)); files=sum(1 for p in dst.rglob('*') if p.is_file()); size=sum(p.stat().st_size for p in dst.rglob('*') if p.is_file())
 return {'ok':True,'id':sid,'configured':True,'url':url(sid),'root':str(dst),'files':files,'bytes':size,'maps':len(good),'verified_maps':vn,'clean_rebuild':clean,'cfg':cf,'nginx':ng}
def status(sid):
 good,bad=srcmaps(sid); dst=FASTDL_ROOT/str(sid); p=probe(sid,'maps/'+('zm_303.bsp' if 'zm_303.bsp' in good else good[0])) if good else {'ok':False}; cur=''; cfg=root(sid)/'cstrike/server.cfg'
 if cfg.is_file():
  x=re.findall(r'(?im)^\s*sv_downloadurl\s+"?([^"\r\n]+)',cfg.read_text(encoding='utf-8',errors='ignore')); cur=x[-1].strip().rstrip('/') if x else ''
 files=sum(1 for x in dst.rglob('*') if x.is_file()) if dst.is_dir() else 0; size=sum(x.stat().st_size for x in dst.rglob('*') if x.is_file()) if dst.is_dir() else 0
 return {'ok':True,'id':sid,'configured':bool(dst.is_dir() and not bad and p.get('ok') and cur==url(sid)),'url':url(sid),'configured_url':cur,'root':str(dst),'exists':dst.is_dir(),'files':files,'bytes':size,'maps':len(good),'http_ok':bool(p.get('ok')),'http':p}
def main():
 a=argparse.ArgumentParser(); sp=a.add_subparsers(dest='cmd',required=True)
 for c in ('sync','status','rebuild','clean'): q=sp.add_parser(c); q.add_argument('id',type=int)
 x=a.parse_args()
 try: out(sync(x.id,x.cmd in ('rebuild','clean')) if x.cmd!='status' else status(x.id))
 except Exception as e: out({'ok':False,'error':str(e)},1)
if __name__=='__main__': main()
