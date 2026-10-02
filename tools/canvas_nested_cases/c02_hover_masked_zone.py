import sys,json
sys.path.insert(0,'/Users/nicolasvair/Documents/Xcode/Objekat/objekat/tools')
import scenario_canvas_nested as s
from objekat_cli import ObjekatClient, ObjekatError
c=ObjekatClient('/tmp/cc501/t.sock',timeout=300); c.connect()
sc=json.load(open('/tmp/cc501/nested/scene.json')); I=sc['ids']; inv={v:k for k,v in I.items()}
s.open_scene(c,sc)
g=s.geometry(c); print(g)
x,y,w,h=s.block_rect(c,I['B1'],g)
print("B1 rect",x,y,w,h)
def hov(t,yy,label):
    xx=t*g['pps']-g['sx']
    c.send("input.hover",{"x":xx,"y":yy})
    hv=c.send("view.state.hover"); print(label,"t=",t,{k:(inv.get(v,v) if isinstance(v,str) else v) for k,v in hv.items() if k in('hovered_id','zone','hover_zone')}, hv if 'hovered_id' not in hv else '')
for t in (2,4.5,6,6.9): hov(t,y+h*0.5,"B1 row")
# overlap point: A1/A2 crossfade at t=3.7 on A row, with A2 selected
xa,ya,wa,ha=s.block_rect(c,I['A1'],g)
c.send("selection.set",{"ids":[I['A1']]})
hov(3.75,ya+ha*0.6,"A1 sel, overlap")
c.send("selection.set",{"ids":[I['A2']]})
hov(3.75,ya+ha*0.6,"A2 sel, overlap")
c.send("selection.clear")
print("---full")
for t,l in ((3.75,"xf"),(1.5,"A1 plain"),(5,"A2 plain")):
    c.send("input.hover",{"x":t*50,"y":ya+ha*0.6}); print(l,c.send("view.state.hover"))
