const assert = require('node:assert/strict');
const { execFile } = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

// This resets only a disposable, newly installed release APK on an emulator.
// Preserve any earlier test outbox before replacing a differently signed APK.
const [adb, acknowledgement] = process.argv.slice(2);
assert.equal(acknowledgement, '--fresh-installed-emulator', 'Explicit fresh-emulator acknowledgement required. Never use this test on a physical counter.');
const serial = process.env.ANDROID_TEST_SERIAL || 'emulator-5558';
assert.match(serial, /^emulator-[0-9]+$/);
const output = path.resolve(__dirname, '../docs/test-results');
const run = (args, input, allowFailure = false) => new Promise((resolve, reject) => {
  const child = execFile(adb, ['-s', serial, ...args], { encoding: 'utf8', windowsHide: true, maxBuffer: 8 * 1024 * 1024 }, (error, stdout, stderr) => {
    if (error && !allowFailure) reject(new Error(`${args.slice(0, 3).join(' ')}: ${stderr || stdout}`));
    else resolve({ stdout, stderr, code: error?.code || 0 });
  });
  child.stdin.end(input);
});
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const dump = async () => {
  await run(['shell', 'uiautomator', 'dump', '/sdcard/motorline-release-test.xml']);
  return (await run(['shell', 'cat', '/sdcard/motorline-release-test.xml'])).stdout;
};
const nodes = xml => [...xml.matchAll(/<node\b[^>]*>/g)].map(match => Object.fromEntries([...match[0].matchAll(/([\w-]+)="([^"]*)"/g)].map(item => [item[1], item[2]])));
const tap = async node => {
  assert.ok(node, 'Expected a visible native UI control.');
  const [left, top, right, bottom] = node.bounds.match(/\d+/g).map(Number);
  await run(['shell', 'input', 'tap', String(Math.round((left + right) / 2)), String(Math.round((top + bottom) / 2))]);
};

(async () => {
  const requests = [];
  const server = http.createServer((request, response) => {
    requests.push({ method: request.method, path: request.url });
    response.writeHead(200, { 'Content-Type': 'application/json', Connection: 'close' });
    response.end('{"probe":true}');
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(4021, '127.0.0.1', resolve); });
  try {
    let xml = await dump();
    assert.match(xml, /Open your workspace/);
    const apiField = nodes(xml).find(node => node.class === 'android.widget.EditText' && node.hint === 'Server API');
    assert.equal(apiField.text, 'https://pos.cartunez.in/api/v1');
    for (const hint of ['Organization code', 'Email', 'Password', 'Branch code']) assert.equal(nodes(xml).find(node => node.class === 'android.widget.EditText' && node.hint === hint).text, '');
    const pid = (await run(['shell', 'pidof', 'com.motorline.pos'])).stdout.trim().split(' ')[0];
    assert.ok(pid);
    const sockets = (await run(['shell', 'cat', '/proc/net/unix'])).stdout;
    const deviceBuildType = (await run(['shell', 'getprop', 'ro.build.type'])).stdout.trim();
    const systemDebuggable = (await run(['shell', 'getprop', 'ro.debuggable'])).stdout.trim() === '1';
    const webViewDebuggingExposed = sockets.split('\n').some(line => line.trim().endsWith(`@webview_devtools_remote_${pid}`));
    // Chromium forces WebView debugging on userdebug/eng OS images even when the
    // application explicitly disables it. Production user builds may not expose it.
    if (webViewDebuggingExposed) assert.ok(systemDebuggable && ['userdebug', 'eng'].includes(deviceBuildType), 'A production user build must not expose release WebView CDP.');
    const runAs = await run(['shell', 'run-as', 'com.motorline.pos', 'id'], undefined, true);
    assert.notEqual(runAs.code, 0);
    assert.match(runAs.stdout + runAs.stderr, /not debuggable/);

    const probe = await run(['shell', '-T', "printf 'GET /reachability-probe HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n' | toybox nc -w 3 10.0.2.2 4021"]);
    assert.match(probe.stdout, /200 OK/);
    assert.equal(requests.length, 1, 'The emulator must reach the HTTP probe before testing its application policy.');
    const values = { 'Server API': 'http://10.0.2.2:4021/api/v1', 'Organization code': 'probe', Email: 'probe@example.test', Password: 'ReleaseHttpProbe2026', 'Branch code': 'probe' };
    for (const [hint, value] of Object.entries(values)) {
      xml = await dump();
      await tap(nodes(xml).find(node => node.class === 'android.widget.EditText' && node.hint === hint));
      await run(['shell', 'input', 'keycombination', '113', '29']);
      await run(['shell', 'input', 'text', value]);
      await run(['shell', 'input', 'keyevent', '4']);
    }
    xml = await dump();
    for (const [hint, value] of Object.entries(values)) if (hint !== 'Password') assert.equal(nodes(xml).find(node => node.class === 'android.widget.EditText' && node.hint === hint).text, value);
    await tap(nodes(xml).find(node => node.class === 'android.widget.Button' && node.text === 'Sign in'));
    await pause(600);
    xml = await dump();
    assert.match(xml, /Failed to fetch|Network error|HTTPS required/i);
    assert.equal(requests.length, 1, 'Release login must not send cleartext HTTP, even to a reachable local server.');
    const log = (await run(['logcat', '-d', '--pid', pid])).stdout;
    const policyEvidence = /Mixed Content|ERR_CLEARTEXT_NOT_PERMITTED|insecure resource|blocked.*HTTP|must use HTTPS/i.test(log);
    // Release WebView builds may omit console diagnostics from logcat. The
    // reachable endpoint received no login request and the UI reported failure.

    // Only this fresh, unauthenticated emulator app is reset; no real counter is touched.
    await run(['shell', 'pm', 'clear', 'com.motorline.pos']);
    await run(['shell', 'am', 'start', '-n', 'com.motorline.pos/.MainActivity']);
    await pause(500);
    xml = await dump();
    assert.match(xml, /https:\/\/pos\.cartunez\.in\/api\/v1/);
    fs.mkdirSync(output, { recursive: true });
    await run(['shell', 'screencap', '-p', '/sdcard/motorline-release-login.png']);
    await run(['pull', '/sdcard/motorline-release-login.png', path.join(output, 'android-release-login.png')]);
    fs.writeFileSync(path.join(output, 'android-release-smoke.json'), JSON.stringify({ passed: true, environment: 'Fresh Android API 36 emulator install; release-signed APK', applicationId: 'com.motorline.pos', defaultApi: 'https://pos.cartunez.in/api/v1', apiAddressEditable: true, webViewDebuggingExposed, deviceBuildType, systemDebuggable, emulatorDebuggingLimitation: webViewDebuggingExposed ? 'Chromium forces WebView debugging on userdebug OS images despite the application disabling it; repeat no-CDP runtime check on a production user build.' : null, packageDebuggable: false, emulatorHttpProbeReachable: true, cleartextLoginRequestBlocked: true, cleartextPolicyLogged: policyEvidence, authenticatedUserDataCreated: false, remaining: ['Live public HTTPS login and enrollment after VPS deployment', 'No-CDP runtime check on an Android user build', 'Physical scanner and printer validation'] }, null, 2) + '\n');
    console.log('PASS Android release install: production HTTPS default, editable server, non-debuggable package, and cleartext HTTP blocked; userdebug OS WebView limitation recorded.');
  } finally { await new Promise(resolve => { server.closeAllConnections(); server.close(resolve); }); }
})().catch(error => { console.error(error); process.exitCode = 1; });
