#!/bin/bash
# CI: the swizzin web jails parse, fail2ban accepts them, and each filter matches exactly the lines it
# should (attacks yes; normal traffic, first visits without a password and injected text no).
# Needs root and the fail2ban package.
set -euo pipefail
cd "$(dirname "$0")/../.."
log=/tmp/swizzin-f2b-ci.log
export log
# shellcheck source=sources/functions/color_echo
. sources/functions/color_echo
# shellcheck source=sources/functions/panel
. sources/functions/panel
id swizzin > /dev/null 2>&1 || useradd -r swizzin -s /usr/sbin/nologin
mkdir -p /var/log/nginx
panel_f2b_web_setup
fail2ban-client -t
for f in "${PANEL_F2B_FILES[@]}"; do [[ -f $f ]] || { echo "::error::$f missing"; exit 1; }; done

t=$(mktemp -d)
cat > "$t/panel.log" << 'EOF'
2026-11-28T07:44:00+0530 swizzin-panel: login failed from 203.0.113.7
2026-11-28T07:44:05+0530 swizzin-panel: login failed from 2001:db8::5
2026-11-28T07:44:06+0530 swizzin-panel: something else from 198.51.100.1
EOF
cat > "$t/access.log" << 'EOF'
203.0.113.9 - - [28/Nov/2026:07:44:00 +0530] "GET /wp-login.php HTTP/1.1" 404 162 "-" "Mozilla/5.0"
203.0.113.9 - - [28/Nov/2026:07:44:01 +0530] "GET /.env HTTP/1.1" 404 162 "-" "curl"
203.0.113.9 - - [28/Nov/2026:07:44:02 +0530] "POST /vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php HTTP/1.1" 404 162 "-" "x"
203.0.113.9 - - [28/Nov/2026:07:44:03 +0530] "GET /.git/config HTTP/1.1" 403 162 "-" "x"
198.51.100.4 - prateek [28/Nov/2026:07:44:04 +0530] "GET /sonarr/api/v3/queue HTTP/2.0" 200 162 "-" "Mozilla"
198.51.100.4 - prateek [28/Nov/2026:07:44:05 +0530] "GET /static/js/glass.js?v=.env HTTP/2.0" 200 162 "-" "Mozilla"
198.51.100.4 - - [28/Nov/2026:07:44:06 +0530] "GET /environment HTTP/1.1" 404 162 "-" "x"
198.51.100.4 - - [28/Nov/2026:07:44:07 +0530] "GET /wp-login.php HTTP/1.1" 200 162 "-" "x"
198.51.100.5 - - [28/Nov/2026:07:44:08 +0530] "GET /x HTTP/1.1" 404 162 "GET /wp-login.php HTTP/1.1\" 404" "x"
EOF
cat > "$t/fb.log" << 'EOF'
203.0.113.30 - - [28/Nov/2026:07:44:00 +0530] "POST /filebrowser/api/login HTTP/2.0" 403 10 "-" "Mozilla"
203.0.113.31 - - [28/Nov/2026:07:44:01 +0530] "POST /fbquantum/api/auth/login?username=admin HTTP/2.0" 401 10 "-" "Mozilla"
198.51.100.4 - - [28/Nov/2026:07:44:02 +0530] "POST /filebrowser/api/login HTTP/2.0" 200 400 "-" "Mozilla"
198.51.100.4 - - [28/Nov/2026:07:44:03 +0530] "GET /filebrowser/api/resources/ HTTP/2.0" 401 10 "-" "Mozilla"
198.51.100.4 - - [28/Nov/2026:07:44:04 +0530] "POST /fbquantum/api/auth/login?username=me HTTP/2.0" 200 400 "-" "Mozilla"
EOF
cat > "$t/error.log" << 'EOF'
2026/11/28 07:44:00 [error] 1234#1234: *5 user "admin": password mismatch, client: 203.0.113.20, server: example.com, request: "GET /sonarr HTTP/2.0", host: "example.com"
2026/11/28 07:44:01 [error] 1234#1234: *6 no user/password was provided for basic authentication, client: 198.51.100.4, server: example.com, request: "GET /sonarr HTTP/2.0", host: "example.com"
2026/11/28 07:44:02 [error] 1234#1234: *7 user "bob" was not found in "/etc/htpasswd", client: 203.0.113.21, server: example.com, request: "GET /radarr HTTP/2.0", host: "example.com"
EOF
check() { # log filter expected-matches expected-ip-list
    local out n ips
    out=$(fail2ban-regex -v "$t/$1" "/etc/fail2ban/filter.d/$2.conf")
    n=$(grep -oE '^Lines: [0-9]+ lines, [0-9]+ ignored, [0-9]+ matched' <<< "$out" | awk '{print $6}')
    ips=$(grep -oE '^\|\s+[0-9a-f.:]+\s+(Mon|Tue|Wed|Thu|Fri|Sat|Sun) ' <<< "$out" | awk '{print $2}' | sort -u | tr '\n' ' ')
    if [[ $n != "$3" || $ips != "$4" ]]; then
        echo "::error::$2 matched $n line(s) from [$ips], expected $3 from [$4]"
        echo "$out"
        exit 1
    fi
    echo "ok: $2 matched $n line(s) from [$ips]"
}
check panel.log swizzin-panel 2 "2001:db8::5 203.0.113.7 "
check access.log swizzin-scan 4 "203.0.113.9 "
check fb.log swizzin-filebrowser 2 "203.0.113.30 203.0.113.31 "
check error.log nginx-http-auth 2 "203.0.113.20 203.0.113.21 "

# a second run changes nothing; remove takes everything away again
before=$(md5sum "${PANEL_F2B_FILES[@]}")
panel_f2b_web_setup
[[ $before == "$(md5sum "${PANEL_F2B_FILES[@]}")" ]] || { echo "::error::second run changed the files"; exit 1; }
panel_f2b_web_remove
for f in "${PANEL_F2B_FILES[@]}"; do [[ ! -e $f ]] || { echo "::error::$f left behind"; exit 1; }; done
fail2ban-client -t
echo "fail2ban web jails ok"
