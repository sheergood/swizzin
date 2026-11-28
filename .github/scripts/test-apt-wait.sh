#!/bin/bash
# shellcheck disable=SC1090,SC2034
# _apt_update_waiting: waits through a held lock, logs only the last attempt
set -u
_apt_ignore_errors=""; _apt_skip_checks=""
log=$(mktemp); export log
echo_log_only() { echo "LOG $*" >> "$log"; }
echo_info() { echo "INFO $*"; }; echo_error() { echo "ERROR $*"; }; echo_warn() { echo "WARN $*"; }
echo_progress_start() { :; }; echo_progress_done() { :; }
sleep() { :; }
command -v uuidgen > /dev/null || uuidgen() { echo "mark-$RANDOM$RANDOM"; }
. "${1:-sources/functions/apt}"
n=0
apt-get() { n=$((n + 1)); if [[ $n -le 2 ]]; then echo "E: Could not get lock /var/lib/apt/lists/lock. It is held by process 1 (apt-get)"; return 100; fi; echo "Reading package lists... Done"; }
_apt_logcheck_mark
_apt_update_waiting
[[ $n == 3 ]] || { echo "FAIL tried $n times"; exit 1; }
(_apt_logcheck) | grep -q "Apt failed" && { echo "FAIL waits counted as apt errors"; cat "$log"; exit 1; }
grep -q "waiting (2/30)" "$log" || { echo "FAIL no wait note"; exit 1; }
# lock never released: gives up after 30 waits and the error is reported
n=-1000
_apt_logcheck_mark
_apt_update_waiting
[[ $n == -969 ]] || { echo "FAIL gave up after $((n + 1000)) tries"; exit 1; }
(_apt_logcheck) | grep -q "Apt failed" || { echo "FAIL a lock that never clears wasn't reported"; exit 1; }
# a real error isn't retried
apt-get() { n=$((n + 1)); echo "E: The repository 'x' does not have a Release file."; return 100; }
n=0
_apt_logcheck_mark
_apt_update_waiting
[[ $n == 1 ]] || { echo "FAIL real error retried ($n)"; exit 1; }
(_apt_logcheck) | grep -q "Apt failed" || { echo "FAIL real error hidden"; exit 1; }
echo "apt lock wait: all good"
