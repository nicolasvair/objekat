import sys,json,os
sys.path.insert(0,'/Users/nicolasvair/Documents/Xcode/Objekat/objekat/tools')
import scenario_canvas_nested as s
from objekat_cli import ObjekatClient
c=ObjekatClient('/tmp/cc501/t.sock',timeout=600); c.connect()
os.makedirs('/tmp/cc501/parity/snap',exist_ok=True)
c.send("project.open",{"path":"/tmp/cc501/parity/parity.objekat"}); s.settle(c,1500)
res={}
for pps in (100,20):
  for k in range(5):
    c.send("selection.clear")
    c.send("view.set",{"pps":pps,"block_height":40,"scroll_x":0,"scroll_y":k*800}); s.settle(c,800)
    n="pp%d_%d"%(pps,k)
    a="/tmp/cc501/parity/snap/%s_c.png"%n; b="/tmp/cc501/parity/snap/%s_r.png"%n
    s.snapshot(c,a); c.send("debug.force_rich_blocks",{"enabled":True}); s.settle(c,800); s.snapshot(c,b); c.send("debug.force_rich_blocks",{"enabled":False})
    d=s.diff_png(a,b,"/tmp/cc501/parity/snap/%s_d.png"%n); res[n]=d; print(n,d)
