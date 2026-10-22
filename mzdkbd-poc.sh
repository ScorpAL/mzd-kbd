#!/bin/sh
# POC: on-screen keyboard (mzdkbd) driven from a shell script.
#
# All dialog windows are the stock /jci/tools/jci-dialog; the keyboard is mzdkbd/mzdkbd.
#
# Flow:
#   1. "POC keyboard" window: [Keyboard] [Exit]
#   2. Keyboard -> on-screen keyboard; the typed name comes back on stdout
#        OK     -> the name is saved to userdata.txt, window "Hello, NAME" [Exit]
#        CANCEL -> nothing is saved
#   3. Last window on every path: "you can remove the USB drive" (closes itself after 10 s, or Close)
#
# On the USB drive: this script and mzdkbd/mzdkbd.
# Output: userdata.txt (USB root) and logs/mzdkbd-poc/ (progress.log, mzdkbd.log).
#
# Safety:
#  * every window has a time limit (jci-dialog is killed when it expires, mzdkbd has --timeout/--max-seconds);
#    the keyboard's input grab is released by the kernel when the process ends;
#  * an independent watchdog stops everything after HARD_LIMIT seconds;
#  * the binary lives only in /tmp (tmpfs) and is deleted at the end; only the USB drive is
#    remounted read-write, nothing is written to the car's flash storage.

hwclock --hctosys

MYDIR=$(dirname "$(readlink -f "$0")")
mount -o rw,remount ${MYDIR}

DLG=/jci/tools/jci-dialog
KBD_SRC="${MYDIR}/mzdkbd/mzdkbd"
KBD=/tmp/mzdkbd
USERDATA="${MYDIR}/userdata.txt"
OUT="${MYDIR}/logs/mzdkbd-poc"
PROGRESS="${OUT}/progress.log"        # one line per step
KBD_LOG="${OUT}/mzdkbd.log"           # stderr of the keyboard

ASK_TIMEOUT=300                       # seconds: first window
KBD_TIMEOUT=300                       # seconds: keyboard
HELLO_TIMEOUT=120                     # seconds: "Hello" window
HARD_LIMIT=900                        # seconds: watchdog

MAIN_PID=$$

rm -rf "${OUT}"
mkdir -p "${OUT}"

# ---------------------------------------------------------------- helpers
mark()
{
  echo "[$(date +%T)] $1" >> "${PROGRESS}"
  sync
}

cleanup()
{
  killall -q jci-dialog mzdkbd 2>/dev/null
  rm -f "${KBD}"
}

# dlg <seconds> <jci-dialog args...>
# Shows one stock window and waits for it. Returns the exit code of the pressed button
# (0 = first, 1 = second), or 254 if nobody answered within <seconds> (the window is then closed).
dlg()
{
  _limit=$1
  shift
  killall -q jci-dialog 2>/dev/null
  "${DLG}" "$@" &
  _pid=$!
  _sec=0
  while kill -0 ${_pid} 2>/dev/null && [ ${_sec} -lt ${_limit} ]
  do
    sleep 1
    _sec=$((_sec + 1))
  done
  if kill -0 ${_pid} 2>/dev/null
  then
    kill ${_pid} 2>/dev/null
    killall -q jci-dialog 2>/dev/null
    wait ${_pid} 2>/dev/null
    return 254
  fi
  wait ${_pid}
}

# abort <reason>: tell the user, clean up and leave. Nothing has been changed on the car.
abort()
{
  mark "ABORT: $1"
  cleanup
  kill ${WATCHDOG_PID} 2>/dev/null
  dlg 6 --info --title="POC keyboard" --ok-label="Close" --no-cancel \
    --text="$1\nYou can remove the USB drive.\nThis window closes in 6 seconds."
  exit 0
}

# ---------------------------------------------------------------- watchdog (independent of the main flow)
(
  sleep ${HARD_LIMIT}
  echo "[$(date +%T)] WATCHDOG: hard limit reached, stopping" >> "${PROGRESS}"
  kill -9 ${MAIN_PID} 2>/dev/null
  killall -q jci-dialog mzdkbd
  rm -f "${KBD}"
  sync
) &
WATCHDOG_PID=$!

mark "start"

# ---------------------------------------------------------------- preconditions
if [ ! -f "${KBD_SRC}" ] || [ ! -x "${DLG}" ] || [ ! -f /jci/fonts/Tipperary.ttf ] || ! grep -q ' /tmp tmpfs ' /proc/mounts
then
  abort "The keyboard test cannot run on this system."
fi

cp "${KBD_SRC}" "${KBD}" && chmod +x "${KBD}"
"${KBD}" --help > /dev/null 2>&1 || abort "The keyboard does not start."

mark "preconditions ok"

# ---------------------------------------------------------------- 1. Keyboard / Exit
dlg ${ASK_TIMEOUT} --question --title="POC keyboard" --text="Click keyboard button and type your name." \
  --ok-label="Keyboard" --cancel-label="Exit"
ANSWER=$?
mark "window 1 returned ${ANSWER} (0 = Keyboard, 1 = Exit, 254 = nobody answered)"

# ---------------------------------------------------------------- 2. keyboard, save, greeting
if [ ${ANSWER} -eq 0 ]
then
  NAME=$("${KBD}" --max-chars=20 --timeout=${KBD_TIMEOUT} --max-seconds=$((KBD_TIMEOUT + 20)) 2>> "${KBD_LOG}")
  KBD_RC=$?
  mark "keyboard returned ${KBD_RC} (0 = OK, 1 = Cancel, 254 = timeout, 255 = did not start)"
  sleep 1

  [ ${KBD_RC} -eq 255 ] && abort "The keyboard failed to start."

  if [ ${KBD_RC} -eq 0 ] && [ -n "${NAME}" ]
  then
    echo "${NAME}" > "${USERDATA}"
    sync
    mark "name saved to userdata.txt"
    dlg ${HELLO_TIMEOUT} --info --title="POC Keyboard" --text="Hello, ${NAME}" --ok-label="Exit" --no-cancel
    mark "hello window returned $?"
  fi
fi

# ---------------------------------------------------------------- 3. last window on every path
mark "final window"
dlg 10 --info --title="POC keyboard" --ok-label="Close" --no-cancel \
  --text="You can remove the USB drive now.\nThis window closes by itself in 10 seconds."

cleanup
kill ${WATCHDOG_PID} 2>/dev/null
mark "done"
exit 0
