#!/bin/bash
# open_card.sh : restart the original application under Wine, load the card image through the hooked drive and
# then run $W/post.json (a ui.py action list) if present. ORACLE_IMG is the working copy of the card image.
# The click coordinates belong to the 1920x1080 Xvfb layout of the original window; they are a recorded example.
W=${ORACLE_DIR:-/tmp/wine-try}
rm -f $W/prefix2/dosdevices/e:: $W/prefix2/dosdevices/physicaldrive1
chmod u+w "$ORACLE_IMG"
: > $W/hook.log
WDBG='err+all' WAIT=16 bash $W/restart.sh >/dev/null 2>&1
python3 $W/ui.py '[["click",490,217],["wait",1],["click",538,256],["wait",3],["click",833,703],["wait",2],["click",891,742],["wait",1],["click",977,895],["wait",30]]'
[ -f $W/post.json ] && python3 $W/ui.py "$(cat $W/post.json)"
echo FINISHED
