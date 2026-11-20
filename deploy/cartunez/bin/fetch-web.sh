#!/usr/bin/env bash
# Downloads the Flutter web bundle that CI built for one exact commit and
# unpacks it into a new directory. CI publishes it as the GitHub Release
# "web-<full commit SHA>" with two assets: cartunez-web.tar.gz and its .sha256.
#
# Checks: the sidecar SHA-256, GitHub's own recorded asset digest when present,
# that the archive holds only regular files and directories under web/, and
# that its build-info.json names the same commit.
#
# Private repository: put a fine-grained GitHub token with read-only "Contents"
# access to this one repository in /etc/cartunez-pos/github-token (root-owned,
# mode 0600). It is sent only to api.github.com, never on the command line.
set -euo pipefail
umask 077
die() { printf '%s\n' "$*" >&2; exit 1; }
[[ $# -eq 2 ]] || die 'Usage: fetch-web.sh FULL_COMMIT_SHA /absolute/new/directory'
commit="$1"; dest="$2"
[[ "$commit" =~ ^[a-f0-9]{40}$ ]] || die 'Pass the full 40-character commit SHA.'
[[ "$dest" = /* && "$dest" != */ && ! -e "$dest" && -d "$(dirname "$dest")" ]] || die 'Destination must be a new absolute path in an existing directory.'
repo='alpesh15gb/Cartunez-POS'
api="https://api.github.com/repos/$repo"
asset='cartunez-web.tar.gz'
token_file="${CARTUNEZ_GITHUB_TOKEN_FILE:-/etc/cartunez-pos/github-token}"

work="$(mktemp -d "$(dirname "$dest")/.web-fetch.XXXXXX")"
trap 'rm -rf "$work"' EXIT
headers="$work/headers"
printf 'User-Agent: cartunez-pos-deploy\nX-GitHub-Api-Version: 2022-11-28\n' > "$headers"
if [[ -e "$token_file" ]]; then
  [[ -f "$token_file" && ! -L "$token_file" && "$(stat -c '%u %a' "$token_file")" = '0 600' ]] \
    || die "$token_file must be a root-owned regular file with mode 0600."
  token="$(tr -d '[:space:]' < "$token_file")"
  [[ "$token" =~ ^[A-Za-z0-9_]{20,255}$ ]] || die "$token_file does not hold a GitHub token."
  printf 'Authorization: Bearer %s\n' "$token" >> "$headers"
  unset token
fi
# curl drops headers given with -H when a redirect leaves api.github.com, so the
# token never reaches the asset storage host that serves the download.
get() { curl --silent --show-error --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 20 -H @"$headers" "$@"; }

code="$(get --max-time 60 -H 'Accept: application/vnd.github+json' -o "$work/release.json" -w '%{http_code}' "$api/releases/tags/web-$commit")" \
  || die 'Could not reach api.github.com.'
case "$code" in
  200) ;;
  404) die "No CI web bundle is published for commit $commit yet (release web-$commit).
Wait for the 'Build and test' run on main to finish for this commit, then rerun with 'prepare'.
If the repository is private, also check $token_file." ;;
  401|403) die "GitHub refused the request (HTTP $code). Check $token_file or the API rate limit." ;;
  *) die "GitHub returned HTTP $code for release web-$commit." ;;
esac

# Prints: archive-url archive-digest sidecar-url (digest is '-' when GitHub has none).
read -r archive_url archive_digest sidecar_url < <(python3 - "$work/release.json" "$asset" <<'PY'
import json, re, sys
release = json.load(open(sys.argv[1])); name = sys.argv[2]
assets = {a['name']: a for a in release.get('assets', [])}
if name not in assets or name + '.sha256' not in assets:
    sys.exit('The release is missing ' + name + ' or its .sha256 file.')
def url(a):
    u = a['url']
    if not re.fullmatch(r'https://api\.github\.com/repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/assets/[0-9]+', u):
        sys.exit('Unexpected asset URL.')
    return u
digest = assets[name].get('digest') or ''
digest = digest[7:] if re.fullmatch(r'sha256:[a-f0-9]{64}', digest) else '-'
print(url(assets[name]), digest, url(assets[name + '.sha256']))
PY
) || die 'Could not read the release asset list.'
sidecar_url="${sidecar_url:-}"; sidecar_url="${sidecar_url%$'\r'}"
[[ -n "$sidecar_url" ]] || die 'Could not read the release asset list.'

get --fail --max-time 900 -H 'Accept: application/octet-stream' -o "$work/$asset" "$archive_url" || die 'Downloading the web bundle failed.'
get --fail --max-time 60 -H 'Accept: application/octet-stream' -o "$work/$asset.sha256" "$sidecar_url" || die 'Downloading the checksum failed.'
read -r expected _ < "$work/$asset.sha256"
[[ "$expected" =~ ^[a-f0-9]{64}$ ]] || die 'Invalid checksum file.'
actual="$(sha256sum "$work/$asset")"; actual="${actual%% *}"
[[ "$actual" = "$expected" ]] || die "Web bundle checksum mismatch (expected $expected, got $actual)."
[[ "$archive_digest" = - || "$archive_digest" = "$actual" ]] || die 'Web bundle does not match the digest GitHub recorded at upload.'

mkdir "$work/unpacked"
python3 - "$work/$asset" "$work/unpacked" "$commit" <<'PY'
import json, pathlib, sys, tarfile
archive, target, commit = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3]
with tarfile.open(archive, 'r:gz') as tar:
    members = tar.getmembers()
    for m in members:
        parts = pathlib.PurePosixPath(m.name).parts
        if m.name.startswith('/') or '..' in parts or not parts:
            sys.exit('Unsafe path in web bundle: ' + m.name)
        if not (m.isfile() or m.isdir()):
            sys.exit('Web bundle may hold only regular files and directories: ' + m.name)
        if parts[0] not in ('web', 'build-info.json'):
            sys.exit('Unexpected entry in web bundle: ' + m.name)
    tar.extractall(target, members=members, filter='data')
info = json.loads((target / 'build-info.json').read_text())
if info.get('commit') != commit:
    sys.exit('Web bundle was built from %s, not %s.' % (info.get('commit'), commit))
print('CI web bundle for %s (Flutter %s, built %s).' % (commit[:12], info.get('flutter', '?'), info.get('built_at', '?')))
PY
[[ -d "$work/unpacked/web" ]] || die 'Web bundle has no web/ directory.'
chmod -R u+rwX,go+rX "$work/unpacked/web"
mv "$work/unpacked/web" "$dest"
printf '%s  %s\n' "$actual" "$asset" > "$dest.sha256"
