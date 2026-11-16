#!/usr/bin/env python3
"""Private image-inclusive recovery export and non-overwriting clean-project restore."""
import argparse
import fcntl
import datetime
import hashlib
import json
import os
import pathlib
import re
import shutil
import socket
import stat
import subprocess
import sys
import urllib.request

PRIVATE_VALUES = []


def fail(message):
    raise RuntimeError(message)


def run(command, env=None, stdin=None):
    result = subprocess.run(command, env=env, stdin=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        message = result.stderr.decode(errors='replace')[-1800:]
        for secret in PRIVATE_VALUES:
            if secret:
                message = message.replace(secret, '[redacted]')
        fail('Command failed (' + command[0] + '): ' + message)
    return result.stdout.decode(errors='replace').strip()


def safe_path(value, label, suffix=False):
    path = pathlib.Path(value)
    pattern = r'/[A-Za-z0-9/_-]+' + (r'(?:\.json)?' if suffix else '')
    if not re.fullmatch(pattern, str(path)) or len(path.parts) < 3 or path.resolve() != path or path.is_symlink():
        fail('Unsafe ' + label + ' path.')
    return path


def regular(path, private=False):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        fail('Expected a root-owned regular file, not writable by group/others: ' + str(path))
    if private and info.st_mode & 0o077:
        fail('Private file must have mode 0600: ' + str(path))


def config_read(path):
    regular(path, True)
    config = json.loads(path.read_text())
    for key in ['POSTGRES_PASSWORD', 'JWT_SECRET', 'BOOTSTRAP_OWNER_PASSWORD']:
        PRIVATE_VALUES.append(str(config.get(key, '')))
    for key, value in config.items():
        if not re.fullmatch(r'[A-Z][A-Z0-9_]*', key) or not isinstance(value, str) or '\x00' in value:
            fail('Invalid private configuration entry.')
    if not re.fullmatch(r'[a-z][a-z0-9]{2,30}', config.get('CARTUNEZ_PROJECT', '')):
        fail('Invalid project identifier.')
    for key in ['POSTGRES_DB', 'POSTGRES_USER']:
        if not re.fullmatch(r'[a-z_][a-z0-9_]{0,62}', config.get(key, '')):
            fail('Invalid PostgreSQL identifier.')
    return config


def digest(path):
    hasher = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            hasher.update(chunk)
    return hasher.hexdigest()


def files_in(root):
    files = []
    for path in root.rglob('*'):
        info = path.lstat()
        if stat.S_ISDIR(info.st_mode):
            if info.st_uid != 0 or info.st_mode & 0o022:
                fail('Unsafe bundle directory: ' + str(path))
            continue
        regular(path)
        relative = path.relative_to(root).as_posix()
        if any(character in relative for character in ['\n', '\r', '\\']):
            fail('Unsupported bundle filename.')
        files.append(relative)
    return sorted(files)


def image_id(path):
    value = path.read_text().strip()
    if not re.fullmatch(r'sha256:[a-f0-9]{64}', value):
        fail('Invalid pinned image ID.')
    return value


def meta_read(path):
    values = {}
    for line in path.read_text().splitlines():
        key, separator, value = line.partition('=')
        if not separator or key in values:
            fail('Invalid dump metadata.')
        values[key] = value
    return values


def write_private(path, content):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        stream.write(content)


def create_public_directory(path):
    missing = []
    current = path
    while not current.exists():
        missing.append(current)
        current = current.parent
    for directory in reversed(missing):
        directory.mkdir(mode=0o755)
        directory.chmod(0o755)


def export_bundle(args):
    config = config_read(pathlib.Path(args.config))
    release = pathlib.Path(args.release)
    release_id = release.name
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,79}', release_id) or '..' in release_id:
        fail('Invalid release ID.')
    expected_release = safe_path(config['CARTUNEZ_ROOT'], 'application root') / 'releases' / release_id
    if release != expected_release or release.resolve() != release or release.is_symlink():
        fail('Release must be inside the configured immutable release directory.')
    files_in(release)
    api_image, postgres_image = image_id(release / 'image-id'), image_id(release / 'postgres-image-id')
    dump = pathlib.Path(args.dump)
    for path in [dump, pathlib.Path(str(dump) + '.sha256'), pathlib.Path(str(dump) + '.meta')]:
        regular(path, True)
    if pathlib.Path(str(dump) + '.sha256').read_text().split()[0] != digest(dump):
        fail('Dump checksum failed.')
    metadata = meta_read(pathlib.Path(str(dump) + '.meta'))
    if metadata.get('release') != release_id or metadata.get('api_image') != api_image or metadata.get('postgres_image') != postgres_image:
        fail('Dump, immutable release and pinned images do not match.')
    backup_root = safe_path(config['BACKUP_DIR'], 'backup directory')
    recovery_root = backup_root / 'recovery'
    if recovery_root.is_symlink():
        fail('Recovery directory must not be symlinked.')
    recovery_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if recovery_root.stat().st_uid != 0:
        fail('Recovery directory must be owned by root.')
    recovery_root.chmod(0o700)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S')
    name = config['CARTUNEZ_PROJECT'] + '-' + stamp + '-' + str(os.getpid())
    bundle = recovery_root / (name + '.partial')
    bundle.mkdir(mode=0o700)
    # Partial bundles are retained for inspection on failure and never announced as complete.
    shutil.copytree(release, bundle / 'release', symlinks=False)
    tools = bundle / 'recovery-tools'
    tools.mkdir(mode=0o700)
    for filename in ['recovery.py', 'recovery-restore.sh', 'recovery-export.sh', 'common.sh', 'backup.sh']:
        shutil.copyfile(pathlib.Path(__file__).parent / filename, tools / filename)
        (tools / filename).chmod(0o600)
    shutil.copyfile(args.config, bundle / 'private-config.json')
    shutil.copyfile(dump, bundle / 'database.dump')
    shutil.copyfile(str(dump) + '.meta', bundle / 'database.dump.meta')
    write_private(bundle / 'database.dump.sha256', digest(bundle / 'database.dump') + '  database.dump\n')
    for filename in ['private-config.json', 'database.dump', 'database.dump.meta']:
        (bundle / filename).chmod(0o600)
    run(['docker', 'image', 'inspect', api_image, postgres_image])
    run(['docker', 'image', 'save', '--output', str(bundle / 'images.tar'), api_image, postgres_image])
    (bundle / 'images.tar').chmod(0o600)
    manifest = dict(format=1, release=release_id, api_image=api_image, postgres_image=postgres_image,
                    source_project=config['CARTUNEZ_PROJECT'], created_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    scope='Database dump trio, private configuration, immutable release, and exact Docker image bytes; host Nginx/certificates remain separate.')
    write_private(bundle / 'manifest.json', json.dumps(manifest, indent=2) + '\n')
    write_private(bundle / 'SHA256SUMS', ''.join(digest(bundle / name) + '  ' + name + '\n' for name in files_in(bundle)))
    destination = recovery_root / name
    bundle.rename(destination)
    print('Complete private recovery bundle: ' + str(destination))
    print('Copy the entire directory to the existing access-controlled encrypted backup destination. It contains secrets; do not commit or publish it.')


def verify_bundle(root):
    if not root.is_dir() or root.is_symlink() or root.resolve() != root or root.stat().st_uid != 0 or root.stat().st_mode & 0o077:
        fail('Bundle must be a root-owned, mode-0700 directory without symlink traversal.')
    regular(root / 'SHA256SUMS', True)
    expected = {}
    for line in (root / 'SHA256SUMS').read_text().splitlines():
        match = re.fullmatch(r'([a-f0-9]{64})  (.+)', line)
        if not match:
            fail('Malformed bundle checksum list.')
        checksum, name = match.groups()
        path = pathlib.PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts or str(path) != name or name in expected or name == 'SHA256SUMS':
            fail('Unsafe or duplicate checksum path.')
        expected[name] = checksum
    actual = set(files_in(root)) - {'SHA256SUMS'}
    if actual != set(expected):
        fail('Bundle file inventory differs from its checksum manifest.')
    for name, checksum in expected.items():
        if digest(root / name) != checksum:
            fail('Bundle checksum failed for ' + name)
    for name in ['private-config.json', 'manifest.json', 'database.dump', 'database.dump.sha256', 'database.dump.meta', 'images.tar', 'release/compose.yaml', 'release/image-id', 'release/postgres-image-id', 'release/web/index.html', 'release/web/installation.json', 'recovery-tools/recovery.py', 'recovery-tools/recovery-restore.sh']:
        if name not in expected:
            fail('Recovery bundle is missing ' + name)
    manifest = json.loads((root / 'manifest.json').read_text())
    if manifest.get('format') != 1 or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,79}', manifest.get('release', '')) or '..' in manifest['release']:
        fail('Unsupported recovery manifest.')
    if image_id(root / 'release/image-id') != manifest['api_image'] or image_id(root / 'release/postgres-image-id') != manifest['postgres_image']:
        fail('Manifest image IDs differ from the immutable release.')
    metadata = meta_read(root / 'database.dump.meta')
    if any(metadata.get(key) != manifest[key] for key in ['release', 'api_image', 'postgres_image']):
        fail('Database and release metadata do not match.')
    if (root / 'database.dump.sha256').read_text().split()[0] != digest(root / 'database.dump'):
        fail('Database checksum sidecar does not match.')
    return manifest


def ensure_unused_project(project):
    for command in [['docker', 'ps', '-aq'], ['docker', 'volume', 'ls', '-q'], ['docker', 'network', 'ls', '-q']]:
        if run(command + ['--filter', 'label=com.docker.compose.project=' + project]):
            fail('Target Docker project already has resources; nothing may be overwritten.')
    if run(['docker', 'ps', '-aq', '--filter', 'name=^/' + project + '[-_]']):
        fail('Target container name prefix is already in use.')
    for kind, names in [('volume', [project + '_postgres_data']), ('network', [project + '_database', project + '_application'])]:
        existing = set(run(['docker', kind, 'ls', '--format', '{{.Name}}']).splitlines())
        if existing.intersection(names):
            fail('Target Docker resource names are already in use.')


def verify_compose(compose, env, config, manifest):
    model = json.loads(run(compose + ['config', '--format', 'json'], env))
    if set(model.get('services', {})) != {'api', 'postgres'} or set(model.get('volumes', {})) != {'postgres_data'} or set(model.get('networks', {})) != {'database', 'application'}:
        fail('Unexpected recovery Compose services or resources.')
    if model['volumes']['postgres_data'].get('name') != config['CARTUNEZ_PROJECT'] + '_postgres_data' or model['volumes']['postgres_data'].get('external'):
        fail('Recovery volume is not isolated to the target project.')
    for name, network in model['networks'].items():
        if network.get('name') != config['CARTUNEZ_PROJECT'] + '_' + name or network.get('external'):
            fail('Recovery network is not isolated to the target project.')
    for name, service in model['services'].items():
        if service.get('image') != manifest['api_image' if name == 'api' else 'postgres_image']:
            fail('Compose image differs from the archived pinned image.')
        if any(service.get(key) for key in ['privileged', 'container_name', 'network_mode', 'pid', 'ipc', 'devices', 'volumes_from', 'build', 'configs', 'secrets', 'entrypoint', 'command']):
            fail('Unsupported host-affecting recovery service configuration.')
        volumes = service.get('volumes', [])
        if name == 'api' and volumes:
            fail('API recovery must not mount host data.')
        if name == 'postgres' and (len(volumes) != 1 or volumes[0].get('type') != 'volume' or volumes[0].get('source') != 'postgres_data' or volumes[0].get('target') != '/var/lib/postgresql/data'):
            fail('PostgreSQL recovery must use only its fresh project volume.')
        ports = service.get('ports', [])
        if name == 'postgres' and ports:
            fail('Recovery database must not publish a host port.')
        if name == 'api' and (len(ports) != 1 or ports[0].get('host_ip') != '127.0.0.1' or str(ports[0].get('published')) != config['API_PORT'] or ports[0].get('target') != 4000):
            fail('Recovery API must publish only its chosen loopback port.')


def restore_bundle(args):
    bundle = pathlib.Path(args.bundle)
    manifest = verify_bundle(bundle)
    config = config_read(bundle / 'private-config.json')
    root = safe_path(args.root, 'application root')
    backup = safe_path(args.backup_dir, 'backup directory')
    acme = safe_path(args.acme_root, 'ACME directory')
    target_config = safe_path(args.config, 'private configuration', True)
    if not re.fullmatch(r'[a-z][a-z0-9]{2,30}', args.project) or not 1024 <= args.api_port <= 65535:
        fail('Invalid target project or loopback port.')
    lock_path = pathlib.Path('/run/lock/cartunez-cold-recovery-' + args.project + '.lock')
    lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    lock_info = os.fstat(lock_fd)
    if lock_info.st_uid != 0 or not stat.S_ISREG(lock_info.st_mode) or lock_info.st_mode & 0o077:
        fail('Unsafe recovery project lock.')
    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    restore_dump = pathlib.Path(args.dump) if args.dump else bundle / 'database.dump'
    if not restore_dump.is_absolute() or restore_dump.resolve() != restore_dump:
        fail('Replacement dump must be an absolute path without symlink traversal.')
    if args.dump:
        for path in [restore_dump, pathlib.Path(str(restore_dump) + '.sha256'), pathlib.Path(str(restore_dump) + '.meta')]:
            regular(path, True)
        if pathlib.Path(str(restore_dump) + '.sha256').read_text().split()[0] != digest(restore_dump):
            fail('Replacement dump checksum failed.')
        metadata = meta_read(pathlib.Path(str(restore_dump) + '.meta'))
        if any(metadata.get(key) != manifest[key] for key in ['release', 'api_image', 'postgres_image']):
            fail('Replacement dump must match this bundle release and exact images.')
    domain = args.domain or config['DOMAIN']
    if not re.fullmatch(r'[a-z0-9][a-z0-9.-]+\.[a-z]{2,}', domain):
        fail('Invalid target domain.')
    targets = [root, backup, acme, target_config]
    for path in targets:
        if path.exists():
            fail('Recovery target must not already exist: ' + str(path))
        if path == bundle or bundle in path.parents or path in bundle.parents:
            fail('Recovery targets must be separate from the bundle.')
        for other in targets:
            if other != path and (other in path.parents or path in other.parents):
                fail('Recovery target directories must not overlap.')
        ancestor = path.parent
        while not ancestor.exists():
            ancestor = ancestor.parent
        if ancestor.stat().st_uid != 0 or ancestor.stat().st_mode & 0o022:
            fail('Recovery paths must have root-owned, non-writable existing ancestors.')
        if path in [root, acme]:
            for directory in [ancestor, *ancestor.parents]:
                if not directory.stat().st_mode & 0o001:
                    fail('Public application/ACME paths require traversable existing parent directories; existing permissions will not be changed.')
    ensure_unused_project(args.project)
    with socket.socket() as connection:
        connection.bind(('127.0.0.1', args.api_port))
    config.update(CARTUNEZ_ROOT=str(root), CARTUNEZ_PROJECT=args.project, BACKUP_DIR=str(backup), ACME_ROOT=str(acme), API_PORT=str(args.api_port), DOMAIN=domain, BOOTSTRAP_OWNER_PASSWORD='')
    env = {**os.environ, **config, 'API_IMAGE': manifest['api_image'], 'POSTGRES_IMAGE': manifest['postgres_image']}
    for key in ['COMPOSE_FILE', 'COMPOSE_PROFILES', 'COMPOSE_PROJECT_NAME', 'DOCKER_HOST', 'DOCKER_CONTEXT']:
        env.pop(key, None)
    compose = ['docker', 'compose', '--env-file', '/dev/null', '-p', args.project, '-f', str(bundle / 'release/compose.yaml')]
    verify_compose(compose, env, config, manifest)
    print('Verified bundle checksums, image pins, target paths and project isolation. Loading archived images.')
    run(['docker', 'image', 'load', '--input', str(bundle / 'images.tar')])
    for expected in [manifest['api_image'], manifest['postgres_image']]:
        if run(['docker', 'image', 'inspect', '--format', '{{.Id}}', expected]) != expected:
            fail('Archived Docker image could not be loaded with its exact ID.')
    # All validations precede target file creation. No existing configuration or project is replaced.
    create_public_directory(root)
    backup.mkdir(parents=True, mode=0o700)
    create_public_directory(acme)
    target_config.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    write_private(target_config, json.dumps(config, indent=2) + '\n')
    releases = root / 'releases'
    releases.mkdir(mode=0o755)
    releases.chmod(0o755)
    release = releases / manifest['release']
    shutil.copytree(bundle / 'release', release)
    # These public installer hints belong to the new deployment location.
    installation = release / 'web/installation.json'
    installation.chmod(0o644)
    installation.write_text(json.dumps(dict(apiUrl='https://' + domain + '/api/v1', organizationId=config['BOOTSTRAP_ORG_ID'], branchId=config['BOOTSTRAP_BRANCH_ID'])) + '\n')
    installation.chmod(0o444)
    state = root / 'state'
    state.mkdir(mode=0o700)
    write_private(state / 'cold-recovery.json', json.dumps(dict(release=manifest['release'], source_project=manifest['source_project'], bundle=str(bundle), status='database-restore-pending'), indent=2) + '\n')
    (root / 'maintenance').touch(mode=0o600)
    compose = ['docker', 'compose', '--env-file', '/dev/null', '-p', args.project, '-f', str(release / 'compose.yaml')]
    ensure_unused_project(args.project)
    run(compose + ['up', '-d', '--wait', '--wait-timeout', '180', 'postgres'], env)
    with restore_dump.open('rb') as stream:
        run(compose + ['exec', '-T', 'postgres', 'pg_restore', '--exit-on-error', '--single-transaction', '--no-owner', '--no-privileges', '-U', config['POSTGRES_USER'], '-d', config['POSTGRES_DB']], env, stream)
    validation = run(compose + ['exec', '-T', 'postgres', 'psql', '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-U', config['POSTGRES_USER'], '-d', config['POSTGRES_DB'], '-c', "SELECT (SELECT count(*) FROM records WHERE kind='organization')||'|'||(SELECT count(*) FROM stock_ledger)||'|'||(SELECT count(*) FROM transactions);"], env)
    if not re.fullmatch(r'[1-9][0-9]*\|[0-9]+\|[0-9]+', validation):
        fail('Restored database did not contain the required application records. API remains stopped.')
    print('Database restored and checked before API startup. Starting the pinned API image.')
    try:
        run(compose + ['up', '-d', '--wait', '--wait-timeout', '180', 'api'], env)
        with urllib.request.urlopen('http://127.0.0.1:' + config['API_PORT'] + '/api/v1/health', timeout=10) as response:
            if json.load(response).get('status') != 'ok':
                fail('Recovered API health check failed.')
    except Exception:
        run(compose + ['stop', 'api'], env)
        raise
    (root / 'current').symlink_to(release)
    (state / 'cold-recovery.json').write_text(json.dumps(dict(release=manifest['release'], source_project=manifest['source_project'], status='restored-api-healthy', database_counts=validation, images_loaded=[manifest['api_image'], manifest['postgres_image']]), indent=2) + '\n')
    print('Cold recovery succeeded in new project ' + args.project + ' on loopback port ' + config['API_PORT'] + '.')
    print('Nginx, TLS, DNS and scheduled jobs were not changed. Keep counters paused; reconcile post-backup sales and outboxes, then configure the dedicated vhost separately and remove the maintenance marker when ready.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='operation', required=True)
    exporter = sub.add_parser('export')
    for flag in ['config', 'release', 'dump']:
        exporter.add_argument('--' + flag, required=True)
    restorer = sub.add_parser('restore')
    restorer.add_argument('bundle')
    for flag in ['config', 'root', 'backup-dir', 'acme-root', 'project']:
        restorer.add_argument('--' + flag, required=True)
    restorer.add_argument('--api-port', type=int, required=True)
    restorer.add_argument('--domain')
    restorer.add_argument('--dump', help='Optional newer dump trio matching this exact release and image pair.')
    args = parser.parse_args()
    if os.geteuid() != 0:
        fail('Run recovery operations as root.')
    if os.environ.get('DOCKER_HOST') or os.environ.get('DOCKER_CONTEXT'):
        fail('Unset DOCKER_HOST and DOCKER_CONTEXT; recovery operates only on the local Docker daemon.')
    if not run(['docker', 'context', 'inspect', '--format', '{{.Endpoints.docker.Host}}']).startswith('unix://'):
        fail('Recovery requires a local Unix-socket Docker context.')
    os.umask(0o077)
    export_bundle(args) if args.operation == 'export' else restore_bundle(args)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        message = str(error)
        for secret in PRIVATE_VALUES:
            if secret:
                message = message.replace(secret, '[redacted]')
        print('Recovery stopped: ' + message, file=sys.stderr)
        sys.exit(1)
