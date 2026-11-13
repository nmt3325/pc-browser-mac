#!/bin/bash
# exp_evt.sh <tag> '<spec json for patchevt.py>'
# Restore earlier patches, apply the spec to the working copy, restart the original under Wine, load the card and
# crop the event tab to $W/shots/ev_<tag>.png. Runs in the background (about 100 s); poll `grep "EXPTAG <tag>" $W/exp.out`.
# The crop rectangle matches the 1920x1080 Xvfb screen used for the experiments; adjust it for another layout.
W=${ORACLE_DIR:-/tmp/wine-try}; INV=${ORACLE_INV:-/tmp/inv}
tag="$1"; spec="$2"
echo "$spec" > $INV/spec_$tag.json
( nohup bash -c "python3 $INV/patchevt.py restore; python3 $INV/patchevt.py apply \"\$(cat $INV/spec_$tag.json)\" > $W/exp_$tag.log 2>&1; bash $W/open_card.sh > $W/open_card.out 2>&1; convert $W/shots/tab_event.png -crop 420x260+604+556 +repage -resize 150% $W/shots/ev_$tag.png; echo EXPTAG $tag >> $W/exp.out" > /dev/null 2>&1 & )
echo started $tag
