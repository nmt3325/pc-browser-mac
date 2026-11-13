#!/usr/bin/env python3
"""Drive the Wine-hosted original application on the private Xvfb :88. usage: ui.py '<json action list>'
Actions: click/rclick/dbl x y | move x y | key <keysyms…> | type <text> | wait <s> | shot <name> [WxH+X+Y] |
windows | montage <name> <shots…> | run <shell command>. Screenshots go to $ORACLE_DIR/shots (never commit them)."""
import glob, json, os, subprocess, sys, time
W = os.environ.get('ORACLE_DIR', '/tmp/wine-try')
WINE_BIN = sorted(glob.glob(W + '/wine-*/bin'))
ENV = dict(os.environ, DISPLAY=':88', WINEPREFIX=W + '/prefix2', WINEDEBUG='-all',
           PATH=(WINE_BIN[0] + ':' if WINE_BIN else '') + os.environ['PATH'])
os.makedirs(W + '/shots', exist_ok=True)


def sh(*a):
    return subprocess.run(a, env=ENV, capture_output=True, text=True, timeout=60).stdout.strip()


def windows():
    out = []
    for wid in sh('xdotool', 'search', '--onlyvisible', '--name', '.').split():
        out.append((wid, sh('xdotool', 'getwindowname', wid), ' '.join(sh('xdotool', 'getwindowgeometry', wid).split())))
    return out


for act in json.loads(sys.argv[1]):
    op = act[0]
    if op == 'click': sh('xdotool', 'mousemove', str(act[1]), str(act[2]), 'click', '1')
    elif op == 'rclick': sh('xdotool', 'mousemove', str(act[1]), str(act[2]), 'click', '3')
    elif op == 'dbl': sh('xdotool', 'mousemove', str(act[1]), str(act[2]), 'click', '--repeat', '2', '--delay', '80', '1')
    elif op == 'move': sh('xdotool', 'mousemove', str(act[1]), str(act[2]))
    elif op == 'key': sh('xdotool', 'key', '--delay', '120', *act[1:])
    elif op == 'type': sh('xdotool', 'type', '--delay', '60', act[1])
    elif op == 'wait': time.sleep(act[1])
    elif op == 'shot':
        geom = act[2] if len(act) > 2 else None
        cmd = ['import', '-display', ':88', '-window', 'root']
        if geom: cmd += ['-crop', geom, '+repage']
        subprocess.run(cmd + [f'{W}/shots/{act[1]}.png'], env=ENV)
    elif op == 'windows':
        for w in windows(): print(*w)
    elif op == 'montage':
        subprocess.run(['montage'] + [f'{W}/shots/{n}.png' for n in act[2:]] + ['-tile', '2x', '-geometry', '+4+4', f'{W}/shots/{act[1]}.png'], env=ENV)
    elif op == 'run':
        print(subprocess.run(act[1], shell=True, env=ENV, capture_output=True, text=True, timeout=120).stdout.strip())
