#!/bin/bash
# Build the hook with patches 6 and 7 and run one unmodified-card experiment ("H"). Paths: see README.md.
W=${ORACLE_DIR:-/tmp/wine-try}; INV=${ORACLE_INV:-/tmp/inv}
cd $W/hook
cp hook.c.p3 hook.c
python3 $INV/patch6.py hook.c && python3 $INV/patch7.py hook.c || { echo PATCHFAIL >> $W/exp.out; exit 1; }
bash build_hook.sh > $W/build7.log 2>&1 || { echo BUILDFAIL >> $W/exp.out; tail -5 $W/build7.log >> $W/exp.out; exit 1; }
cd $W
bash $INV/exp_evt.sh H '{}'
echo P7STARTED >> $W/exp.out
