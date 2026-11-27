#!/usr/bin/env bash
# CI: render the FileBrowser Quantum config swizzin writes, create the account the way the installer
# does, run the newest stable release on its unix socket, and check: password login gives an admin
# account that can browse, upload, overwrite, download, share and delete; wrong passwords and stray
# headers get nothing; nothing listens on TCP.
# Needs root (creates a throwaway user). Usage: sudo bash .github/scripts/test-fbquantum.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
echo_error() { echo "ERROR: $*" >&2; }
echo_log_only() { :; }
_os_arch() { dpkg --print-architecture; }
apt_install() { apt-get install -y -q "$@" > /dev/null; }
log=/dev/null
# shellcheck source=sources/functions/fbquantum
. sources/functions/fbquantum

u=fbqci
id "$u" > /dev/null 2>&1 || useradd -m "$u"
home="/home/${u}" conf="/home/${u}/.config/fbquantum"
FBQ_BIN="/tmp/fbqci/filebrowser"
FBQ_SOCK="/tmp/fbqci/run/fbquantum.sock"
mkdir -p /tmp/fbqci/run && chown "$u": /tmp/fbqci/run && chmod 0711 /tmp/fbqci/run

read -r tag url sum <<< "$(fbquantum_latest_stable)" || true
[[ -n $tag && -n $url && $url != null ]] || { echo "Couldn't get the FileBrowser Quantum release list from GitHub"; exit 1; }
echo "testing ${tag}"
curl -fsSL --retry 3 -o "$FBQ_BIN" "$url"
[[ -n $sum ]] && echo "${sum}  ${FBQ_BIN}" | sha256sum -c --quiet -
chmod 755 "$FBQ_BIN"

fbquantum_write_config "$u" "$conf"
fbquantum_set_account "$u" "$conf" 'ci-Pass-123' > /tmp/fbqci/account.log 2>&1 || { cat /tmp/fbqci/account.log; exit 1; }
[[ $(fbquantum_config_version "${conf}/config.yaml") == "$FBQ_CONFIG_VERSION" ]] || { echo "config version marker missing"; exit 1; }
echo hello > "${home}/hello.txt" && chown "$u": "${home}/hello.txt"

(cd "$conf" && runuser -u "$u" -g "$u" -G www-data -- "$FBQ_BIN" -c "${conf}/config.yaml" > /tmp/fbqci/run.log 2>&1 &)
trap 'pkill -u "$u" -x filebrowser || true; cat /tmp/fbqci/run.log | grep -E "ERROR|FATAL" || true' EXIT
ok=false
for _ in $(seq 1 40); do [[ -S $FBQ_SOCK ]] && ok=true && break; sleep 0.5; done
$ok || { echo "Quantum did not open its socket"; cat /tmp/fbqci/run.log; exit 1; }

jar=/tmp/fbqci/cookies
login() { curl -s -o /dev/null -w '%{http_code}' --unix-socket "$FBQ_SOCK" -c "$jar" -X POST "http://localhost/fbquantum/api/auth/login?username=${u}" -H "X-Password: $1"; }
q() { curl -s --unix-socket "$FBQ_SOCK" -b "$jar" "$@"; }
code() { q -o /dev/null -w '%{http_code}' "$@"; }
fail=0
check() { if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fail=1; fi; }

check "wrong password refused" "$(login nope)" 401
check "password login" "$(login ci-Pass-123)" 200
perms="$(q "http://localhost/fbquantum/api/users?username=self" | python3 -c 'import sys,json; d=json.load(sys.stdin); p=d["permissions"]; print(d["username"], d["loginMethod"], p["admin"], p["share"], p["api"])')"
check "account (user, method, admin, share, api)" "$perms" "${u} password True True True"
check "list home" "$(code "http://localhost/fbquantum/api/resources?source=${u}&path=%2F")" 200
check "upload" "$(code -X POST "http://localhost/fbquantum/api/resources?source=${u}&path=%2Fci.txt" --data-binary hi)" 200
check "overwrite" "$(code -X POST "http://localhost/fbquantum/api/resources?source=${u}&path=%2Fci.txt&override=true" --data-binary hi2)" 200
check "download" "$(q "http://localhost/fbquantum/api/raw?source=${u}&file=%2Fhello.txt")" hello
check "share" "$(code -X POST http://localhost/fbquantum/api/share -H 'Content-Type: application/json' -d "{\"path\":\"/hello.txt\",\"source\":\"${u}\"}")" 200
check "delete" "$(code -X DELETE "http://localhost/fbquantum/api/resources?source=${u}&path=%2Fci.txt")" 200
check "no session = not signed in" "$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$FBQ_SOCK" "http://localhost/fbquantum/api/users?username=self")" 401
check "proxy header grants nothing" "$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$FBQ_SOCK" -H "X-Swizzin-User: ${u}" "http://localhost/fbquantum/api/users?username=self")" 401
check "no TCP listener" "$(ss -Htlnp | grep -c filebrowser || true)" 0
check "socket mode/group" "$(stat -c '%a %G' "$FBQ_SOCK")" "660 www-data"
exit $fail
