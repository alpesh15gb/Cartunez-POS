# Complete backup and cold recovery

Use the existing VPS/offsite backup system. Its provider, schedule and credentials have not been supplied, so these additions do not edit any live backup job or install another scheduler. They prepare complete application recovery material for that system to copy and retain.

A PostgreSQL dump and a Docker image ID alone cannot rebuild a lost host. The private recovery bundle contains the actual pinned API and PostgreSQL image bytes (`docker save`), the immutable release and static web files, private host configuration, a matching database dump with its checksum/metadata sidecars, standalone recovery tools, a manifest, and SHA-256 checksums for every file. It contains database contents and secrets. Keep the whole bundle root-owned and private; store offsite copies through the existing backup system's access-controlled, encrypted storage. Never commit a bundle, configuration, dump or credential to the public Git repository.

## Prepare material for the existing backup system

From the trusted checkout on the VPS, run as root:

```bash
# SOURCE is the absolute checked-out application root.
bash "$SOURCE/deploy/cartunez/bin/recovery-export.sh"
```

The script takes the existing deployment operation lock, creates a fresh transaction-consistent dump using `backup.sh`, verifies that its metadata matches the current release and both pinned images, and exports a complete bundle under the configured private `BACKUP_DIR/recovery/`. It prints the completed directory path. A failed export remains marked `.partial` and must not be treated as a completed backup. Exporting does not stop the application.

To package an existing verified dump instead, pass its absolute path:

```bash
bash "$SOURCE/deploy/cartunez/bin/recovery-export.sh" /absolute/path/MATCHING.dump
```

For a nondefault private configuration, prefix the command with `CARTUNEZ_CONFIG=/absolute/private/config.json`. A dump from another release or another pinned image pair is rejected.

Configure the **existing** backup system to include:

- Each retained `.dump`, `.dump.sha256` and `.dump.meta` together.
- The current private host `config.json`, with its original confidentiality protections.
- At least one complete recovery bundle for every retained release/image pair needed to restore those dumps.
- The host's separately maintained Nginx configuration, TLS/ACME material and backup-system configuration/credentials where its recovery policy requires them.

Generate a new complete bundle after deploying a new release or changing private host configuration. For subsequent daily backups on the same release, the newest complete dump trio can be restored with its matching existing image bundle using `--dump` below. If the existing backup tool supports a pre-backup hook, its operator can run `backup.sh` or `recovery-export.sh` there and capture failures; no particular provider or tool has been assumed.

The existing dump retention remains unchanged: at least seven dumps and all dumps from the last fourteen days. Recovery bundles are not automatically pruned. Keep the necessary image/configuration bundle for every retained dump; apply the existing backup system's retention and deduplication policy deliberately. Image archives can be large. A checksum detects damaged or changed bytes, but it does not authenticate a backup supplied by an untrusted party.

## Restore into a clean Docker project

Use a host with compatible Docker image architecture, local Docker Engine/Compose, Python 3 and Bash. The recovery entrypoint loads archived images; rebuilding from Git or pulling image tags is unnecessary. Nginx, DNS, TLS certificates and scheduled jobs are handled separately.

Retrieve a complete private bundle and, if needed, a newer matching dump trio. Preserve root ownership and mode 0700 on the bundle directory, mode 0600 on private files, and the release files' public read/traverse permissions. Keep recovery material in a private location. Do not copy the archived configuration onto the intended target configuration path first: all target paths must be new.

Run the restore script from a trusted checkout, or use `BUNDLE/recovery-tools/recovery-restore.sh` from your trusted backup. Set `BUNDLE` to the complete directory path. The example below uses the normal installation paths; they must not already exist on the recovery host:

```bash
bash "$SOURCE/deploy/cartunez/bin/recovery-restore.sh" "$BUNDLE" \
  --config /etc/cartunez-pos/config.json \
  --root /opt/cartunez-pos \
  --backup-dir /var/lib/cartunez-pos/backups \
  --acme-root /var/www/cartunez-pos-acme \
  --project cartunezpos \
  --api-port 18400 \
  --domain pos.cartunez.in
```

To restore a newer backup from the same release, add:

```bash
  --dump /absolute/path/NEWER-MATCHING.dump
```

Its `.sha256` and `.meta` files must be alongside it. The replacement dump must match the bundle's release ID and exact API/PostgreSQL image IDs. Regenerate the bundle when the private host configuration changes; an unrelated configuration/dump combination is not a supported shortcut.

The restore validates file inventory, every checksum, image pins, root ownership, safe paths, project names, Compose resource isolation and the unused loopback port. It refuses existing target directories/configuration, existing project containers, labelled orphan volumes/networks and canonical unlabelled resource-name collisions. It also refuses remote Docker contexts. It never overwrites an existing runtime project or changes another application's resources.

After validation it loads `images.tar` and verifies both exact image IDs. It creates a new PostgreSQL volume, starts only PostgreSQL, restores the dump in one transaction, verifies application/ledger tables, and only then starts the pinned API. Restored business credentials survive; bootstrap password creation is disabled. New public directory permissions are explicitly set so Nginx can traverse the static release and ACME tree without changing permissions on existing parent directories.

The new runtime retains a maintenance marker. Its API is reachable only through the chosen loopback port until a dedicated vhost is configured. On failure, inspect the newly created project's state and logs privately; do not point an older image at a partially migrated database. The tool leaves new resources for investigation rather than deleting them or retrying into an existing project. A subsequent clean recovery requires another unused project and new paths.

## Reopen deliberately

1. Verify restored owner login, business settings, invoices, stock, ledger totals and the backup timestamp. Reconcile sales and counter outboxes created after the chosen dump; restoration does not merge later financial records.
2. Configure the dedicated host Nginx vhost and TLS using the separate deployment instructions and the restored `CARTUNEZ_CONFIG`. Restore or reissue this hostname's certificate as appropriate. Check other applications before and after the vhost operation.
3. While the maintenance marker exists, expect HTTP 503 from the dedicated vhost. After reconciliation, remove only that marker, verify the static page and `/api/v1/health` through the intended HTTPS hostname, and then reopen counters. Restore the marker if verification fails.
4. Confirm the existing backup system now protects the restored paths and continues reporting failures. Do not enable a second timer merely because the application was recovered.

`rollback.sh` remains the matching-release database rollback workflow for an existing running project. `recovery-restore.sh` is the separate cold-host/new-project workflow.

## Local verification

`docs/test-results/cold-recovery.json` records the disposable local Docker test. It exercised real source sales, image export/load, a fresh project and volume, a newer same-release dump, owner login, exact invoice JSON and ledger/stock reconciliation, refusal of damaged bundles/existing targets/occupied ports, non-root public-file access, and orphan-resource refusal on first activation. Existing application containers and all host Nginx files were compared before and after. No production VPS or existing backup job was changed.

The image IDs were already present on the verification host; the test still executed `docker load` from the archived bytes and verified both exact IDs before restoring into a clean project. This establishes clean-project recovery, not a test of a newly installed operating system or the as-yet-unspecified offsite backup provider.
