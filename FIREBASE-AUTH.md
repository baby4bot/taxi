# 🔑 ทำ Firebase Authentication ให้สมบูรณ์ — คู่มือทีละขั้น

คู่มือนี้สอน **ตั้งแต่ต้นจนจบ** ว่าทำไม `firestore.rules` ปิดช่องไม่สนิท และจะปิดให้สนิทได้อย่างไร
เขียนจากโค้ดจริงของโปรเจกต์นี้ (ไม่ใช่ตัวอย่างลอย ๆ) — ทุกชื่อตัวแปร ชื่อคอลเลกชัน และบรรทัดอ้างอิง
มาจาก [`index.html`](index.html) ของแท็กซี่แอปนี้โดยตรง

> 📌 อ่าน [`SECURITY.md`](SECURITY.md) ก่อน ถ้ายังไม่ได้วาง [`firestore.rules`](firestore.rules)

---

## 0. ปัญหาจริงคืออะไร (อ่านก่อน 2 นาที)

กติกา Firestore ตัดสินใจได้จาก **2 อย่างเท่านั้น**

| ตัวแปรในกติกา | ความหมาย | สถานะในแอปนี้ |
|---|---|---|
| `request.auth` | "หลักฐานตัวตน" ของคนที่ยิงคำขอมา | **ว่างเปล่าเสมอ** — แอปไม่ได้ล็อกอิน Firebase |
| `request.resource.data` | ข้อมูลที่กำลังจะเขียน | ใช้ได้ (กติกาปัจจุบันใช้ตัวนี้) |

การล็อกอินของแอปตอนนี้เป็นแบบ **ตรวจเองฝั่งเครื่อง**:

```
ผู้ใช้พิมพ์ username + รหัสผ่าน
   → แอปอ่าน doc จาก users/<docId> (อ่านได้โดยใครก็ได้)
   → เทียบรหัสผ่านกับแฮช PBKDF2 ใน doc นั้น (pwVerify)
   → ถ้าตรง = เข้าแอป
```

รหัสผ่านถูกต้องก็จริง แต่ **Firestore ไม่รู้เรื่องนี้เลย** — พอมันมองไม่เห็น "ตัวตน"
กติกาจึงเขียนได้แค่ "ห้ามลบ" / "จำกัดรูปแบบข้อมูล" ไม่สามารถเขียนว่า *"อ่านได้เฉพาะเจ้าของบัญชี"* ได้

**เป้าหมายของคู่มือนี้:** ทำให้ `request.auth` มีค่า → แล้วกติกาจะกลายเป็นของจริงทันที เช่น

```
allow read, write: if request.auth != null && request.auth.uid == uid;
```

---

## 1. เลือกแนวทาง (ตัดสินใจก่อนลงมือ)

| | ต้องมีอะไร | ปิดช่องได้แค่ไหน | งานฝั่งแอป | ค่าใช้จ่าย |
|---|---|---|---|---|
| **A. App Check** | โดเมนของแอป (มีแล้ว) | กันสคริปต์/บอต/คนที่ไม่มีโทเคน — **ไม่กันคนที่เปิดแอปจริงแล้วใช้ DevTools** | แทบไม่มี (ต่อไว้ให้แล้ว) | ฟรี |
| **B. Auth + อีเมลจริง** | อีเมลของคนขับทุกคน | ~95% (ยังต้องมีดัชนีสาธารณะ + แอดมินแก้รหัสคนอื่นไม่ได้) | ปานกลาง (ฟอร์ม + ล็อกอินใหม่ + กติกา) | ฟรี |
| **C. Auth + Custom Token ผ่าน Cloud Functions** | เปิดใช้ Blaze (ผูกบัตร แต่มีโควตาฟรี) | **ปิดจริง 100%** | ปานกลาง | ฟรีในโควตา (2 ล้านครั้ง/เดือน) |

### 🎯 คำแนะนำของผม

1. **ทำ A ก่อนทันที** — ใช้เวลา 10 นาที ไม่ต้องแก้โค้ดแอปเพิ่ม (ต่อท่อไว้แล้ว) ได้ผลจริงระดับหนึ่ง
2. จากนั้นถ้าอยาก **ปิดจริง** ให้ทำ **C** — เพราะแอปนี้ล็อกอินด้วย username/รหัสผ่านของตัวเอง
   ถ้าไปใช้ B จะต้องบังคับให้คนขับมีอีเมล และ "ลืมรหัสผ่าน" ของเดิม (ยืนยัน username + เบอร์โทร)
   จะใช้ไม่ได้อีก ต้องพึ่งอีเมลของ Firebase เท่านั้น
3. **B เหมาะกับแอปใหม่** ที่เก็บอีเมลตั้งแต่สมัคร — ไม่แนะนำให้ย้ายแอปที่ใช้งานจริงอยู่แล้วไป B

---

## 2. แนวทาง A — App Check (ทำได้เลยวันนี้)

แนวคิด: แนบ **โทเคนที่พิสูจน์ว่า "คำขอนี้มาจากเบราว์เซอร์ที่รันโดเมนของเรา"** ไปกับทุกคำขอ
คนนอกที่ยิง `curl` / สคริปต์ Python ใส่ Firestore จะไม่มีโทเคนนี้ → โดนปฏิเสธ

### ขั้นที่ 1 — ขอ site key ของ reCAPTCHA v3 (ฟรี)

1. เปิด <https://www.google.com/recaptcha/admin/create>
2. Label: `taxi-meter` · reCAPTCHA type: **v3** · Domains: `baby4bot.github.io` (และ `127.0.0.1` ถ้าทดสอบในเครื่อง)
3. กด Submit → คัดลอก **Site key** (ขึ้นต้นด้วย `6L...`)

> reCAPTCHA v3 ให้ประเมินฟรี **1,000,000 ครั้ง/เดือน** — เกินพอสำหรับแอปคนขับไม่กี่สิบคน

### ขั้นที่ 2 — ลงทะเบียนกับ Firebase

1. <https://console.firebase.google.com> → โปรเจกต์ `mytalkie-3955a` → **App Check**
2. แท็บ **Apps** → เลือกเว็บแอป (`...:web:02e2...`) → ติ๊ก **reCAPTCHA v3** → วาง site key → **Save**

### ขั้นที่ 3 — เปิดในแอป (แก้ 1 บรรทัด)

เปิด `index.html` หาบรรทัดนี้ (อยู่ในส่วน Firebase config) แล้ววาง site key:

```js
const APP_CHECK_SITE_KEY = "6Lxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; // ← วาง site key ที่นี่
```

โค้ดที่เหลือ **เขียนไว้ให้แล้ว** — จะโหลด SDK, เริ่มต้น App Check, และแนบโทเคนให้ทุกคำขอ REST
ผ่าน `window.__fsHeaders()` (เส้นทางสำรองที่แอปใช้เมื่อ Firestore SDK ค้าง)

### ขั้นที่ 4 — ดูผลก่อนบังคับใช้ (สำคัญมาก ⚠️)

1. Firebase Console → App Check → **APIs** → **Cloud Firestore** → ยัง **อย่ากด Enforce**
2. เปิดแอปจริง 1-2 วัน → ดูแถบ **Metrics** ว่าคำขอที่ "verified" ต้องขึ้นเกือบ 100%
3. ถ้า verified ครบแล้ว → กด **Enforce**

> ⚠️ กด Enforce ก่อนที่แอปจะส่งโทเคนได้ = **แอปอ่าน/เขียน Firestore ไม่ได้เลย** ทุกคนใช้งานไม่ได้
> ถ้าพลาดแล้ว ให้กลับไปเป็น Unenforced (ย้อนได้ทันที)

### ขั้นที่ 5 — พิสูจน์

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/security-check.ps1
```

สคริปต์นี้ยิง REST ตรงแบบไม่ผ่านเบราว์เซอร์ → หลัง Enforce ต้องขึ้น **LOCKED ทั้ง 7 ข้อ**

### 😬 สิ่งที่ A ยังปิดไม่ได้

คนที่เปิดแอปจริงในเบราว์เซอร์ (โหลดหน้าเว็บของเรา) จะได้โทเคน App Check ไปด้วย
แล้วเปิด DevTools ยิงคำขอเองได้ — App Check **ไม่รู้ว่า "ใคร"** ยังเป็นแนวป้องกันระดับ "กันบอต/กันขโมยคีย์"

---

## 3. แนวทาง B — Auth + อีเมลจริง

แนวคิด: ให้ทุกบัญชีมีอีเมล → ล็อกอินด้วย `signInWithEmailAndPassword()` → ได้ `request.auth.uid`
แล้วผูก uid กับ doc ของผู้ใช้ (`users/<docId>`)

### สิ่งที่ต้องแก้ในแอปนี้

| จุด | เดิม | ใหม่ |
|---|---|---|
| `window.registerApp()` | เก็บ username + รหัสผ่านแฮช | เพิ่มช่องอีเมล + `createUserWithEmailAndPassword` |
| ล็อกอิน | `__fsFindUser` → `pwVerify` | `signInWithEmailAndPassword(email, password)` |
| ลืมรหัสผ่าน | ยืนยัน username + เบอร์โทร แล้วเขียนแฮชใหม่ | `sendPasswordResetEmail()` (Firebase ส่งลิงก์ให้) |
| doc ผู้ใช้ | ไม่มี auth info | เพิ่มฟิลด์ `authUid` |

### โค้ดหลัก (วางใน `index.html` หลังส่วน Firebase config)

```js
import { getAuth, signInWithEmailAndPassword, createUserWithEmailAndPassword,
         signOut, sendPasswordResetEmail, onAuthStateChanged }
  from "https://www.gstatic.com/firebasejs/10.8.0/firebase-auth.js";

const auth = getAuth(app);

// ล็อกอิน
window.authLogin = async (email, password) => {
    const cred = await signInWithEmailAndPassword(auth, email.trim(), password);
    return cred.user; // cred.user.uid คือค่าที่กติกา Firestore จะเห็น
};

// สมัคร
window.authRegister = async (email, password) => {
    const cred = await createUserWithEmailAndPassword(auth, email.trim(), password);
    return cred.user;
};

// ลืมรหัสผ่าน
window.authForgot = (email) => sendPasswordResetEmail(auth, email.trim());

// ออกจากระบบ (ต้องเรียกตอนกด "ออกจากระบบ" เสมอ!)
window.authLogout = () => signOut(auth);
```

### กติกาที่ใช้คู่กัน

```js
match /users/{uid} {
  allow get: if request.auth != null && resource.data.authUid == request.auth.uid;
  allow update: if request.auth != null && resource.data.authUid == request.auth.uid;
  allow create: if request.auth != null && request.resource.data.authUid == request.auth.uid;
  allow list: if request.auth != null;   // ⚠️ ยังเปิดให้ล็อกอินแล้วเห็นรายชื่อ — ดูข้อควรระวัง
}
```

### ⚠️ ข้อควรระวัง 3 ข้อของแนวทางนี้

1. **การค้นหาชื่อผู้ใช้ก่อนล็อกอิน** — แอปต้องรู้ว่า username นี้มีอยู่ไหมก่อนสร้างบัญชี (`registerApp`)
   จึงต้องมีคอลเลกชันสาธารณะเช่น `usernames/{username} = { docId }` ที่ **ห้ามมีข้อมูลอ่อนไหว**
   (ตอนนี้ `registerApp` คิวรี `users` ตรง ๆ ซึ่งจะถูกบล็อกเมื่อกติการัด)
2. **แฮชรหัสผ่านยังอยู่ใน `users`** — ถ้าเปิด `allow list` ให้คนที่ล็อกอินแล้วทุกคนอ่าน
   เท่ากับคนขับทุกคนอ่านแฮชรหัสผ่านเพื่อนได้ → ควรย้ายฟิลด์ `password` ไปไว้ `users/{uid}/private/pw`
   ที่อนุญาตเฉพาะเจ้าของ (และแอดมิน) — เป็นงานย้ายข้อมูลอีกขั้น
3. **แอดมินแก้รหัสผ่านคนอื่นไม่ได้** — `sendPasswordResetEmail` ต้องให้เจ้าของบัญชีกดเอง
   ตอนนี้แอปมีหน้า "แอดมินเพิ่มผู้ใช้ + ตั้งรหัสให้" ซึ่งจะทำแบบเดิมไม่ได้

---

## 4. แนวทาง C — Auth + Custom Token (ปิดจริง 100%) ⭐

แนวคิด: ตัดสินใจเรื่องรหัสผ่าน **ที่เซิร์ฟเวอร์** แล้วออก "ตั๋วเข้าแอป" (custom token) ให้

```
คนขับ                     Cloud Function (Admin SDK)              Firestore
  │  username + รหัสผ่าน  ─────────────►  │
  │                                       │  ตรวจรหัสกับแฮชใน doc (ฝั่งเซิร์ฟเวอร์)
  │                                       │  ไม่ต้องแก้กติกา ไม่ต้องให้ client อ่าน
  │  ◄───── custom token ────────────────┤
  │
  │  signInWithCustomToken(token)
  │  ─────────────────────────────────────────────────────►  request.auth.uid = <docId>
```

**จุดที่สวยที่สุด:** ตั้ง `uid` ของโทเคนให้ **เท่ากับ docId ของผู้ใช้ใน `users`** (`0FujoFAvn6QUOI4DfYPo` ฯลฯ)
→ กติกาง่ายสุด ๆ ไม่ต้องมีตารางจับคู่:

```js
allow read, write: if request.auth.uid == uid;   // /users/{uid}
```

### ขั้นที่ 1 — เปิด Blaze (ผูกบัตร)

Blaze = pay-as-you-go แต่ **มีโควตาฟรีทุกเดือน** (Cloud Functions 2 ล้านครั้ง/เดือน, Firestore ต่อวัน)
→ ตั้ง **Budget alert** ไว้ที่ 100 บาท จะได้ไม่ตื่นตระหนกถ้าจู่ ๆ มีคนยิงถล่ม

### ขั้นที่ 2 — เตรียมโปรเจกต์ฟังก์ชัน (ในเครื่อง)

```bash
npm i -g firebase-tools          # ติดตั้ง Firebase CLI (ครั้งเดียว)
firebase login
cd "G:\My Drive\HTML\freebuff\แท็กซี"
firebase init functions          # เลือก JavaScript, ใช้โปรเจกต์ mytalkie-3955a, ไม่ต้อง ESLint
```

### ขั้นที่ 3 — เขียนฟังก์ชัน (`functions/index.js`)

```js
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const crypto = require("crypto");

admin.initializeApp();
const db = admin.firestore();

// ── ตรวจรหัสผ่านให้ตรงกับ format ของแอป ──────────────────────────────
// แอปเก็บ 3 รุ่น (index.html → window.pwVerify)
//   pbkdf2$<iter>$<salt>$<hex>   ← รุ่นใหม่ (PBKDF2-HMAC-SHA256, 100000 รอบ, 256 บิต)
//   sha256$<salt>$<hex>          ← รุ่นเก่า  (sha256(salt + "::" + plain))
//   <plaintext>                  ← รุ่นเก่ามาก
function verifyPassword(plain, stored) {
  if (!stored || typeof stored !== "string") return { ok: false, legacy: false };
  if (stored.startsWith("pbkdf2$")) {
    const [, iter, salt, hash] = stored.split("$");
    const got = crypto.pbkdf2Sync(plain, salt, parseInt(iter, 10), hash.length / 2, "sha256").toString("hex");
    return { ok: got === hash, legacy: false };
  }
  if (stored.startsWith("sha256$")) {
    const [, salt, hash] = stored.split("$");
    const got = crypto.createHash("sha256").update(salt + "::" + plain, "utf8").digest("hex");
    return { ok: got === hash, legacy: true };
  }
  return { ok: stored === plain, legacy: true };  // plaintext → ต้องอัปเกรด
}

const newHash = (plain) => {
  const salt = crypto.randomBytes(9).toString("base64url").slice(0, 16);
  const hash = crypto.pbkdf2Sync(plain, salt, 100000, 32, "sha256").toString("hex");
  return `pbkdf2$100000$${salt}$${hash}`;
};

// ── ล็อกอิน: ตรวจรหัสฝั่งเซิร์ฟเวอร์ แล้วออก custom token ──────────────
exports.login = onCall(async (req) => {
  const username = String(req.data?.username || "").trim();
  const password = String(req.data?.password || "");
  if (!username || !password) throw new HttpsError("invalid-argument", "missing credentials");

  const snap = await db.collection("users").where("username", "==", username).limit(1).get();
  if (snap.empty) throw new HttpsError("not-found", "ไม่พบบัญชี");
  const doc = snap.docs[0];
  const data = doc.data();
  if (data.isBanned) throw new HttpsError("permission-denied", "บัญชีถูกระงับ");

  const { ok, legacy } = verifyPassword(password, data.password || "");
  if (!ok) throw new HttpsError("unauthenticated", "รหัสผ่านไม่ถูกต้อง");

  // อัปเกรดแฮชรุ่นเก่าให้เป็น PBKDF2 (ทำฝั่งเซิร์ฟเวอร์ ไม่ต้องให้ client เห็นรหัส)
  if (legacy) await doc.ref.update({ password: newHash(password) });

  await doc.ref.update({ lastLoginAt: Date.now() });

  // 🔑 uid = docId ของผู้ใช้ → กติกาจับคู่ได้ตรง ๆ ด้วย request.auth.uid == uid
  const token = await admin.auth().createCustomToken(doc.id);
  return { token, docId: doc.id, role: data.role || "User" };
});

// ── สมัครสมาชิก (ฝั่งเซิร์ฟเวอร์) ────────────────────────────────────────
exports.register = onCall(async (req) => {
  const { username, password, displayName, phoneNumber, photoURL } = req.data || {};
  if (!username || !password) throw new HttpsError("invalid-argument", "missing fields");
  if (String(password).length < 6) throw new HttpsError("invalid-argument", "รหัสผ่านสั้นเกินไป");

  const dup = await db.collection("users").where("username", "==", username).limit(1).get();
  if (!dup.empty) throw new HttpsError("already-exists", "Username นี้มีคนใช้แล้ว");

  const ref = await db.collection("users").add({
    username, password: newHash(password), displayName: displayName || username,
    phoneNumber: phoneNumber || "", photoURL: photoURL || "", role: "User",
    taxiType: 35, tollwayMode: false, isBanned: false,
    lastLoginAt: Date.now(), order: Date.now(), themeMode: "oled", oledMode: true,
  });
  return { token: await admin.auth().createCustomToken(ref.id), docId: ref.id };
});

// ── เปลี่ยนรหัสผ่าน (ผู้ใช้ที่ล็อกอินแล้ว) ───────────────────────────────
exports.changePassword = onCall(async (req) => {
  if (!req.auth) throw new HttpsError("unauthenticated", "ต้องล็อกอินก่อน");
  const { oldPassword, newPassword } = req.data || {};
  const ref = db.collection("users").doc(req.auth.uid);   // uid = docId
  const data = (await ref.get()).data();
  if (!verifyPassword(String(oldPassword || ""), data.password || "").ok)
    throw new HttpsError("unauthenticated", "รหัสเดิมไม่ถูกต้อง");
  if (String(newPassword || "").length < 6) throw new HttpsError("invalid-argument", "รหัสใหม่สั้นเกินไป");
  await ref.update({ password: newHash(newPassword) });
  return { ok: true };
});
```

### ขั้นที่ 4 — deploy

```bash
firebase deploy --only functions
# → ได้ชื่อฟังก์ชันมาใช้ในแอป เช่น
#   https://asia-southeast1-mytalkie-3955a.cloudfunctions.net/login
```

### ขั้นที่ 5 — แก้แอป (client)

```js
import { getAuth, signInWithCustomToken, onAuthStateChanged }
  from "https://www.gstatic.com/firebasejs/10.8.0/firebase-auth.js";

const auth = getAuth(app);

window.serverLogin = async (username, password) => {
    const r = await fetch(FN_BASE + "/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ data: { username, password } }),
    });
    if (!r.ok) throw new Error((await r.json()).error?.message || "ล็อกอินไม่สำเร็จ");
    const { result } = await r.json();
    await signInWithCustomToken(auth, result.token);   // ← ได้ request.auth.uid ทันที
    return result;
};
```

> 📌 **สำคัญ — เรื่องออฟไลน์:** ตอนนี้แอปเปิดได้ตอนไม่มีเน็ต (ใช้ `taxi_user_id` ใน `localStorage`)
> ถ้าย้ายการตรวจรหัสไปเซิร์ฟเวอร์ การ "ล็อกอินครั้งแรก" จะต้องมีเน็ต
> วิธีที่แนะนำ: ถ้าเครื่องนี้เคยล็อกอินสำเร็จมาก่อน → ให้เข้าแอปได้เลยโดยข้ามการถามรหัส
> (เหมือนกลไก session ที่มีอยู่) · ให้ถามรหัสผ่านเฉพาะเครื่องใหม่/หลังกดออกจากระบบ

### ขั้นที่ 6 — รัดกติกา (`firestore-auth.rules`)

หลังทุกบัญชีล็อกอินผ่านทางใหม่ได้แล้ว จึงเปลี่ยนกติกาเป็นแบบเจ้าของเท่านั้น
(ผมเตรียมไฟล์ [`firestore-auth.rules`](firestore-auth.rules) ไว้ให้แล้ว — ดูหัวไฟล์ประกอบ)

### ขั้นที่ 7 — ลบบัญชี Auth ที่ไม่ใช้

แนวทาง C **ไม่ต้องสร้างบัญชีใน Firebase Authentication เลย** (custom token สร้างผู้ใช้ปลอมให้ชั่วคราว)
→ ไม่มีรหัสผ่านค้างที่ Firebase, ไม่มีปัญหาอีเมลปลอม, และ **รหัสผ่านเปลี่ยนได้ทันที** เพราะความจริงอยู่ที่ Firestore

---

## 5. ทดสอบว่า "เสร็จจริง"

| # | ทดสอบ | ต้องได้ |
|---|---|---|
| 1 | `tests/security-check.ps1` | **LOCKED ทั้ง 7 ข้อ** (ก่อนวางกติกาต้องขึ้น OPEN ตามเดิม) |
| 2 | เปิดแอป → ล็อกอินคนขับ 1 คน | เข้าได้ + ข้อมูล/เที่ยว/รายได้ครบ |
| 3 | ล็อกอินด้วยรหัสผิด 3 ครั้ง | เข้าไม่ได้ + ไม่ล็อกบัญชีค้าง (แนวทาง C ไม่มีนโยบายล็อกของ Firebase) |
| 4 | เครื่องใหม่ที่ไม่มี `localStorage` + เน็ตหลุด | ต้องบอกให้ต่อเน็ต (ไม่ใช่ค้างเงียบ) |
| 5 | กด **ออกจากระบบ** แล้วเปิดแอปใหม่ | **ต้องไม่เข้าเอง** (ถ้าเข้าเอง = ลืม `signOut(auth)` หรือยังมีโทเคนค้าง) |
| 6 | ลืมรหัสผ่าน → ตั้งใหม่ → ล็อกอิน | เข้าได้ด้วยรหัสใหม่ และรหัสเก่าใช้ไม่ได้ |
| 7 | เปิด 2 เครื่องด้วยบัญชีเดียวกัน (คนขับ) | เครื่องเก่าโดนไล่ออก (กลไก session เดิมยังทำงาน) |

---

## 6. ย้อนกลับได้เสมอ (Rollback)

| ทำอะไร | ย้อนยังไง |
|---|---|
| วางกติกาแล้วแอปพัง | Firebase Console → Rules → **ประวัติ** → เลือกเวอร์ชันก่อนหน้า → Restore (หรือ Publish กติกาไฟล์เก่า) |
| เปิด App Check Enforce แล้วแอปเข้าไม่ได้ | App Check → APIs → Cloud Firestore → **Unenforced** (มีผลทันที) |
| Auth แล้วล็อกอินไม่ได้ | กลับไปใช้เส้นทางเดิม: `AUTH_*` ในโค้ดแอปเป็นสวิตช์ — ปิด = กลับพฤติกรรมเดิมเป๊ะ |
| ลบข้อมูลผิด | `firestore.rules` ห้ามลบ `trips` / log อยู่แล้ว → ใช้ **Firestore → Backup** (ต้องเปิดก่อน) |

**ก่อนทำอะไรที่แก้ข้อมูล**: ทดสอบกับบัญชีทดสอบ 1 บัญชีก่อนเสมอ (สร้าง `test1` → ทดสอบ → ลบ)

---

## 7. ตาราง error ที่เจอบ่อย + วิธีแก้

| ข้อความ | สาเหตุ | แก้ |
|---|---|---|
| `auth/operation-not-allowed` | ยังไม่เปิด Email/Password provider | Authentication → Sign-in method → เปิด |
| `auth/invalid-api-key` | คีย์ผิด/โปรเจกต์ผิด | เทียบกับ `firebaseConfig` ใน `index.html` |
| `auth/unauthorized-domain` | โดเมนไม่ได้อยู่ในรายการ (เกิดกับ OAuth เป็นหลัก) | Authentication → Settings → Authorized domains → เพิ่ม `baby4bot.github.io` |
| `auth/too-many-requests` | ยิงถี่เกิน (เช่นรหัสผิดรัว ๆ) | รอ ~15 นาที · อย่าล็อกอินซ้ำในลูป |
| `auth/email-already-in-use` | มีบัญชี Auth ด้วยอีเมลนั้นแล้ว | ใช้ `signInWithEmailAndPassword` แทน `create...` |
| `auth/user-not-found` | ยังไม่ได้ย้ายบัญชีนั้นมา Auth | ให้ผู้ใช้ล็อกอินเส้นทางเดิม 1 ครั้งแล้วผูกอัตโนมัติ |
| `Missing or insufficient permissions` (ตอนแอปทำงาน) | กติการัดแล้วแต่ยังอ่าน doc ที่ไม่ใช่ของตัวเอง | ดูว่าฟังก์ชันนั้นอ่านคอลเลกชันไหน แล้วเปิดในกติกาให้ตรง |
| `FirebaseError: 7 PERMISSION_DENIED` บ่อยตอนสลับหน้า | กติกาอนุญาต `get` แต่ไม่อนุญาต `list` (หรือกลับกัน) | Firestore แยก `get`/`list` — ต้องเขียนทั้งคู่ |
| App Check ขึ้น `invalid` ตลอด | site key ไม่ตรงโดเมน / เปิด Enforce ก่อน | ตรวจโดเมนใน reCAPTCHA admin · กลับเป็น Unenforced |

---

## 8. คำศัพท์ที่ต้องรู้

| คำ | ความหมายสั้น ๆ |
|---|---|
| `uid` | รหัสประจำตัวในระบบ Firebase Auth · ในแนวทาง C เราตั้งให้เท่ากับ docId ของผู้ใช้ |
| **ID token** | ตั๋วอายุสั้น (~1 ชม.) ที่ Firebase ออกให้หลังล็อกอิน · SDK แนบให้อัตโนมัติ |
| **custom token** | ตั๋วที่ **เซิร์ฟเวอร์ของเรา** (Admin SDK) ออกให้ แล้ว client แลกเป็น ID token |
| `request.auth.uid` | ค่าที่กติกาเห็น · ว่างเมื่อไม่ได้ล็อกอิน Firebase |
| **App Check** | ระบบพิสูจน์ว่า "คำขอนี้มาจากแอปของเรา" — **ไม่รู้ว่าเป็นใคร** (ต่างจาก Auth) |
| `get` vs `list` | Firestore แยกสิทธิ์ "อ่านเอกสารเดียว" กับ "คิวรีเป็นชุด" |
| **Admin SDK** | SDK ฝั่งเซิร์ฟเวอร์ ใช้ข้ามกติกาได้ · **ห้ามอยู่ในโค้ดฝั่งเว็บเด็ดขาด** |

---

## 9. สรุปว่าควรทำอะไรต่อ

```
วันนี้        → A. App Check (10 นาที) + วาง firestore.rules (ตาม SECURITY.md)
สัปดาห์นี้     → ลองขับจริง 1 เที่ยว → ยืนยันว่าทุกอย่างยังทำงาน → กด Enforce
เมื่อพร้อม     → C. Cloud Functions + Custom Token → กติกาแบบเจ้าของเท่านั้น = ปิดจริง
ไม่แนะนำ      → B. อีเมลจริง (คนขับต้องมีอีเมล + ลืมรหัสผ่านแบบเดิมหายไป)
```

> 💡 **คอมมิตนี้ไม่ได้แก้โค้ดแอปเพิ่มเลย** — เป็นคู่มือล้วน ๆ เพื่อให้คุณเลือกแนวทางก่อน
> แล้วผมจะลงมือทำเส้นทางที่เลือกให้เสร็จ (โค้ด + กติกา + ทดสอบ)
