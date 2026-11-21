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
   (dark with red accents, `storefront/app/design/frontend/Cartunez/default`) and the
   **Cartunez_Storefront** module: offer bar, hero slider, promo tiles, featured parts with "-X%"
   badges, help panel, benefits, footer, and the **Make / Model / Year finder**. The finder lists the
   vehicles from the fitment the POS sends with each published part (product attribute `cz_fitment`);
   it stays hidden until at least one published part has fitment. Edit the content in the admin:
   Content › Pages › Home Page and Content › Blocks (`cartunez-hero`, `cartunez-announcement`,
   `cartunez-footer`). The hero and promo photos are free Unsplash images (unsplash.com/license),
   loaded from Unsplash until you replace them with your own. Run the script again after changing
   the theme; about 10 minutes.

6. `bash /opt/cartunez-shop-source/deploy/magento/6-speed.sh` makes the shop faster: host Nginx
   compresses CSS, JavaScript, fonts and SVG (it compressed only HTML before), Magento minifies CSS,
   JavaScript and HTML and moves scripts to the end of the page, and the full-page cache is switched
   on. Run `4-theme.sh` afterwards so the shop's files are rebuilt with these settings.

**Premium design (November 2026).** The theme uses two self-hosted variable fonts (Inter and Saira,
SIL Open Font License, `web/fonts`) instead of Google Fonts and Luma's Open Sans. The next
`4-theme.sh` run applies the `PremiumStoreContent` data patch once. It rewrites the home page and the
`cartunez-hero` block, with a hero slider, trust strip, category tiles, brands, featured products,
studio services and a "visit us" panel, after saving the previous versions as the disabled blocks
`cartunez-home-backup` and `cartunez-hero-backup`. It leaves the footer and offer bar alone. Only the
first hero photo loads up front; the others load once the page has finished. Every photo is sized
for the screen and lazy-loaded.

**Stitch design system (November 2026).** The whole shop follows the owner's Google Stitch design:
carbon-dark surfaces, racing red for buying, turbo cyan for fitment, Montserrat headings and labels
(Google Fonts, `display=swap`, replacing Saira) with self-hosted Inter for text. The next `4-theme.sh`
run applies two data patches once. `StitchMenu` swaps the `cartunez-menu` block to the new menu only
while it still holds the launch default. `StitchStorefront` rewrites the home page, `cartunez-hero`,
`cartunez-announcement` and `cartunez-footer` (the previous versions are kept as disabled
`*-backup-stitch` blocks) and creates `cartunez-reviews`, the "Loved by Hyderabad drivers" band whose
button opens the shop's Google reviews: put the exact Google Business link there in
**Content › Blocks › cartunez-reviews**. Department tiles, menu items and the cyan "Studio fitting"
tag look for POS categories named Audio, Interior, Lighting, Dashcams, Styling, Performance and
Installation (longer names such as "Audio & Speakers" also work).

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

## Going live: `5-launch.sh`

`bash 5-launch.sh` (as root, after Stage 4) asks for the UPI ID, shop phone, and the Gmail address
and app password, then sets: cash on delivery / pay at pickup and "Pay now by UPI" (no gateway);
free store pickup plus home delivery across India (Rs 99, free from Rs 1,999; change with
`DELIVERY_FEE=… FREE_ABOVE=… bash 5-launch.sh`); order, invoice and contact emails through Gmail;
search engines allowed; a nightly backup (`/usr/local/sbin/cartunez-shop-backup`, 02:30, 14 days in
`/var/backups/cartunez-shop`; copy it off the server). Last, typing `LIVE` removes the staging password
(the old site is kept in `/etc/cartunez-shop/nginx-staging.conf.bak`). The policy pages (shipping,
returns, terms, privacy) come from Stage 4. Later: Razorpay, and admin two-factor sign-in
(`bin/magento module:enable Magento_TwoFactorAuth Magento_AdminAdobeImsTwoFactorAuth`).

## Fresh launch: `7-reset-shop.sh`

`bash 7-reset-shop.sh` (as root) clears the test data before opening: all products and their photos,
orders, invoices, shipments, credit memos, carts, customers, and every category except the two roots
(1 and 2). It keeps CMS pages and blocks, the theme, configuration, admin users and the POS token.
It takes a full backup first and asks you to type `CLEAR SHOP`. Run it **after** the POS reset
(`/opt/cartunez-pos/current/bin/reset-data.sh`). The order of commands and how to restore are in
`docs/CARTUNEZ-DEPLOYMENT.md`, section "Fresh launch: clear test data".

## Remove everything (if ever needed)

```bash
rm -f /etc/nginx/sites-enabled/cartunez-shop.conf && nginx -t && systemctl reload nginx
docker compose -p cartunezshop -f /opt/cartunez-shop/compose.yaml down        # keeps the data volumes
```
Deleting the volumes (`down --volumes`) erases the shop's database and photos; only do that on purpose.
