# 📱 แอป Android “ค่าแท็กซี่” — เปลือก WebView + บริการ GPS ฉากหลัง

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
| `app/src/main/AndroidManifest.xml` | สิทธิ์ทั้งหมด (ตำแหน่ง · บริการเบื้องหน้า · สั่น · แจ้งเตือน) + ตั้งไอคอน `@mipmap/ic_launcher` |
| `app/src/main/res/values/strings.xml` | **ชื่อที่โชว์ใต้ไอคอนบนมือถือ** (`app_name` = ค่าแท็กซี่) |
| `app/src/main/res/mipmap-*/ic_launcher*.png` | ไอคอนแอปทุกความละเอียด (สร้างจาก `tools/make-icons.ps1`) |
| `tools/make-icons.ps1` | สร้างไอคอนจากไฟล์รูปต้นฉบับ — เปลี่ยนรูปได้ด้วยคำสั่งเดียว (ดูหัวข้อถัดไป) |
| `../../.github/workflows/build-apk.yml` | สร้าง APK บน GitHub (ไม่ต้องติดตั้ง JDK/Gradle ในเครื่อง) |

---

## 🚀 ขั้นตอนแรก: สร้าง APK ครั้งแรก (ทำครั้งเดียว)

1. อัปโฟลเดอร์นี้ + `.github/workflows/build-apk.yml` ขึ้นเรโป GitHub (`baby4bot/taxi`)
2. เข้า GitHub → แท็บ **Actions** → **Build Android APK** → **Run workflow**
3. รอ ~5–8 นาที → ดาวน์โหลด APK ได้จาก
   - **Releases → `apk-latest`** (ลิงก์ถาวร ใช้ตลอด) หรือ
   - **Actions → artifact `taxi-meter-apk`** (เก็บชั่วคราว)
4. **กุญแจเซ็นแอปเป็นแบบถาวรแล้ว** (18 ก.ย. 2569 — ตั้งครั้งเดียว อัปเดตทับได้ตลอด ไม่ต้องถอนแอปเดิม)
   - ลายนิ้วมือที่ใช้อยู่: `74449ae235baf1ef2e668dae363230366f7d07dfe7f100962068f5cc934aefbe` (SHA-256)
     มาจาก artifact `keystore-bootstrap` ของงาน **build #8** = ดอกเดียวกับแอปที่ติดตั้งบนเครื่องผู้ใช้
   - Secrets ที่ต้องมีบน GitHub: `KEYSTORE_BASE64` + `KEYSTORE_PASSWORD`
     (ค่าต้นทางอยู่ที่ `.freebuff/signing-key/secret-KEYSTORE_BASE64.txt` และ `secret-KEYSTORE_PASSWORD.txt`)
   - ⛔ ห้าม commit ไฟล์กุญแจเด็ดขาด — โฟลเดอร์ `.freebuff/signing-key/` มี `.gitignore` = `*` กันไว้แล้ว
     และ `tests/pre-push.ps1` ข้อ 3c จะหยุดก่อน push ถ้าพบกุญแจอยู่ในเรโป
   - 🔒 **ด่านกันกุญแจเปลี่ยนดอก:** งาน build เทียบลายนิ้วมือของ APK กับ `android-app/signing-key-fingerprint.txt`
     → ไม่ตรง = **งานล้มทันที ไม่ปล่อย APK** (กันไฟล์ที่ติดตั้งทับของเดิมไม่ได้หลุดไปให้คนโหลด)
   - หลังตั้ง Secret แล้ว **ลบ artifact `keystore-bootstrap` ทิ้ง** (งานถัดไปจะไม่อัปโหลดกุญแจซ้ำอีก)
   - ถ้าต้องเปลี่ยนกุญแจจริง ๆ: แก้ `signing-key-fingerprint.txt` + ตั้ง Secret ใหม่พร้อมกัน
     และแจ้งว่าผู้ใช้ต้องถอนแอปเดิม **1 ครั้ง** แล้วกลับมาทับได้ตามปกติ

## 📥 ดึงไฟล์ APK ลงเครื่อง (วางไว้โฟลเดอร์เดียวกับ `index.html`)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File android-app/tools/fetch-apk.ps1
```

ได้ 2 ไฟล์ในโฟลเดอร์โปรเจกต์: **`ค่าแท็กซี่.apk`** (ตัวล่าสุด ทับของเดิมทุกครั้ง) และ **`ค่าแท็กซี่-info.txt`**
(ชื่อแอป · ไอคอนที่ฝังในไฟล์ · sha256 · เวลาสร้าง — CI เขียนจากในไฟล์ APK เอง เลยตรวจได้โดยไม่ต้องติดตั้ง)

> 📌 **กติกาของโปรเจกต์นี้:** ทุกครั้งที่ push งานที่แก้ “ชั้น Android” (โค้ด Java · manifest · ไอคอน · ชื่อแอป)
> ให้รอ CI build เสร็จแล้วรันสคริปต์นี้ทันที — ผู้ใช้จะได้ส่งไฟล์จากคอมเข้าเครื่องได้เลย โดยไม่ต้องเข้าไปโหลดในลิงก์
> (ลิงก์ Release ยังอัปเดตตามปกติ — สคริปต์นี้คือทางลัด ไม่ใช่ทางแทน)

### 🛡️ สคริปต์นี้ไม่ยอมทับไฟล์ที่ติดตั้งได้ ด้วยไฟล์ที่ติดตั้งไม่ได้

ก่อนทับ สคริปต์จะอ่าน `apk-info.txt` ของ Release แล้วดูว่าไฟล์นั้นเซ็นด้วย:

| สถานะของ APK ที่โหลดมา | สคริปต์ทำอะไร |
|---|---|
| กุญแจ **ถาวร** (มาจาก Secrets) หรือลายนิ้วมือตรงกับที่แอปผู้ใช้มีอยู่ | ทับให้ตามปกติ |
| กุญแจ **ชั่วคราว** (ยังไม่ได้ตั้ง Secrets) | **ไม่ทับ** · เก็บไฟล์เดิมไว้ · exit code 3 · บอกวิธีตั้ง Secrets |
| กุญแจคนละดอกกับที่ประกาศไว้ | **ไม่ทับ** (ติดตั้งทับจะขึ้นว่า “ติดตั้งไม่ได้”) |
| อ่านข้อมูลกุญแจไม่ได้ (Release รุ่นเก่า) | **ไม่ทับ** (ปลอดภัยไว้ก่อน) |
| ในโฟลเดอร์ยังไม่มีไฟล์ / ไฟล์เดิมเสียหาย | วางให้ตามปกติ (ไม่มีอะไรให้ปกป้อง) |

```powershell
powershell ... -File android-app/tools/fetch-apk.ps1            # ปกติ (มีด่านกัน)
powershell ... -File android-app/tools/fetch-apk.ps1 -SelfTest   # ทดสอบตรรกะ 7 เคส (ไม่ต้องมีเน็ต)
powershell ... -File android-app/tools/fetch-apk.ps1 -Force      # ทับเสมอ (ข้ามด่าน — ใช้เมื่อแน่ใจ)
```

**ทำไมต้องมี:** เคยเกิดจริง — ลิงก์ Release ชี้ไฟล์งาน #9 (กุญแจชั่วคราว) แต่ในโฟลเดอร์เป็นงาน #8 ที่ตรงกับแอป
ในเครื่องผู้ใช้ ⇒ ถ้าทับทันทีจะได้ไฟล์ที่ติดตั้งอัปเดตทับไม่ได้โดยไม่มีใครรู้ (APK 2 ไฟล์ versionCode เท่ากัน ตรวจด้วยตาก็ไม่รู้)

## 📲 ติดตั้งบนมือถือ

1. คัดลอกไฟล์ `.apk` ไปที่มือถือ (หรือโหลดจาก Releases บนมือถือโดยตรง)
2. แตะไฟล์ → อนุญาต **“ติดตั้งจากแหล่งที่ไม่รู้จัก”** ให้แอปที่เปิดไฟล์นั้น (Chrome/ไฟล์)
3. เปิดแอป → **อนุญาตตำแหน่ง** (เลือก “ขณะใช้งานแอป” ก็พอ) + **อนุญาตการแจ้งเตือน** (Android 13+)
4. ตอนเริ่มจับเที่ยวจะเห็น **ป้าย “กำลังบันทึกตำแหน่งเที่ยว”** บนแถบสถานะ = ระบบกำลังเก็บ GPS ฉากหลังอยู่

**อัปเดตแอป:** ถ้าแก้แค่เว็บ (`index.html`) → ไม่ต้องทำอะไร ปิด-เปิดแอปก็ได้ของใหม่
ถ้าแก้ชั้น Android → รัน Actions แล้วติดตั้งทับได้เลย (ลายเซ็นเดิม ไม่ต้องถอนก่อน)

---

## 🎨 เปลี่ยนชื่อแอป / ไอคอนแอป

**ชื่อใต้ไอคอน** แก้ที่ `app/src/main/res/values/strings.xml` → `<string name="app_name">`

**ไอคอน** สร้างจากไฟล์รูปต้นฉบับในเครื่องด้วยคำสั่งเดียว (ไม่ต้องติดตั้งโปรแกรมแต่งภาพ):

```powershell
cd android-app
powershell -NoProfile -ExecutionPolicy Bypass -File tools/make-icons.ps1
# ใช้รูปอื่น:  powershell ... -File tools/make-icons.ps1 -Source "C:\path\to\taxi.png"
```

สคริปต์จะสร้างให้ครบ 3 ชุด ทุกความละเอียด (mdpi/hdpi/xhdpi/xxhdpi/xxxhdpi):

| ไฟล์ | ใช้เมื่อไหร่ |
|---|---|
| `ic_launcher.png` | ไอคอนเหลี่ยม และเป็นตัวสำรองของ launcher รุ่นเก่า |
| `ic_launcher_round.png` | เครื่องที่ขอ **ไอคอนกลม** (`android:roundIcon`) |
| `ic_launcher_foreground.png` | ชั้นหน้าของ **adaptive icon** (Android 8+) — launcher จะตัดเป็นวงกลม/มุมมนเอง |

> 📌 ไอคอนที่ใช้อยู่ตอนนี้สร้างจาก **รูปรถแท็กซี่พื้นเขียว (ไม่มีตัวหนังสือ)** — คำสั่งที่ใช้จริงบันทึกไว้ใน `.freebuff/run.md`

> 💡 **ทำไมข้อความ “ZOOM!” / “SPEED!” ในรูปถึงหายไป:** adaptive icon จะเห็นเฉพาะส่วนกลางของภาพ
> (launcher ตัดขอบเอง) ⇒ รถอยู่กลางจอพอดี ข้อความริมขอบถูกตัดออกอัตโนมัติ ถ้าอยากให้เห็นทั้งภาพต้องใช้รูปที่จัดวาง
> องค์ประกอบไว้กลางจอ

ดูการจำลองหน้าตาก่อนติดตั้งจริงได้ที่ `.freebuff/icon-check.html` (เปิดในพรีวิว)

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

1. **ล็อกอิน Google ในแอปทำไม่ได้ — และตอนนี้บอกตรง ๆ แล้ว (แก้ 18 ก.ย. 69)**

   **อาการที่ผู้ใช้รายงาน:** กดปุ่ม Google ในแอป → เลือกอีเมล → **ขึ้น error / ไม่เข้าแอป**

   **ทำไม:** Google ห้ามหน้า OAuth ใน WebView (`disallowed_useragent`) · และโค้ดเดิมส่ง URL นั้น **ออกไปเบราว์เซอร์จริง**
   ⇒ ล็อกอินสำเร็จใน Chrome แต่ **เซสชันไม่กลับเข้าแอป** (เบราว์เซอร์กับแอปเป็นคนละพื้นที่จัดเก็บ)

   **พฤติกรรมปัจจุบัน:** ในแอป Android ปุ่ม Google และปุ่ม “ผูกบัญชี Google” → **เทา กดไม่ได้** + ข้อความแนะนำให้ใช้
   **ไอดี + รหัสผ่าน หรือ PIN** (ใช้ได้จริง) · ต้องการ Google ให้เปิดเว็บ `baby4bot.github.io/taxi` ใน Chrome
   · ในเบราว์เซอร์ปกติยังใช้ Google ได้เหมือนเดิม

   **ถ้าจะให้ Google ใช้ได้ในแอปจริง ๆ (งานขั้นถัดไป):** ทำ **native Google Sign-In**
   1. Firebase Console → Project settings → **Add app → Android**
      · Package name: `com.baby4bot.taximeter`
      · SHA-1: `89:44:CC:82:26:8E:09:D6:85:FB:4D:9A:91:96:50:F3:70:A1:DA:00` (ของกุญแจเซ็นแอป · ตรงกับแอปที่ติดตั้งอยู่)
   2. เลือกใช้ `GoogleSignInOptions … requestIdToken(<Web client ID>)` ใน `MainActivity` (Web client ID มีอยู่ใน `firebaseConfig` แล้ว)
      ⇒ ไม่จำเป็นต้องใช้ `google-services.json`
   3. เพิ่มสะพาน `TaxiNative.googleSignIn()` → ส่ง `idToken` กลับเข้า JS → `signInWithCredential(auth, GoogleAuthProvider.credential(idToken))`
   4. ออก APK ใหม่ 1 ครั้ง (แก้ชั้น Android = ต้องติดตั้งใหม่ — เว็บยังอัปเดตเองได้ตามปกติ)

   ⛔ ห้ามเปิดปุ่ม Google ในแอปกลับก่อนที่ข้อ 1–3 จะเสร็จ — ไม่งั้นผู้ใช้จะกลับไปเจอทางตันเดิม
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
