#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
[[ "${1:-}" = --owner-login-verified ]] || die 'After verifying owner login and changing the password, run finish-bootstrap.sh --owner-login-verified'
load_release "$(current_release)"; lock
python3 - "$CARTUNEZ_CONFIG" <<'PY'
import json,os,pathlib,sys,tempfile
p=pathlib.Path(sys.argv[1]); config=json.loads(p.read_text());config['BOOTSTRAP_OWNER_PASSWORD']=''
fd,name=tempfile.mkstemp(prefix='.config-',dir=p.parent)
with os.fdopen(fd,'w') as f: json.dump(config,f,indent=2); f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(name,p)
login=p.parent/'owner-login.txt'
if login.is_file() and not login.is_symlink():login.unlink()
PY
export BOOTSTRAP_OWNER_PASSWORD=''
compose up -d --no-deps --wait --wait-timeout 180 api
health
printf 'Removed the bootstrap password from host configuration and recreated only this API container.\n'
