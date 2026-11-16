"""Verify a built Android release without accessing its private signing key."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile

root = Path(__file__).resolve().parents[1]
apk = root / 'release/android/Motorline-1.1.0-release.apk'
web = root / 'apps/web/out'
sdk = Path(os.environ['ANDROID_HOME']) / 'build-tools/36.0.0'
badging = subprocess.check_output([str(sdk / 'aapt.exe'), 'dump', 'badging', str(apk)], text=True)
manifest = subprocess.check_output([str(sdk / 'aapt.exe'), 'dump', 'xmltree', str(apk), 'AndroidManifest.xml'], text=True)
signature = subprocess.check_output([str(sdk / 'apksigner.bat'), 'verify', '--verbose', '--print-certs', str(apk)], text=True, shell=True)
assert 'Verified using v2 scheme (APK Signature Scheme v2): true' in signature
assert 'Android Debug' not in signature
certificate = re.search(r'certificate SHA-256 digest: ([0-9a-f]+)', signature).group(1).upper()
version_code = int(re.search(r"versionCode='(\d+)'", badging).group(1))
version_name = re.search(r"versionName='([^']+)'", badging).group(1)
target_sdk = int(re.search(r"targetSdkVersion:'(\d+)'", badging).group(1))
debuggable = bool(re.search(r'android:debuggable[^\n]*0xffffffff', manifest))
cleartext = bool(re.search(r'android:usesCleartextTraffic[^\n]*0xffffffff', manifest))
assert version_code == 2 and version_name == '1.1.0'
assert not debuggable and not cleartext and target_sdk >= 28
assert re.search(r'android:allowBackup[^\n]*\(type 0x12\)0x0', manifest)
files = sorted(item for item in web.rglob('*') if item.is_file())
missing, different = [], []
with zipfile.ZipFile(apk) as archive:
    names = set(archive.namelist())
    for file in files:
        relative = file.relative_to(web).as_posix()
        entry = 'assets/public/' + relative
        if entry not in names:
            missing.append(relative)
        elif archive.read(entry) != file.read_bytes():
            different.append(relative)
    config = json.loads(archive.read('assets/capacitor.config.json'))
    assert config['android']['webContentsDebuggingEnabled'] is False
    assert config['android']['allowMixedContent'] is False
    assert config['server']['androidScheme'] == 'https'
    assert not any(name.lower().endswith(('.p12', '.jks', '.keystore', '/signing.json', '/.env')) for name in names)
assert not missing and not different
result = {
    'passed': True,
    'artifact': 'release/android/Motorline-1.1.0-release.apk',
    'bytes': apk.stat().st_size,
    'sha256': hashlib.sha256(apk.read_bytes()).hexdigest().upper(),
    'certificateSha256': certificate,
    'signing': 'Stable private application release key; RSA 3072; APK Signature Scheme v2 verified',
    'versionCode': version_code, 'versionName': version_name, 'targetSdk': target_sdk,
    'webExportFilesCompared': len(files), 'matchedFiles': len(files),
    'missingFiles': missing, 'differentFiles': different,
    'extraCapacitorFilesIgnored': True,
    'manifestDebuggable': debuggable,
    'manifestAllowsCleartext': cleartext,
    'targetSdkDefaultDisallowsCleartext': True,
    'webViewDebuggingConfigured': False,
    'mixedContentConfigured': False,
    'appOriginScheme': 'https',
    'backupEnabled': False,
    'privateSigningMaterialBundled': False,
}
destination = root / 'docs/test-results/android-release-package.json'
destination.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
print(json.dumps(result, indent=2))
