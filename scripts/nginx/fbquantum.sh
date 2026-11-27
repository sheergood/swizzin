#!/usr/bin/env bash
# nginx config for FileBrowser Quantum at /fbquantum. Safe to re-run (e.g. by box install nginx).

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils
#shellcheck source=sources/functions/fbquantum
. /etc/swizzin/sources/functions/fbquantum

# Like the original File Browser: no swizzin login in front, Quantum shows its own login page.
#
# One catch: the dashboard keeps you signed in with a login the browser saves and sends with every
# request to this site, Quantum's included. When an answer to such a request is 401, the browser
# decides the saved login is wrong and forgets it, which signs you out of the dashboard. Quantum answers
# 401 whenever you're not signed in to it, so for browsers carrying the swizzin login those answers go
# out as 403 instead. Quantum's page treats both the same way (shows its login page).
cat > /etc/nginx/apps/fbquantum.conf << 'NGINX'
location /fbquantum/ {
    auth_basic off;
    proxy_intercept_errors on;
    error_page 401 = @fbquantum_401;
    include /etc/nginx/snippets/fbquantum-proxy.conf;
}
location @fbquantum_401 {
    default_type application/json;
    if ($http_authorization ~* "^Basic ") {
        return 403 '{"status":403,"message":"Not signed in to FileBrowser Quantum, or wrong username or password"}';
    }
    return 401 '{"status":401,"message":"Not signed in"}';
}
NGINX

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
# the browser's saved swizzin login is not for Quantum
proxy_set_header Authorization "";
proxy_buffering off;               # live events and large downloads stream straight through
proxy_request_buffering off;       # uploads go straight to disk
client_max_body_size 0;
proxy_read_timeout 1h;
NGINX
