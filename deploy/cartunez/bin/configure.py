#!/usr/bin/env python3
"""Create private host configuration once; never print generated credentials."""
import argparse
import json
import os
import pathlib
import re
import secrets

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--config', default='/etc/cartunez-pos/config.json')
p.add_argument('--root', default='/opt/cartunez-pos')
p.add_argument('--backup-dir', default='/var/lib/cartunez-pos/backups')
p.add_argument('--acme-root', default='/var/www/cartunez-pos-acme')
p.add_argument('--domain', default='pos.cartunez.in')
p.add_argument('--project', default='cartunezpos')
p.add_argument('--api-port', type=int, default=18400)
p.add_argument('--owner-email', required=True)
p.add_argument('--owner-name', default='Owner')
p.add_argument('--organization-code', required=True)
p.add_argument('--business-name', default='New business')
p.add_argument('--branch-code', required=True)
p.add_argument('--branch-name', default='Main branch')
p.add_argument('--currency', required=True)
a = p.parse_args()
if os.geteuid() != 0:
    p.error('Run as root to protect the host configuration.')
if not 1024 <= a.api_port <= 65535:
    p.error('API port must be between 1024 and 65535.')
for value, pattern in [(a.domain, r'[a-z0-9][a-z0-9.-]+\.[a-z]{2,}'),
                       (a.project, r'[a-z][a-z0-9]{2,30}'),
                       (a.organization_code, r'[a-z0-9][a-z0-9_-]{1,63}'),
                       (a.branch_code, r'[a-z0-9][a-z0-9_-]{1,63}'),
                       (a.currency, r'[A-Z]{3}'),
                       (a.owner_email, r'[^\s@]+@[^\s@]+\.[^\s@]+')]:
    if not re.fullmatch(pattern, value):
        p.error('Invalid domain, identifier, currency, or email format.')
for value in vars(a).values():
    if isinstance(value, str) and (not value.strip() or any(ord(c) < 32 for c in value)):
        p.error('Values must be nonempty and cannot contain control characters.')
for value in [a.root, a.backup_dir, a.acme_root, a.config]:
    if not re.fullmatch(r'/[A-Za-z0-9/_-]+(?:\.json)?', value) or '..' in value.split('/'):
        p.error('Use absolute paths containing only letters, digits, slash, underscore, hyphen, and an optional .json suffix.')
    if pathlib.Path(value).resolve() != pathlib.Path(value):
        p.error('Configuration and runtime paths must not traverse symlinks.')
if a.root in ['/', '/opt', '/srv', '/var', '/etc']:
    p.error('Use a dedicated application root.')
config = pathlib.Path(a.config)
if config.exists():
    p.error('Configuration already exists; it was not changed.')
config.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
if config.parent.stat().st_uid != 0 or config.parent.stat().st_mode & 0o022:
    p.error('Configuration parent must be root-owned and not writable by group/others.')
for target, mode in [(a.root, 0o755), (a.backup_dir, 0o700), (a.acme_root, 0o755)]:
    directory = pathlib.Path(target)
    if directory.exists() and (directory.stat().st_uid != 0 or any(directory.iterdir())):
        p.error(f'{target} must be a new or empty root-owned directory.')
    directory.mkdir(parents=True, exist_ok=True, mode=mode)
    directory.chmod(mode)
owner_password = secrets.token_urlsafe(30)
values = dict(CARTUNEZ_ROOT=a.root, CARTUNEZ_PROJECT=a.project, BACKUP_DIR=a.backup_dir,
              ACME_ROOT=a.acme_root, DOMAIN=a.domain, API_PORT=str(a.api_port),
              POSTGRES_DB='cartunezpos', POSTGRES_USER='cartunezpos',
              POSTGRES_PASSWORD=secrets.token_hex(32), JWT_SECRET=secrets.token_hex(48),
              BOOTSTRAP_OWNER_EMAIL=a.owner_email, BOOTSTRAP_OWNER_PASSWORD=owner_password,
              BOOTSTRAP_OWNER_NAME=a.owner_name, BOOTSTRAP_ORG_ID=a.organization_code,
              BOOTSTRAP_ORG_NAME=a.business_name, BOOTSTRAP_BRANCH_ID=a.branch_code,
              BOOTSTRAP_BRANCH_NAME=a.branch_name, BOOTSTRAP_CURRENCY=a.currency)
fd = os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as stream:
    json.dump(values, stream, indent=2)
    stream.write('\n')
login_path = config.parent / 'owner-login.txt'
fd = os.open(login_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as stream:
    stream.write(f'URL: https://{a.domain}\nOrganization: {a.organization_code}\nBranch: {a.branch_code}\nEmail: {a.owner_email}\nInitial password: {owner_password}\n')
print(f'Private configuration created: {config}\nOwner login saved privately: {login_path}\nNo credentials were printed.')
