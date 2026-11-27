#!/usr/bin/env bash
# nginx config for FileBrowser Quantum at /fbquantum. Safe to re-run (e.g. by box install nginx).

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils
#shellcheck source=sources/functions/fbquantum
. /etc/swizzin/sources/functions/fbquantum

username="$(cut -d: -f1 < /root/.master.info)"

#shellcheck source=sources/functions/panel
. /etc/swizzin/sources/functions/panel

panel_port_="$(panel_port)"
panel_base="$(grep -E '^\s*URLBASE\s*=' /opt/swizzin/swizzin.cfg 2> /dev/null | tail -n1 | sed -E "s/^[^=]*=\s*['\"]?([^'\"]*)['\"]?.*/\1/")"
panel_base="${panel_base%/}"
[[ $panel_base == "/" ]] && panel_base=""

# Preferred: ask the swizzin panel (nginx auth_request) whether the browser's saved swizzin login is
# valid — the exact check the dashboard itself makes. A browser that isn't signed in is sent to the
# dashboard login page, never shown a password popup, and never answered with a 401 (a 401 makes
# browsers forget the saved login, which is what logged people out of the dashboard).
# Fallback (no panel, an old panel, or nginx without auth_request): plain nginx basic auth.
sso=false
if [[ -f /install/.panel.lock ]] && nginx -V 2>&1 | grep -q http_auth_request_module; then
    for _ in 1 2 3 4 5 6; do     # the panel may be restarting (box update)
        if [[ $(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:${panel_port_}${panel_base}/auth/check") == 401 ]]; then
            sso=true
            break
        fi
        sleep 2
    done
fi

if [[ $sso == true ]]; then
    cat > /etc/nginx/apps/fbquantum.conf << NGINX
# FileBrowser Quantum — signed in by your swizzin login (checked by the swizzin panel)
location /fbquantum/ {
    auth_request /.swizzin-auth/fbquantum;
    auth_request_set \$swz_user \$upstream_http_x_swizzin_user;
    error_page 401 = @fbquantum_signin;
    error_page 403 = @fbquantum_forbidden;
    proxy_set_header X-Swizzin-User \$swz_user;
    proxy_set_header X-Swizzin-Groups "swizzin-admin";
    include /etc/nginx/snippets/fbquantum-proxy.conf;
}
location = /.swizzin-auth/fbquantum {
    internal;
    proxy_pass http://127.0.0.1:${panel_port_}${panel_base}/auth/check;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header X-Swizzin-Require-User "${username}";
}
location @fbquantum_signin {
    return 302 ${panel_base}/login?next=/fbquantum/;
}
location @fbquantum_forbidden {
    default_type text/html;
    return 403 '<!doctype html><meta charset="utf-8"><title>FileBrowser Quantum</title><body style="font:16px system-ui;padding:40px;max-width:560px;margin:auto"><h2>Not your files</h2><p>FileBrowser Quantum here shows the home folder of <b>${username}</b>, the server&rsquo;s main swizzin user. You are signed in to swizzin as someone else.</p><p><a href="${panel_base}/logout">Sign out</a> and sign in as ${username} to use it.</p></body>';
}
# share links and the page assets they need stay reachable without signing in
location /fbquantum/public/ {
    proxy_set_header X-Swizzin-User "";
    proxy_set_header X-Swizzin-Groups "";
    # share pages ask "who am I?" and Quantum answers 401; a browser signed in to swizzin would take
    # that as its saved login being wrong and forget it (logging you out of the dashboard), so the
    # answer goes out as 403 instead
    proxy_intercept_errors on;
    error_page 401 = @fbquantum_public_denied;
    include /etc/nginx/snippets/fbquantum-proxy.conf;
}
location @fbquantum_public_denied {
    default_type application/json;
    return 403 '{"status":403,"message":"not signed in"}';
}
NGINX
else
    cat > /etc/nginx/apps/fbquantum.conf << NGINX
# FileBrowser Quantum — nginx basic auth with the swizzin login (panel single sign-on unavailable)
location /fbquantum/ {
    auth_basic "What's the password?";
    auth_basic_user_file /etc/htpasswd.d/htpasswd.${username};
    proxy_set_header X-Swizzin-User \$remote_user;
    proxy_set_header X-Swizzin-Groups "swizzin-admin";
    include /etc/nginx/snippets/fbquantum-proxy.conf;
}
location /fbquantum/public/ {
    auth_basic off;
    proxy_set_header X-Swizzin-User "";
    proxy_set_header X-Swizzin-Groups "";
    include /etc/nginx/snippets/fbquantum-proxy.conf;
}
NGINX
fi

mkdir -p /etc/nginx/snippets
cat > /etc/nginx/snippets/fbquantum-proxy.conf << NGINX
proxy_pass http://unix:${FBQ_SOCK};
proxy_http_version 1.1;
proxy_set_header Host \$host;
proxy_set_header X-Real-IP \$remote_addr;
proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto \$scheme;
proxy_set_header X-Forwarded-Host \$http_host;
proxy_set_header Upgrade \$http_upgrade;
proxy_set_header Connection \$http_connection;
# the browser's swizzin login is for nginx only; Quantum must not see it or answer it
proxy_set_header Authorization "";
proxy_buffering off;               # live events and large downloads stream straight through
proxy_request_buffering off;       # uploads go straight to disk
client_max_body_size 0;
proxy_read_timeout 1h;
NGINX
