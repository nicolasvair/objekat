exec(open('/tmp/cc501/nested/x/h.py').read())
# D9 fade
s.open_scene(c,sc); c.send("view.reveal",{"ids":[I['C1']]}); s.settle(c,400)
x,y=s.find_zone(c,I['C1'],"fadeIn"); b=s.items_state(c)
print("fade before",node('C1')['fadeIn'])
c.send("input.drag",{"x":x,"y":y,"dx":20,"dy":0,"duration_ms":500}); s.settle(c,500)
print("fade after drag +20px (exp 0.6+0.4=1.0?)",node('C1')['fadeIn'], node('C1')['startTime'],node('C1')['duration'])
c.send("edit.undo"); s.settle(c,400); print("undo restores",s.items_state(c)==b)
# D2 : closed group G9 drop, shrink blocks
s.open_scene(c,sc); c.send("view.set",{"pps":50,"block_height":22,"scroll_x":0,"scroll_y":0}); s.settle(c,400)
c.send("view.reveal",{"ids":[I['B1']]}); s.settle(c,300)
g=s.geometry(c); print(g)
try:
    x,y=s.find_zone(c,I['B1'],"move")
    _,ty,_,_=s.block_rect(c,I['G9'],g); dy=ty+g['bh']*0.75-y
    print("target y",ty+g['bh']*0.75,"vh",g['vh'])
    b=s.items_state(c); tb=s.tree_index(json.loads(b)); n0=count()
    c.send("input.drag",{"x":x,"y":y,"dx":0,"dy":dy,"duration_ms":500,"release":False}); s.settle(c,300)
    s.snapshot(c,OUT+"D2_held.png"); c.send("input.release"); s.settle(c,600)
    ta=s.tree_index(c.send('project.get_state')['items'])
    print({k:(tb[v],ta.get(v)) for k,v in I.items() if tb.get(v)!=ta.get(v)}); print("count",n0,count())
    s.snapshot(c,OUT+"D2_after.png")
    c.send("edit.undo"); s.settle(c,500); print("undo ok",s.items_state(c)==b)
except Exception as e: print("ERR",e)
