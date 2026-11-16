import { readdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
async function paths(dir, base = '') {
  const result = [];
  for (const item of await readdir(dir, { withFileTypes: true })) {
    const relative = `${base}/${item.name}`;
    if (item.isDirectory()) result.push(...await paths(join(dir, item.name), relative));
    else if (!relative.endsWith('.map') && relative !== '/sw.js') result.push(relative);
  }
  return result;
}
const assets = await paths('out');
const version = `motorline-${Date.now()}`;
await writeFile('out/sw.js', `const CACHE=${JSON.stringify(version)};const ASSETS=${JSON.stringify(['/', ...assets])};
self.addEventListener('install',event=>event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(ASSETS)).then(()=>self.skipWaiting())));
self.addEventListener('activate',event=>event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(key=>key.startsWith('motorline-')&&key!==CACHE).map(key=>caches.delete(key)))).then(()=>self.clients.claim())));
self.addEventListener('fetch',event=>{const url=new URL(event.request.url);if(event.request.method!=='GET'||url.origin!==location.origin||url.pathname.startsWith('/api/'))return;event.respondWith(caches.open(CACHE).then(async cache=>{const cached=await cache.match(event.request);if(cached)return cached;try{return await fetch(event.request)}catch(error){if(event.request.mode==='navigate')return cache.match('/');throw error}}))});`);
console.log(`Cached ${assets.length} assets for offline startup`);
