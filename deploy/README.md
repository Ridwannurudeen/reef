# Deploy `reef.gudman.xyz`

Same playbook as `verdikt.gudman.xyz`. DNS already points the subdomain to the gudman.xyz VPS (`75.119.153.252`). What's left: nginx server block, Let's Encrypt cert, upload `ui/index.html` as the homepage and `slides.html` next to it.

## What gets deployed

```
/opt/reef/web/
├── index.html      ← ui/index.html (the live dashboard)
└── slides.html     ← slides.html (the hackathon pitch deck)
```

`reef.gudman.xyz/` is the live dashboard you can paste in any DoraHacks field. `reef.gudman.xyz/slides.html` is the deck.

## One-time setup (run on the VPS)

```bash
sudo mkdir -p /opt/reef/web
sudo chown -R $USER:$USER /opt/reef
sudo cp /tmp/nginx-reef.gudman.xyz.conf /etc/nginx/sites-available/
sudo ln -sf /etc/nginx/sites-available/nginx-reef.gudman.xyz.conf /etc/nginx/sites-enabled/
sudo certbot certonly --webroot -w /var/www/html -d reef.gudman.xyz \
    --non-interactive --agree-tos -m nraheemst@gmail.com
sudo nginx -t && sudo systemctl reload nginx
```

## Upload (run on your laptop)

```bash
scp ui/index.html                       root@75.119.153.252:/opt/reef/web/index.html
scp slides.html                         root@75.119.153.252:/opt/reef/web/slides.html
scp deploy/nginx-reef.gudman.xyz.conf   root@75.119.153.252:/tmp/
```

## Re-deploy after editing UI or slides

```bash
scp ui/index.html  root@75.119.153.252:/opt/reef/web/index.html
scp slides.html    root@75.119.153.252:/opt/reef/web/slides.html
```

No nginx reload needed for content changes — both files are self-contained (viem + reveal.js from CDN).

## Verify

```bash
curl -sI https://reef.gudman.xyz/ | head -5
# HTTP/2 200, content-type: text/html
```
