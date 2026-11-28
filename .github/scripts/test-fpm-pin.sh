#!/bin/bash
# install_fpm: installs the pinned fpm, swaps a newer one for it, and leaves an older one alone
# shellcheck disable=SC2154 # fpm_version and log come from / are used by sources/functions/fpm
set -u
fail=0
log=$(mktemp)
export log
echo_progress_start() { echo "> $*"; }
echo_progress_done() { :; }
echo_warn() { echo "WARN $*"; }
echo_error() { echo "ERROR $*"; }
apt_install() { :; }
_os_codename() { echo bookworm; }
# shellcheck source=/dev/null
. sources/functions/fpm

fresh() {
    GEM_HOME=$(mktemp -d)
    export GEM_HOME GEM_PATH=$GEM_HOME
    export PATH="$GEM_HOME/bin:$ORIG_PATH"
    hash -r
}
expect() {
    local want=$1 why=$2 got
    got=$(fpm --version 2> /dev/null)
    if [[ $got == "$want" ]]; then
        echo "ok   $why: fpm $got"
    else
        echo "FAIL $why: fpm '${got}', wanted $want"
        fail=1
    fi
}
ORIG_PATH=$PATH

fresh
(install_fpm)
expect "$fpm_version" "no fpm yet"

fresh
gem install fpm -v 1.18.0 --no-document > /dev/null 2>&1
expect 1.18.0 "setup"
(install_fpm)
expect "$fpm_version" "newer fpm present"
gem list fpm --exact | grep -q "1.18.0" && { echo "FAIL 1.18.0 still installed"; fail=1; }
(install_fpm)
expect "$fpm_version" "second run"

fresh
gem install fpm -v 1.15.1 --no-document > /dev/null 2>&1
(install_fpm)
expect 1.15.1 "older fpm left alone"

[[ $fail == 0 ]] || { tail -n 40 "$log"; exit 1; }
echo "fpm pin: all good"
