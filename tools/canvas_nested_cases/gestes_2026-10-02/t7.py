exec(open('/tmp/cc501/nested/x/t6.py').read().split("seamx=")[0])
seamx=a2[0]+0.25*g['pps']
for yy in (a1[1]+6,a1[1]+14):
    c.send("input.hover",{"x":seamx,"y":yy}); h=c.send("view.state.hover"); print(yy,h['cursor'],h['zone'])
b=s.items_state(c)
y=a1[1]+8
c.send("input.drag",{"x":seamx,"y":y,"dx":30,"dy":0,"duration_ms":500,"release":False}); s.settle(c,300)
s.snapshot(c,OUT+"C1_held.png")
c.send("input.release"); s.settle(c,600)
for n in ('A1','A2'):
    t=node(n); print(n,t['startTime'],t['duration'],t.get('fadeIn'),t.get('fadeOut'))
s.snapshot(c,OUT+"C1_after.png")
c.send("edit.undo"); s.settle(c,500); print("undo one step ok",s.items_state(c)==b)
