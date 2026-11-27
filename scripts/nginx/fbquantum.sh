#!/usr/bin/env bash
# nginx config for FileBrowser Quantum at /fbquantum. Safe to re-run (e.g. by box install nginx).

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils
#shellcheck source=sources/functions/fbquantum
. /etc/swizzin/sources/functions/fbquantum

username="$(cut -d: -f1 < /root/.master.info)"

cat > /etc/nginx/apps/fbquantum.conf << NGINX
# FileBrowser Quantum: the swizzin login (same realm as the dashboard, so one sign-in covers both),
# then the signed-in user is handed to Quantum. Its own login page is never needed.
location /fbquantum/ {
    auth_basic "What's the password?";
    auth_basic_user_file /etc/htpasswd.d/htpasswd.${username};
    proxy_set_header X-Swizzin-User \$remote_user;
    proxy_set_header X-Swizzin-Groups "swizzin-admin";   # only the master's htpasswd is accepted here
    include /etc/nginx/snippets/fbquantum-proxy.conf;
}
# share links and the page assets they need stay reachable without the swizzin login
location /fbquantum/public/ {
    auth_basic off;
    proxy_set_header X-Swizzin-User "";
    proxy_set_header X-Swizzin-Groups "";
    include /etc/nginx/snippets/fbquantum-proxy.conf;
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
# the browser's swizzin login is for nginx only; Quantum must not see it or answer it
proxy_set_header Authorization "";
proxy_buffering off;               # live events and large downloads stream straight through
proxy_request_buffering off;       # uploads go straight to disk
client_max_body_size 0;
proxy_read_timeout 1h;
NGINX
