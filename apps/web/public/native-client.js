(function () {
  'use strict';
  if (window.motorlineNative || !window.Capacitor || !window.Capacitor.isNativePlatform()) return;
  const call = (method, options = {}) => window.Capacitor.nativePromise('MotorlineNative', method, options);
  window.motorlineNative = Object.freeze({
    platform: 'android',
    async get(key) { return (await call('get', { key })).value ?? null; },
    async set(key, value) { await call('set', { key, value }); },
    async remove(key) { await call('remove', { key }); },
    async scan() { return (await call('scan')).value ?? null; },
    async print() { await call('print'); }
  });
})();
