#!/usr/bin/env python3
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); t=p.read_text(encoding='utf-8')
if '# HYPER_FASTDL_V8_OVERRIDE' not in t:
 m=re.search(r'(?m)^def main\(\):\s*$',t)
 if not m: raise SystemExit('[PATCH ERROR] def main() not found')
 o=Path(sys.argv[2]).read_text(encoding='utf-8')
 t=t[:m.start()]+o.rstrip()+'\n\n'+t[m.start():]
 p.write_text(t,encoding='utf-8')
