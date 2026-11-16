// Retires the service worker left by the previous (Next.js) web app.
// Browsers check /sw.js for updates on each visit; this version clears the old
// offline cache, unregisters itself and reloads open tabs onto the new app.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter((key) => key.startsWith('motorline-')).map((key) => caches.delete(key)));
    await self.registration.unregister();
    const tabs = await self.clients.matchAll({ type: 'window' });
    tabs.forEach((tab) => tab.navigate(tab.url));
  })());
});
