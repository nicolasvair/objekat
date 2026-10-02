import sys,json
sys.path.insert(0,'/Users/nicolasvair/Documents/Xcode/Objekat/objekat/tools')
import scenario_canvas_nested as s
from objekat_cli import ObjekatClient
c=ObjekatClient('/tmp/cc501/t.sock',timeout=300);c.connect()
sc=json.load(open('/tmp/cc501/nested/scene.json'));I=sc['ids']
OUT='/tmp/cc501/nested/x/'
def find(items,i):
    for it in items:
        if it['id']==i: return it
        k=it.get('kind') or {}
        if isinstance(k,dict) and k.get('children'):
            r=find(k['children'],i)
            if r: return r
def node(n): return find(c.send('project.get_state')['items'],I[n])
def count(): return len(s.tree_index(c.send('project.get_state')['items']))
