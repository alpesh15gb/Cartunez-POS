const assert = require('node:assert/strict');
const { randomBytes } = require('node:crypto');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { Pool } = require('pg');

async function createFreshEnvironment() {
  assert.ok(process.env.TEST_POSTGRES_URL, 'Set TEST_POSTGRES_URL for the isolated local freshqa_admin database.');
  const adminUrl = new URL(process.env.TEST_POSTGRES_URL);
  assert.equal(adminUrl.hostname, '127.0.0.1', 'This destructive-test guard permits only the isolated localhost database.');
  assert.equal(adminUrl.port, '5441');
  assert.equal(adminUrl.pathname, '/freshqa_admin', 'Never run fresh-install acceptance against a shop or demo database.');
  const root = path.resolve(__dirname, '..');
  const databaseName = `fresh_qa_${Date.now()}_${randomBytes(4).toString('hex')}`;
  const admin = new Pool({ connectionString: adminUrl.href });
  await admin.query(`CREATE DATABASE "${databaseName}"`);
  const databaseUrl = new URL(adminUrl);
  databaseUrl.pathname = '/' + databaseName;
  const credentials = {
    organizationId: 'freshqa', branchId: 'first', email: 'owner@fresh-acceptance.example',
    password: randomBytes(24).toString('base64url'),
  };
  const apiBase = 'http://127.0.0.1:4011/api/v1';
  const webBase = 'http://127.0.0.1:3011';
  const environment = {
    ...process.env, NODE_ENV: 'production', DATABASE_URL: databaseUrl.href,
    PORT: '4011', HOST: '127.0.0.1', SEED_DEMO: 'false', JWT_SECRET: randomBytes(32).toString('hex'),
    CORS_ORIGINS: `https://fresh-acceptance.example,${webBase}`, TRUST_PROXY_HOPS: '0',
    BOOTSTRAP_ORG_ID: credentials.organizationId, BOOTSTRAP_BRANCH_ID: credentials.branchId,
    BOOTSTRAP_ORG_NAME: 'Fresh Acceptance Shop', BOOTSTRAP_BRANCH_NAME: 'Fresh First Branch',
    BOOTSTRAP_OWNER_EMAIL: credentials.email, BOOTSTRAP_OWNER_PASSWORD: credentials.password,
    BOOTSTRAP_CURRENCY: 'INR',
  };
  let apiProcess;
  let apiLog = '';
  async function startApi() {
    apiProcess = spawn(process.execPath, [path.join(root, 'apps/api/dist/server.js')], {
      cwd: path.join(root, 'apps/api'), env: environment, windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    apiProcess.stdout.on('data', chunk => { apiLog = (apiLog + chunk).slice(-20000); });
    apiProcess.stderr.on('data', chunk => { apiLog = (apiLog + chunk).slice(-20000); });
    for (let attempt = 0; attempt < 80; attempt++) {
      if (apiProcess.exitCode !== null) throw new Error(`Isolated production API exited: ${apiLog}`);
      try {
        const response = await fetch(apiBase + '/health', { signal: AbortSignal.timeout(1000) });
        if (response.ok) {
          assert.equal((await response.json()).database, 'postgresql');
          return;
        }
      } catch {}
      await new Promise(resolve => setTimeout(resolve, 250));
    }
    throw new Error(`Isolated production API did not start: ${apiLog}`);
  }
  async function stopApi() {
    if (apiProcess && apiProcess.exitCode === null) {
      const stopped = new Promise(resolve => apiProcess.once('exit', resolve));
      apiProcess.kill();
      await stopped;
    }
  }
  const webDirectory = path.join(root, 'apps/web/out');
  const contentTypes = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.woff2': 'font/woff2' };
  const server = http.createServer((request, response) => {
    const pathname = decodeURIComponent(new URL(request.url, webBase).pathname);
    let file = path.resolve(webDirectory, '.' + pathname);
    if (file !== webDirectory && !file.startsWith(webDirectory + path.sep)) { response.writeHead(403).end(); return; }
    if (file === webDirectory || fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
    if (!fs.existsSync(file)) { response.writeHead(404).end(); return; }
    response.writeHead(200, { 'Content-Type': contentTypes[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    fs.createReadStream(file).pipe(response);
  });
  let webStarted = false;
  try {
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(3011, '127.0.0.1', resolve); });
    webStarted = true;
    await startApi();
  } catch (error) {
    await stopApi();
    if (webStarted) await new Promise(resolve => { server.closeAllConnections(); server.close(resolve); });
    await admin.query(`DROP DATABASE "${databaseName}"`);
    await admin.end();
    throw error;
  }
  return {
    credentials, apiBase, webBase, databaseName,
    restart: async () => { await stopApi(); await startApi(); },
    close: async () => {
      await stopApi();
      await new Promise(resolve => { server.closeAllConnections(); server.close(resolve); });
      assert.match(databaseName, /^fresh_qa_[0-9]+_[a-f0-9]+$/);
      await admin.query(`DROP DATABASE "${databaseName}"`);
      await admin.end();
    },
  };
}
module.exports = { createFreshEnvironment };
