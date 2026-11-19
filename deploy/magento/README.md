# Magento staging at shop.cartunez.in

An isolated Docker project (`cartunezshop`) on the shared VPS, next to the POS. It adds:

| What | Where |
| --- | --- |
| Containers | `cartunezshop-{db,search,cache,php,cron,web}-1` (MariaDB 11.4, OpenSearch 2.19, Valkey 8, PHP 8.3-FPM, Nginx) |
| Port | `127.0.0.1:18600` only (web container); everything else is on a private Docker network |
| Data | Docker volumes `cartunezshop_db`, `cartunezshop_search`, `cartunezshop_code` |
| Files | `/opt/cartunez-shop` (compose and scripts), `/etc/cartunez-shop` (secrets, root only) |
| Host Nginx | one new site `/etc/nginx/sites-available/cartunez-shop.conf` (+ link in `sites-enabled`) |
| Certificate | Let's Encrypt for `shop.cartunez.in` only, webroot `/var/www/cartunez-shop-acme` |

Memory is capped at about 6.5 GB in total (database 1 GB, search 1.2 GB, PHP 3 GB for compiling,
cron 768 MB, cache and web the rest); in normal use it sits around 2.5-3 GB. Nothing else on the server is
stopped, restarted, pruned or edited. Every Nginx change is tested with `nginx -t` and undone if the
test fails.

## Steps

Get the files (a separate read-only clone; the POS release clone is left alone):

```bash
git clone https://github.com/alpesh15gb/Cartunez-POS.git /opt/cartunez-shop-source
```

1. `bash /opt/cartunez-shop-source/deploy/magento/1-prepare.sh` creates the secrets, asks for the
   Magento Marketplace keys (hidden input, saved root-only), builds the PHP image and starts the
   database, search and cache. About 5 minutes.
2. `bash /opt/cartunez-shop/2-install.sh` downloads and installs Magento 2.4.8 (set
   `MAGENTO_VERSION` to use another 2.4.x release), applies India settings (INR, IST, prices
   including GST) and production mode, then starts cron and the web container. Asks for the admin
   email. 15-30 minutes. The admin login is saved in `/etc/cartunez-shop/admin-login.txt`.
3. `bash /opt/cartunez-shop/3-nginx.sh` adds the Nginx site, gets the certificate (asks for an
   email for expiry notices), and protects the shop with a staging password saved in
   `/etc/cartunez-shop/staging-login.txt`. `/rest/` stays open for the POS (Magento's API needs its
   own token).

4. `bash /opt/cartunez-shop-source/deploy/magento/4-theme.sh` installs the **Cartunez theme**
   (`storefront/app/design/frontend/Cartunez/default`: logo, colours, MRP struck through next to the
   selling price, product cards, footer) and the **Cartunez_Storefront** module, which writes the home
   page and the `cartunez-footer` block once. Both stay editable in the admin (Content › Pages ›
   Home Page, Content › Blocks). Run it again after changing the theme; about 10 minutes.

Each script stops with a clear message if something is not as expected, and can be run again.

## Connect the POS

In the Magento admin (address in `admin-login.txt`): **System › Extensions › Integrations › Add New
Integration**, name "Cartunez POS", API access to *Catalog*, *Sales › Operations › Orders* and
*Stores › Settings*; save, **Activate**, copy the **Access Token**. In the POS: Settings › Modules ›
Online store, then Settings › Online store › Connect Magento with `https://shop.cartunez.in`.

## Useful commands

```bash
docker compose -p cartunezshop ps                       # status
docker compose -p cartunezshop logs --tail 100 php web  # logs
docker stats --no-stream $(docker ps -q -f name=cartunezshop)   # memory
docker compose -p cartunezshop exec php php bin/magento cache:flush
```

## Going live (later)

Remove the three staging lines (X-Robots-Tag, auth_basic, auth_basic_user_file) from the site,
`nginx -t && systemctl reload nginx`; turn admin two-factor sign-in back on
(`bin/magento module:enable Magento_TwoFactorAuth Magento_AdminAdobeImsTwoFactorAuth`) after setting
up outgoing email; add a payment method and shipping rates; and add Magento's database and media to
the backup routine.

## Remove everything (if ever needed)

```bash
rm -f /etc/nginx/sites-enabled/cartunez-shop.conf && nginx -t && systemctl reload nginx
docker compose -p cartunezshop -f /opt/cartunez-shop/compose.yaml down        # keeps the data volumes
```
Deleting the volumes (`down --volumes`) erases the shop's database and photos; only do that on purpose.
