#!/usr/bin/env python3
"""A source rewritten while its project is CLOSED, then the project reopened in the same run:
the opening must reload it (engine and waveform), and a reopening with nothing changed must not.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_file_reopen.py /tmp/o.sock
"""
import sys, os, time, math, array, wave, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from objekat_cli import ObjekatClient
def wav(p, amp, f):
    s = array.array('h', (int(32767*amp*math.sin(2*math.pi*f*i/48000)) for i in range(96000)))
    with wave.open(p, 'wb') as w: w.setnchannels(1); w.setsampwidth(2); w.setframerate(48000); w.writeframes(s.tobytes())
d = os.path.realpath(tempfile.mkdtemp(prefix='objekat-reopen-')); os.makedirs(d+'/proj')
w = d+'/take.wav'; wav(w, 0.5, 440); P = d+'/proj/p.objekat'
fails = []
with ObjekatClient(sys.argv[1], timeout=60) as c:
    def settle(): c.send('wait_idle', {'timeout_ms': 20000})
    def reloads(): return c.send('perf.waveforms')['file_change_reloads']
    c.send('project.new'); c.send('project.save_as', {'path': P})
    c.send('object.add', {'path': w, 'lane': 0, 'start': 0.0}); c.send('project.save'); settle()
    c.send('project.open', {'path': P}); settle()        # the opening scan learns the file
    r0 = reloads()
    c.send('project.new'); settle()                        # the project is closed
    st = os.stat(w).st_mtime_ns; wav(w, 0.05, 660)        # same size, other content
    if os.stat(w).st_mtime_ns == st: os.utime(w, ns=(st+10**9, st+10**9))
    c.send('project.open', {'path': P}); settle()
    r1 = reloads(); print('reopen after a rewrite: reloads', r0, '->', r1); r1 > r0 or fails.append('reopen')
    c.send('project.new'); settle(); c.send('project.open', {'path': P}); settle()
    r2 = reloads(); print('reopen, nothing changed: reloads', r1, '->', r2); r2 == r1 or fails.append('spurious')
print('ALL PASS' if not fails else 'FAILED %s' % fails); sys.exit(1 if fails else 0)
