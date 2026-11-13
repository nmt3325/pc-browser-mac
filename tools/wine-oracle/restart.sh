#!/bin/bash
# restart the original application in the private Wine prefix; optional arguments are passed to the application.
#   ORACLE_DIR     work directory (default /tmp/wine-try): prefix2/, app/ with the hooked exe, wine-*/ runtime, shots/
#   ORACLE_LOCALES directory with a ja_JP.UTF-8 locale (optional); ORACLE_XVFB path of Xvfb; SCREEN e.g. 1920x1080x24
W=${ORACLE_DIR:-/tmp/wine-try}
export LOCPATH=${ORACLE_LOCALES:-$LOCPATH} LC_ALL=ja_JP.UTF-8 LANG=ja_JP.UTF-8 DISPLAY=:88 WINEPREFIX=$W/prefix2 WINEDEBUG=${WDBG:--all} PATH=$(ls -d $W/wine-*/bin | head -1):$PATH WINEDLLOVERRIDES="mscoree,mshtml=,winemenubuilder.exe="
wineserver -k 2>/dev/null; sleep 2
XVFB=${ORACLE_XVFB:-Xvfb}
if [ -n "$SCREEN" ]; then
  pkill -u $USER -f "^.*Xvfb :88 "; sleep 1; rm -f /tmp/.X11-unix/X88 /tmp/.X88-lock
  setsid nohup $XVFB :88 -screen 0 $SCREEN -nolisten tcp > $W/xvfb.log 2>&1 < /dev/null &
  sleep 2
fi
if [ ! -e $W/fonts-done ]; then
  # the original asks for Windows fonts; map them all to one installed CJK font
  for f in "MS Shell Dlg" "MS Shell Dlg 2" "Tahoma" "Segoe UI" "Microsoft Sans Serif" "MS UI Gothic" "MS Gothic" "MS PGothic" "Meiryo" "Meiryo UI" "Yu Gothic" "Arial" "Verdana" "MS Mincho" "MS PMincho" "Times New Roman" "Courier New" "System" "Terminal" "Lucida Sans Unicode" "SimSun" "Malgun Gothic"; do
    wine reg add 'HKCU\Software\Wine\Fonts\Replacements' /v "$f" /d "Noto Sans CJK JP" /f >/dev/null 2>&1
  done
  touch $W/fonts-done
fi
cd $W/app
setsid nohup wine "PC Browser.exe" "$@" > $W/app2.log 2>&1 < /dev/null &
sleep ${WAIT:-20}
for id in $(xdotool search --onlyvisible --name '.' 2>/dev/null); do echo "$id [$(xdotool getwindowname $id 2>/dev/null)] $(xdotool getwindowgeometry $id 2>/dev/null | tr '\n' ' ')"; done | head -10
