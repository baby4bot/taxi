/* Taxi Meter — Service Worker (PWA)
   - ทำให้ Chrome/Android ส่ง beforeinstallprompt (ปุ่มติดตั้งแอปเต็มจอ) ได้
   - กัน "แคชเก่าค้าง": GitHub Pages สั่งให้เบราว์เซอร์เก็บไฟล์ได้ถึง ~10 นาที
     → ขอไฟล์จากเน็ตทุกครั้ง (cache:'no-store' ข้ามแคช HTTP) เวอร์ชันใหม่จะโผล่ทันทีหลัง deploy
   - สำรองจาก cache เฉพาะตอนออฟไลน์ */
const CACHE = 'taxi-meter-v2';

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
      // no-store = ไม่เชื่อแคช HTTP เก่า → เปิดทีไรได้เวอร์ชันใหม่สุดจาก GitHub Pages เสมอ
      const fresh = await fetch(req, { cache: 'no-store' });
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
