# nannakolla test server - reverse proxy to Leptos/Axum app
server {
    server_name nannakolla.com;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }

    # Static assets - serve directly if you want (optional, Axum can handle it)
    location /static/ {
        alias /var/www/rlxapi.eu/nannakolla/html/;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
    location /pkg/ {
    	alias /var/www/rlxapi.eu/nannakolla/html/pkg/;
	    expires 1y;
    	add_header Cache-Control "public, immutable";
	}

    access_log /var/log/nginx/nannakolla.com.access.log;
    error_log /var/log/nginx/nannakolla.com.error.log;

    listen [::]:443 ssl;
    listen 443 ssl;

    ssl_certificate /etc/letsencrypt/live/nannakolla.com/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/nannakolla.com/privkey.pem; # managed by Certbot
}

# HTTP redirect
server {
    if ($host = nannakolla.com) {
        return 301 https://$host$request_uri;
    } # managed by Certbot


    listen 80;
    listen [::]:80;
    server_name nannakolla.com;
    return 301 https://$host$request_uri;


}