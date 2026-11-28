#!/bin/bash
# CI: Allowed Hosts for Sonarr/Radarr/Prowlarr/Lidarr (sources/functions/servarr_hosts).
# - the new nginx templates and old ones patched in place pass `nginx -t`
# - through nginx, any site name or IP reaches the app as Host 127.0.0.1, and the app's own
#   redirects come back as a path on the site
# - config.xml gets Allowed Hosts unless the admin set a list; the file stays valid XML
# Needs root and nginx.
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=sources/functions/servarr_hosts
. sources/functions/servarr_hosts
t=$(mktemp -d)
render() { # script-ref app port -> nginx app config on stdout
    local blk
    blk=$(git show "$1:scripts/nginx/$2.sh" | sed -n '/cat > \/etc\/nginx\/apps\/\$app_name.conf << ARRNGINX/,/^ARRNGINX/p' | sed '1s#.*#cat << ARRNGINX#')
    app_baseurl=$2 app_port=$3 master=ci bash -c "app_baseurl=$2; app_port=$3; master=ci; $blk" | grep -v auth_basic
}
cat > "$t/nginx.conf" << EOF
pid $t/nginx.pid; error_log $t/error.log;
events {}
http { access_log off;
  server { listen 127.0.0.1:18080 default_server; server_name _; include $t/app.conf; }
}
EOF
port=8989
for app in sonarr radarr prowlarr lidarr; do
    render HEAD "$app" $port > "$t/app.conf"
    grep -q 'proxy_set_header Host 127.0.0.1;' "$t/app.conf" || { echo "::error::$app template still passes the site name"; exit 1; }
    nginx -t -q -c "$t/nginx.conf"
    # an install made from the old template, patched in place
    if git cat-file -e "HEAD~1:scripts/nginx/$app.sh" 2> /dev/null && render HEAD~1 "$app" $port > "$t/old.conf" &&
        grep -q 'proxy_set_header Host \$host;' "$t/old.conf"; then
        servarr_nginx_patch "$t/old.conf"
        cp "$t/old.conf" "$t/app.conf"
        nginx -t -q -c "$t/nginx.conf"
        if servarr_nginx_patch "$t/old.conf"; then
            echo "::error::$app patched twice"
            exit 1
        fi
    fi
    echo "ok: $app nginx"
done

# what the app sees through nginx
render HEAD sonarr 8989 > "$t/app.conf"
cat > "$t/backend.py" << 'EOF'
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        host = self.headers.get("Host", "")
        if self.path.startswith("/sonarr/login-redirect"):
            self.send_response(302); self.send_header("Location", "http://" + host + "/sonarr/login?ReturnUrl=%2Fsonarr"); self.end_headers(); return
        b = json.dumps({"host": host}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
http.server.HTTPServer(("127.0.0.1", 8989), H).serve_forever()
EOF
python3 "$t/backend.py" &
bp=$!
nginx -c "$t/nginx.conf"
sleep 1
for h in example.com 192.0.2.10 another.example.net; do
    got=$(curl -s -H "Host: $h" http://127.0.0.1:18080/sonarr/system)
    [[ $got == '{"host": "127.0.0.1"}' ]] || { echo "::error::Host $h reached the app as $got"; exit 1; }
done
loc=$(curl -s -o /dev/null -D - -H "Host: example.com" http://127.0.0.1:18080/sonarr/login-redirect | tr -d '\r' | grep -i '^location:')
[[ $loc == *"example.com"*"/sonarr/login?ReturnUrl=%2Fsonarr" && $loc != *127.0.0.1* ]] || { echo "::error::redirect came back as '$loc'"; exit 1; }
nginx -c "$t/nginx.conf" -s stop
kill "$bp"
echo "ok: any site name reaches the app as 127.0.0.1; redirects stay on the site"

# config.xml
for v in none empty selfclose own; do
    case $v in
        none) x="" ;;
        empty) x="  <AllowedHosts></AllowedHosts>" ;;
        selfclose) x="  <AllowedHosts />" ;;
        own) x="  <AllowedHosts>media.example.com</AllowedHosts>" ;;
    esac
    printf '<Config>\n  <Port>9696</Port>\n%s\n  <UrlBase>/prowlarr</UrlBase>\n</Config>\n' "$x" | sed '/^$/d' > "$t/$v.xml"
    rc=0
    servarr_config_patch "$t/$v.xml" || rc=$?
    python3 -c "import sys, xml.etree.ElementTree as E; r = E.parse(sys.argv[1]).getroot(); v = [e.text for e in r.iter('AllowedHosts')]; print(v); sys.exit(0 if len(v) == 1 else 1)" "$t/$v.xml" > "$t/out"
    if [[ $v == own ]]; then
        [[ $rc == 1 ]] && grep -q "media.example.com" "$t/out" || { echo "::error::the admin's own list was changed"; exit 1; }
    else
        [[ $rc == 0 ]] && grep -q "localhost,127.0.0.1" "$t/out" || { echo "::error::$v: Allowed Hosts not set"; exit 1; }
    fi
done
echo "ok: config.xml"
echo "servarr Allowed Hosts ok"
