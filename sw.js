/* Taxi Meter — Service Worker (PWA)
   Chrome/Android จะส่ง beforeinstallprompt (ปุ่มติดตั้งแอปเต็มจอ) ต่อเมื่อมี service worker + manifest
   กลยุทธ์: network-first (ไฟล์เปลี่ยนทุกครั้งที่ deploy) → สำรองจาก cache ตอนออฟไลน์ */
const CACHE = 'taxi-meter-v1';

self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  let url;
  try { url = new URL(req.url); } catch (err) { return; }
  // ขอเฉพาะไฟล์ของเว็บเราเอง (ปล่อยให้ API/CDN/Firebase/TomTom ทำงานปกติ)
  if (url.origin !== self.location.origin) return;

  e.respondWith((async () => {
    try {
      const fresh = await fetch(req);
      const cache = await caches.open(CACHE);
      cache.put(req, fresh.clone()).catch(() => {});
      return fresh;
    } catch (err) {
      const cached = await caches.match(req);
      if (cached) return cached;
      if (req.mode === 'navigate') {
        const idx = await caches.match('./index.html');
        if (idx) return idx;
      }
      throw err;
    }
  })());
});
