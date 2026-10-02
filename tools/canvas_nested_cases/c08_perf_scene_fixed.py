import sys,json,os
sys.path.insert(0,'/Users/nicolasvair/Documents/Xcode/Objekat/objekat/tools')
import scenario_canvas_nested as s
from objekat_cli import ObjekatClient, ObjekatError
c=ObjekatClient('/tmp/cc501/p.sock',timeout=600); c.connect()
c.send("app.set_dialog_policy",{"policy":"assume_no"})
out="/tmp/cc501/perf"; n=480
wav=s.write_wav(out+"/perf.wav",300.0,220,7)
c.send("project.new"); c.send("project.set_snap",{"enabled":False})
clip=c.send("object.add",{"path":wav,"lane":0,"start":0})
r=c.send("object.explode",{"id":clip["id"],"cuts":[round(i*0.5,6) for i in range(1,n)],"lanes":[i%12 for i in range(n)],"group_lanes":True})
print({k:(v if not isinstance(v,list) else len(v)) for k,v in r.items()})
tree=s.tree_index(c.send("project.get_state")["items"])
print(len(tree), max(v['depth'] for v in tree.values()))
subs=r["lane_groups"]
outer=[k for k,v in tree.items() if v['depth']==0 and v['parent'] is None]
print("roots",len(outer))
# make every path expanded first
for k,v in tree.items():
    if v['depth']==0: 
        try: c.send("group.expand",{"id":k,"expanded":True})
        except ObjekatError as e: print("exp",e)
try:
    pairs=[c.send("group.create",{"ids":subs[i:i+2]})["id"] for i in range(0,len(subs),2)]
    tops=[c.send("group.create",{"ids":pairs[i:i+3]})["id"] for i in range(0,len(pairs),3)]
except ObjekatError as e: print("ERR",e)
tree=s.tree_index(c.send("project.get_state")["items"])
print(len(tree), max(v['depth'] for v in tree.values()))
for e in list(tree):
    try: c.send("group.expand",{"id":e,"expanded":True})
    except ObjekatError: pass
c.send("selection.clear")
path=out+"/perf_nested_480.objekat"
c.send("project.save_as",{"path":path}); s.settle(c,1500)
ce=c.send("perf.census"); print(path,ce.get("objects_total"),ce.get("max_group_depth"))
