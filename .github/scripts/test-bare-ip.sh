#!/bin/bash
# CI: the bare-IP rule (sources/functions/bare_ip) on swizzin's real default site.
# Domains and loopback are served; the server's bare IPv4/IPv6 address gets no answer; the
# opt-out file turns it off again; a second run changes nothing. Needs nginx and openssl.
set -euo pipefail
cd "$(dirname "$0")/../.."
t=$(mktemp -d)
mkdir -p "$t/snippets" "$t/apps" "$t/bin"
blk=$(sed -n '/cat > \/etc\/nginx\/sites-enabled\/default << NGC/,/^NGC/p' scripts/install/nginx.sh | sed '1s#.*#cat << NGC#')
bash -c "$blk" | sed \
    -e "s#/etc/ssl/certs/ssl-cert-snakeoil.pem#$t/c.pem#; s#/etc/ssl/private/ssl-cert-snakeoil.key#$t/k.pem#" \
    -e "s#include snippets/ssl-params.conf;##; s#/etc/nginx/apps/\*.conf#$t/apps/*.conf#" \
    -e "s#listen 80 default_server#listen 127.0.0.1:18081 default_server#; s#listen 443 ssl http2 default_server#listen 127.0.0.1:18443 ssl default_server#" \
    -e '/listen \[::\]/d' \
    > "$t/default"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$t/k.pem" -out "$t/c.pem" -days 1 -subj /CN=test 2> /dev/null
echo 'location /x { return 200 "app\n"; }' > "$t/apps/x.conf"
printf 'pid %s/pid; error_log %s/err.log;\nevents {}\nhttp { access_log off; include %s/default; }\n' "$t" "$t" "$t" > "$t/nginx.conf"
printf '#!/bin/bash\n[[ $1 == -t ]] && exec /usr/sbin/nginx -t -q -c %s/nginx.conf\nexit 0\n' "$t" > "$t/bin/nginx"
printf '#!/bin/bash\n/usr/sbin/nginx -c %s/nginx.conf -s reload 2> /dev/null || true\n' "$t" > "$t/bin/systemctl"
chmod +x "$t/bin/nginx" "$t/bin/systemctl"
export PATH="$t/bin:$PATH"
echo_info() { echo "$*"; }
echo_warn() { echo "WARN $*"; }
# shellcheck source=sources/functions/bare_ip
. sources/functions/bare_ip
BARE_IP_SNIPPET=$t/snippets/swizzin-no-bare-ip.conf
BARE_IP_ALLOW=$t/snippets/swizzin-bare-ip.allow
BARE_IP_SITE=$t/default
BARE_IP_INCLUDE="include ${BARE_IP_SNIPPET};"

bare_ip_apply
[[ $(grep -c "swizzin-no-bare-ip" "$t/default") == 2 ]] || { echo "::error::include not added to both server blocks"; exit 1; }
before=$(md5sum "$t/default" "$BARE_IP_SNIPPET")
bare_ip_apply
[[ $before == "$(md5sum "$t/default" "$BARE_IP_SNIPPET")" ]] || { echo "::error::second run changed the files"; exit 1; }

/usr/sbin/nginx -c "$t/nginx.conf"
sleep 0.5
expect() { # host scheme+port want
    local got
    got=$(curl -sk -o /dev/null -w '%{http_code}' -H "Host: $1" "$2/x" || true)
    [[ $got == "$3" ]] || { echo "::error::Host $1 on $2 gave $got, expected $3"; /usr/sbin/nginx -c "$t/nginx.conf" -s stop; exit 1; }
    echo "ok: $1 $2 -> $got"
}
for h in example.com other.example.net example.com:443 127.0.0.1 '[::1]' 127.0.0.1:18443; do expect "$h" https://127.0.0.1:18443 200; done
for h in 203.0.113.7 203.0.113.7:443 '[2001:db8::7]' '[2001:db8::7]:443'; do expect "$h" https://127.0.0.1:18443 000; done
expect example.com http://127.0.0.1:18081 301
expect 203.0.113.7 http://127.0.0.1:18081 000

touch "$BARE_IP_ALLOW"
bare_ip_apply
sleep 1   # reload is asynchronous
expect 203.0.113.7 https://127.0.0.1:18443 200
/usr/sbin/nginx -c "$t/nginx.conf" -s stop
echo "bare-IP rule ok"
