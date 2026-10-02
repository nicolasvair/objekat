exec(open('/tmp/cc501/nested/x/h.py').read())
s.open_scene(c,sc); c.send("view.reveal",{"ids":[I['B1']]}); s.settle(c,400); g=s.geometry(c)
for n in ('G2','B1'): t=node(n); print(n,t['startTime'],t['duration'])
r=s.block_rect(c,I['B1'],g); print(r)
names={v:k for k,v in I.items()}
for tsec in (2.0,4.5,5.5,6.5):
    x=tsec*g['pps']; y=r[1]+r[3]*0.75
    c.send("input.hover",{"x":x,"y":y}); h=c.send("view.state.hover"); print(tsec,h['zone'],names.get(h['hovered_id'],h['hovered_id']),h['cursor'])
# grab masked part and drag it
x=6.0*g['pps']; y=r[1]+r[3]*0.75
b=s.items_state(c)
try:
    c.send("input.drag",{"x":x,"y":y,"dx":40,"dy":0,"duration_ms":500,"release":False}); s.settle(c,300)
    print("selection",c.send("selection.get") if False else "")
    s.snapshot(c,OUT+"H1_held.png"); c.send("input.release"); s.settle(c,500)
    for n in ('B1','G2'): t=node(n); print(n,t['startTime'],t['duration'])
    c.send("edit.undo"); s.settle(c,400); print("undo",s.items_state(c)==b)
except Exception as e: print("ERR",e)
