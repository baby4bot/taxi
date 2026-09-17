# 📱 แอป Android (Taxi Meter 2026) — เปลือก WebView + บริการ GPS ฉากหลัง

โฟลเดอร์นี้คือ **แอป Android** ที่ “ห่อเว็บแอปจริง” (`https://baby4bot.github.io/taxi/`)
จุดขาย: **แก้ `index.html` บนเว็บ → ในแอปเห็นทันที ไม่ต้องออก APK ใหม่**
ออก APK ใหม่เฉพาะตอนแก้ **ชั้น Android** (สิทธิ์ · โค้ด Java ในโฟลเดอร์นี้ · ไอคอน)

---

## 🎯 ทำไมต้องมีแอป Android (ปัญหาที่มันแก้)

| ปัญหาเดิม | สาเหตุ | แอปนี้แก้ยังไง |
|---|---|---|
| ปิดจอ/ล็อกจอ/ยุบแอป แล้ว **เวลารถติดเพี้ยน** (เช่น 4:50 → 18:03) | เบราว์เซอร์ **แช่แข็งหน้าเว็บ + หยุดส่งพิกัด** เมื่อจอดับ ⇒ ช่วงนั้นแอปได้แต่ “เดา” | `BgLocationService` เป็น **Foreground Service** เก็บพิกัดต่อเนื่องแม้จอดับ แล้วเก็บเข้าคิวให้หน้าเว็บมาเบิก (`TaxiNative.drainFixes()`) |
| กดจอไม่ค้าง / Wake Lock ถูกปฏิเสธ | เบราว์เซอร์ต้องรอ “ผู้ใช้แตะจอก่อน” | แอปสั่ง `FLAG_KEEP_SCREEN_ON` ระดับระบบได้ (`TaxiNative.setKeepScreenOn`) |
| อัปโหลดรูป (จอโหลด/QR) กดแล้วเงียบใน WebView | WebView ต้องเขียน `onShowFileChooser` เอง | เขียนไว้แล้ว — เปิดตัวเลือกรูปมาตรฐาน (SAF) รองรับหลายรูป |
| พิกัดใช้ไม่ได้เลยใน WebView | ต้องอนุมัติผ่าน `onGeolocationPermissionsShowPrompt` | อนุมัติให้ origin ของแอปอัตโนมัติ |

---

## 🗂 ไฟล์สำคัญ

| ไฟล์ | หน้าที่ |
|---|---|
| `app/src/main/java/com/baby4bot/taximeter/MainActivity.java` | เปลือก WebView + ขอสิทธิ์ + ตัวเลือกรูป + สะพาน JS (`window.TaxiNative`) |
| `app/src/main/java/com/baby4bot/taximeter/BgLocationService.java` | Foreground Service เก็บพิกัด (GPS + เครือข่าย) เข้าคิวในหน่วยความจำ |
| `app/build.gradle` | ตั้งค่าแอป + **URL เว็บแอป** (`buildConfigField APP_URL`) + ลายเซ็น APK |
| `app/src/main/AndroidManifest.xml` | สิทธิ์ทั้งหมด (ตำแหน่ง · บริการเบื้องหน้า · สั่น · แจ้งเตือน) |
| `../../.github/workflows/build-apk.yml` | สร้าง APK บน GitHub (ไม่ต้องติดตั้ง JDK/Gradle ในเครื่อง) |

---

## 🚀 ขั้นตอนแรก: สร้าง APK ครั้งแรก (ทำครั้งเดียว)

1. อัปโฟลเดอร์นี้ + `.github/workflows/build-apk.yml` ขึ้นเรโป GitHub (`baby4bot/taxi`)
2. เข้า GitHub → แท็บ **Actions** → **Build Android APK** → **Run workflow**
3. รอ ~5–8 นาที → ดาวน์โหลด APK ได้จาก
   - **Releases → `apk-latest`** (ลิงก์ถาวร ใช้ตลอด) หรือ
   - **Actions → artifact `taxi-meter-apk`** (เก็บชั่วคราว)
4. **ตั้งกุญแจเซ็นแอปให้ถาวร** (สำคัญ! ไม่งั้นอัปเดตทับของเดิมไม่ได้)
   - ดาวน์โหลด artifact **`keystore-bootstrap`** (มี `keystore.jks.base64` + `keystore-password.txt`)
   - Repo → **Settings → Secrets and variables → Actions → New repository secret**
     - `KEYSTORE_BASE64` = ข้อความทั้งหมดในไฟล์ `keystore.jks.base64`
     - `KEYSTORE_PASSWORD` = รหัสในไฟล์ `keystore-password.txt`
   - **ลบ artifact `keystore-bootstrap` ทิ้ง** แล้วรันงานอีกครั้ง → APK จะเซ็นด้วยกุญแจเดิมตลอดไป
   - ⛔ ห้าม commit ไฟล์ `.jks` ขึ้นเรโปเด็ดขาด (`.gitignore` กันไว้แล้ว)

## 📲 ติดตั้งบนมือถือ

1. คัดลอกไฟล์ `.apk` ไปที่มือถือ (หรือโหลดจาก Releases บนมือถือโดยตรง)
2. แตะไฟล์ → อนุญาต **“ติดตั้งจากแหล่งที่ไม่รู้จัก”** ให้แอปที่เปิดไฟล์นั้น (Chrome/ไฟล์)
3. เปิดแอป → **อนุญาตตำแหน่ง** (เลือก “ขณะใช้งานแอป” ก็พอ) + **อนุญาตการแจ้งเตือน** (Android 13+)
4. ตอนเริ่มจับเที่ยวจะเห็น **ป้าย “กำลังบันทึกตำแหน่งเที่ยว”** บนแถบสถานะ = ระบบกำลังเก็บ GPS ฉากหลังอยู่

**อัปเดตแอป:** ถ้าแก้แค่เว็บ (`index.html`) → ไม่ต้องทำอะไร ปิด-เปิดแอปก็ได้ของใหม่
ถ้าแก้ชั้น Android → รัน Actions แล้วติดตั้งทับได้เลย (ลายเซ็นเดิม ไม่ต้องถอนก่อน)

---

## 🔌 สะพาน JS ที่หน้าเว็บเรียกได้ (`window.TaxiNative`)

| เมธอด | ใช้ทำอะไร |
|---|---|
| `isNativeApp()` / `platform()` / `appVersion()` / `androidSdk()` | ตรวจว่าเปิดในแอป Android + ดูเวอร์ชัน |
| `startTracking()` / `stopTracking()` / `isTracking()` | เริ่ม/หยุดเก็บพิกัดฉากหลัง (คืน `false` ถ้ายังไม่มีสิทธิ์ตำแหน่ง) |
| `drainFixes()` | **เบิกพิกัดที่เก็บไว้ทั้งหมด** (JSON array: `t, lat, lon, acc, spd, brg, prov`) แล้วล้างคิว |
| `peekStats()` | ดูสถานะคิว (ไม่ล้าง) — `{tracking, count, lastFixAt, now}` |
| `clearFixes()` | ล้างคิว (ไม่ควรเรียกกลางเที่ยว) |
| `setKeepScreenOn(on)` | บังคับจอค้างระดับระบบ |
| `hasLocationPermission()` / `requestLocationPermission()` / `openSystemAppSettings()` | จัดการสิทธิ์ |
| `vibrate(ms)` | สั่น (สำรองของ `navigator.vibrate`) |
| `reload()` | สั่งโหลดหน้าใหม่ |
| `getAppUrl()` / `setAppUrl(url)` | ดู/เปลี่ยน URL ที่โหลด — ใช้ทดสอบกับเซิร์ฟเวอร์ในเครื่อง เช่น `http://192.168.1.20:58911/` |

ตรวจสถานะจากหน้าเว็บได้ด้วย `window.taxiNativeDebug()` (ดูว่าบริการทำงานอยู่ไหม · เบิกพิกัดได้กี่จุด)

---

## ⚠️ ข้อจำกัดที่ต้องรู้ (จริงใจ)

1. **ล็อกอิน Google ใน WebView ถูก Google บล็อก** (`disallowed_useragent`) — เวอร์ชันนี้จะ **เด้งออกไปเบราว์เซอร์จริง** ให้
   ⇒ ในแอป Android ให้เข้าใช้ด้วย **ไอดี + รหัสผ่าน** หรือ **PIN** (ถ้าต้องการปุ่ม Google ในแอปจริง ๆ ต้องทำ
   **Native Google Sign-In** เพิ่ม: เอา `idToken` จากชั้น Android ส่งเข้า Firebase ฝั่งเว็บ — เป็นงานขั้นถัดไป ต้องใช้
   SHA-1 ของกุญแจเซ็นแอป + Web client ID)
2. **ต้องมีเน็ตครั้งแรก** เพื่อโหลดหน้าเว็บ (หลังจากนั้น `sw.js` เก็บสำรองไว้ให้เปิดแบบออฟไลน์ได้)
3. **แบต**: ระหว่างจับเที่ยวมี GPS + Wake Lock ⇒ ควรเสียบชาร์จในรถ (ออกแบบมาเพื่อแบบนั้นอยู่แล้ว)
4. **Play Store**: แอปที่ห่อเว็บเปล่า ๆ เสี่ยงถูกปฏิเสธ — ติดตั้งเองไม่มีปัญหา
   ถ้าจะขึ้น Play ควรขายจุดขายจริง (GPS ฉากหลัง · มิเตอร์ · บันทึกเที่ยวออฟไลน์) และต้องมี Privacy Policy
5. **แจ้งเตือน**: Android 13+ ถ้าไม่อนุญาตการแจ้งเตือน บริการยังทำงานแต่จะไม่เห็นป้ายบนแถบสถานะ

---

## 🛠 build ในเครื่อง (ถ้าอยาก ไม่บังคับ)

ต้องมี **JDK 17** + **Android SDK (platform 34)** — เครื่องที่ใช้ปัจจุบันมี SDK แต่ไม่มี JDK
⇒ ทางที่ง่ายคือติดตั้ง **Android Studio** แล้วเปิดโฟลเดอร์ `android-app` (กด Sync ให้ Android Studio สร้าง Gradle wrapper ให้)

```bash
# ทาง CLI (ต้องมี gradle/jdk ในเครื่อง)
cd android-app
gradle wrapper --gradle-version 8.7
./gradlew assembleRelease
# ไฟล์ออกที่ app/build/outputs/apk/release/app-release.apk
```

ตรวจไฟล์โปรเจกต์แบบไม่ต้อง build (มีแค่ PowerShell):
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ../.freebuff/check-android.ps1
```

---

## 🔜 ขั้นถัดไปที่ยังไม่ได้ทำ (ตั้งใจแยกไว้ให้ทดสอบทีละขั้น)

1. **ใช้พิกัดจากคิวคำนวณ “เวลารถติดจริง”** แทนค่าประมาณ — ตอนนี้หน้าเว็บเบิกพิกัดมาเก็บไว้แล้ว
   (`window.nativeFixes`) แต่ยังไม่ได้ป้อนเข้าสูตรมิเตอร์ (ต้องแก้ `estimateGapTrafficSec` + ชุดทดสอบออฟไลน์)
2. ปุ่มในแอป: “ตรวจสิทธิ์ · ดูจำนวนพิกัดที่เก็บได้”
3. Native Google Sign-In (ถ้าต้องการปุ่ม Google ในแอป)
4. อัปเดตอัตโนมัติ: เช็ค `buildStamp` บนเว็บแล้วสั่ง `reload()` เองเมื่อมีเวอร์ชันใหม่ (ปัจจุบันใช้ `sw.js` network-first ให้อยู่แล้ว)
