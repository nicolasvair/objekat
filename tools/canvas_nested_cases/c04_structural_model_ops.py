import sys,json
sys.path.insert(0,'/Users/nicolasvair/Documents/Xcode/Objekat/objekat/tools')
import scenario_canvas_nested as s
from objekat_cli import ObjekatClient, ObjekatError
c=ObjekatClient('/tmp/cc501/t.sock',timeout=300); c.connect()
c.send("app.set_dialog_policy",{"policy":"assume_no"})
sc=json.load(open('/tmp/cc501/nested/scene.json')); I=sc['ids']
inv={v:k for k,v in I.items()}
def tree():
    return s.tree_index(c.send("project.get_state")["items"])
def absstart(t,i):
    a=0
    while i: a+=t[i]['start'] or 0; i=t[i]['parent']
    return a
def run(name,fn,fresh=True):
    if fresh: s.open_scene(c,sc)
    before=s.items_state(c); tb=tree()
    try: fn()
    except ObjekatError as e: print(name,"ERROR",e); return
    s.settle(c,500)
    ta=tree()
    ch={inv.get(k,k[:6]):(dict(parent=inv.get(tb[k]['parent']),start=tb[k]['start'],dur=tb[k]['duration']),dict(parent=inv.get(ta[k]['parent']) if k in ta else None,start=ta[k]['start'],dur=ta[k]['duration'],abs=round(absstart(ta,k),3))) for k in tb if k in ta and tb[k]!=ta[k]}
    lost=[inv.get(k,k) for k in tb if k not in ta]
    sn=c.send("view.snapshot",{"path":"/tmp/cc501/nested/struct_%s.png"%name.split()[0],"method":"cache"})
    try: c.send("edit.undo")
    except ObjekatError as e: print("   undo:",e)
    s.settle(c,500)
    ok=s.items_state(c)==before
    print("==",name,"| count",len(tb),"->",len(ta),"lost",lost,"| undo1 exact:",ok)
    for k,v in ch.items(): print("   ",k,v[0],"->",v[1])
    if not ok:
        c.send("edit.undo"); s.settle(c,500); print("    2nd undo exact:",s.items_state(c)==before)
run("D2d G2 into its own subtree G3 (cycle)",lambda:c.send("group.reparent",{"ids":[I['G2']],"group":I['G3']}))
run("D2e G1 into itself",lambda:c.send("group.reparent",{"ids":[I['G1']],"group":I['G1']}))
def mv(i,dt):
    o=c.send("object.get",{"id":I[i]}); c.send("object.move",{"id":I[i],"start":o["start"]+dt})
run("D3 G2 move +1.6",lambda:mv('G2',1.6))
run("D4 C1 trim L +0.5",lambda:(lambda o:c.send("object.trim",{"id":I['C1'],"start":o["start"]+0.5,"duration":o["duration"]-0.5}))(c.send("object.get",{"id":I['C1']})))
run("D5 C1 resize R -0.6",lambda:(lambda o:c.send("object.trim",{"id":I['C1'],"start":o["start"],"duration":o["duration"]-0.6}))(c.send("object.get",{"id":I['C1']})))
run("D6 G3 trim L +0.6",lambda:(lambda o:c.send("object.trim",{"id":I['G3'],"start":o["start"]+0.6,"duration":o["duration"]-0.6}))(c.send("object.get",{"id":I['G3']})))
run("D7 A2 move +0.8",lambda:mv('A2',0.8))
run("D8 N1 move +1",lambda:mv('N1',1.0))
run("D9 C1 fadeIn 0.4",lambda:c.send("object.set_fade",{"id":I['C1'],"in":0.4}))
run("A1 dup C1",lambda:c.send("object.duplicate",{"ids":[I['C1']]}))
run("A1g dup G3",lambda:c.send("object.duplicate",{"ids":[I['G3']]}))
