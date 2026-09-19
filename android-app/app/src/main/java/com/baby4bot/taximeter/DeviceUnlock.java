package com.baby4bot.taximeter;

import android.app.Activity;
import android.app.KeyguardManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.hardware.biometrics.BiometricManager;
import android.hardware.biometrics.BiometricPrompt;
import android.os.Build;
import android.os.CancellationSignal;
import android.util.Base64;

import java.security.SecureRandom;

/**
 * 🔓 ปลดล็อกด้วยเครื่อง (ลายนิ้วมือ / ใบหน้า / รหัสเครื่อง) — สำหรับเวอร์ชัน APK
 *
 * ⚠️ ทำไมต้องมีชั้นนี้ (ผู้ใช้แจ้ง 20 ก.ย. 69: “ปุ่มลงทะเบียนปลดล็อกด้วยลายนิ้วมือ ใช้ผ่านโทรศัพท์ไม่ได้
 *    มันเคยใช้ได้อยู่แล้ว”):
 *    ฝั่งเว็บใช้ WebAuthn (`navigator.credentials.create`) ซึ่ง **Android WebView ไม่รองรับ**
 *    (ทั้ง Okta และ Duo ระบุตรงกันว่า WebAuthn ใช้ใน WebView ไม่ได้ ⇒ `window.PublicKeyCredential` ไม่มี)
 *    ⇒ ใน APK ปุ่มนี้จึงขึ้นว่า “เครื่องนี้/ที่อยู่นี้ยังใช้ไม่ได้” ทุกเครื่อง (ใน Chrome บนมือถือยังใช้ได้)
 *
 * ✅ วิธีของชั้นนี้: เรียก "หน้าปลดล็อกของระบบ" ตรง ๆ ผ่าน framework API ล้วน (ไม่เพิ่ม dependency)
 *    · Android 11+ (30) → `android.hardware.biometrics.BiometricManager` + BiometricPrompt (ลายนิ้วมือ/ใบหน้า/รหัสเครื่อง)
 *    · Android 9 (28–29) → BiometricPrompt (เฉพาะเซนเซอร์) / ถ้าไม่มีเซนเซอร์ = ใช้หน้า Keyguard
 *    · Android 8 (26–27) → หน้า Keyguard (ยืนยันด้วยรหัส/รูปแบบ/PIN ของเครื่อง)
 *
 * ⚠️ ทำไม “แยกเมธอดตามรุ่น” (availableApi30 / startApi30 / startApi28 / startKeyguard):
 *    minSdk = 26 แต่คลาส BiometricManager มีตั้งแต่ API 29 และ BiometricPrompt ตั้งแต่ API 28
 *    การอ้างคลาสเหล่านี้ปนอยู่ในเมธอดเดียวจะทำให้เครื่องรุ่นเก่าโดน “ตรวจคลาสไม่ผ่าน” (VerifyError/NoClassDefFoundError)
 *    ⇒ แยกเป็นเมธอดของตัวเอง แล้วเรียกเฉพาะเมื่อรุ่นนั้นรองรับจริง (แนวทางที่ Android แนะนำ)
 *
 * 🔐 ระดับความปลอดภัย (เทียบเท่าของเดิม): เก็บ "รหัส credential" แบบสุ่มใน SharedPreferences ของแอป
 *    และ **ต้องผ่านหน้าปลดล็อกของเครื่องทุกครั้ง** ก่อนใช้ (ตัวเลข/ใบหน้าไม่เข้าแอป ไม่ขึ้นเซิร์ฟเวอร์)
 *
 * 📮 ผลลัพธ์ทุกเส้นทางส่งกลับเป็น “คีย์สั้น ๆ” ให้หน้าเว็บแปลเป็นภาษาไทยเอง
 *    (canceled / locked / unavailable / busy / no-keyguard / not-enrolled / error-*)
 *
 * ⛔ ห้ามเรียกเมธอดของคลาสนี้จาก thread ของ WebView ตรง ๆ — MainActivity เป็นคนเรียกผ่าน runOnUiThread
 */
final class DeviceUnlock {

    /** ✉️ ผลลัพธ์ของคำขอหนึ่งครั้ง (ok = ผ่านหน้าปลดล็อกแล้ว) */
    interface Cb {
        void done(boolean ok, String credId, String err);
    }

    /** รหัสคำขอไปยัง onActivityResult ของ MainActivity */
    static final int REQ = 1004;

    private static final String PREFS = "taxi_devunlock_native";
    private static final String TAG_PREFIX = "uid:";
    private static final String TITLE = "ยืนยันตัวตน";

    // 🔢 รหัสข้อผิดพลาด 13 = “กดปุ่มยกเลิกบนหน้าต่างของระบบ”
    //    ⚠️ ค่านี้ไม่มีค่าคงที่ใน android.hardware.biometrics.BiometricPrompt
    //       (มีแต่ใน androidx.biometric / BiometricConstants) ⇒ ประกาศเองเพื่อให้คอมไพล์ผ่านแน่นอน
    private static final int ERR_NEGATIVE_BUTTON = 13;

    // 🧵 สถานะของคำขอที่กำลังรอผลจากหน้า Keyguard (มีได้ครั้งละหนึ่ง — กันกดรัว)
    private static Cb pendingCb;
    private static String pendingUid;
    private static boolean pendingEnroll;
    private static boolean promptShowing;

    private DeviceUnlock() {
    }

    // ───────────────────────────── ที่เก็บ ─────────────────────────────

    private static SharedPreferences prefs(Context c) {
        return c.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    /** ลงทะเบียนเครื่องนี้ให้บัญชีนั้นไว้แล้วหรือยัง */
    static boolean has(Context c, String uid) {
        try {
            return uid != null && !uid.isEmpty() && !prefs(c).getString(TAG_PREFIX + uid, "").isEmpty();
        } catch (Throwable e) {
            return false;
        }
    }

    /** ยกเลิกการลงทะเบียนของบัญชีนั้น (คืน true = ไม่เหลือข้อมูลแล้ว) */
    static boolean remove(Context c, String uid) {
        try {
            if (uid == null || uid.isEmpty()) return false;
            prefs(c).edit().remove(TAG_PREFIX + uid).apply();
            return true;
        } catch (Throwable e) {
            return false;
        }
    }

    private static String readCred(Context c, String uid) {
        try {
            return prefs(c).getString(TAG_PREFIX + uid, "");
        } catch (Throwable e) {
            return "";
        }
    }

    private static String newCredId() {
        byte[] b = new byte[32];
        new SecureRandom().nextBytes(b);
        return Base64.encodeToString(b, Base64.NO_WRAP | Base64.URL_SAFE | Base64.NO_PADDING);
    }

    /**
     * ผ่านหน้าปลดล็อกแล้ว → ปิดงานให้จบในที่เดียว
     *   enroll  = สร้างรหัส credential ใหม่ + จำไว้กับบัญชีนี้
     *   verify  = คืนรหัสที่จำไว้
     * (สำคัญ: เขียนที่เก็บที่เดียว ⇒ ทุกเส้นทาง — BiometricPrompt / Keyguard — ได้พฤติกรรมเดียวกัน)
     */
    private static void complete(Activity a, String uid, boolean enroll, Cb cb) {
        try {
            if (enroll) {
                String cred = newCredId();
                prefs(a).edit().putString(TAG_PREFIX + uid, cred).apply();
                cb.done(true, cred, "");
            } else {
                String cred = readCred(a, uid);
                if (cred.isEmpty()) cb.done(false, "", "not-enrolled");
                else cb.done(true, cred, "");
            }
        } catch (Throwable e) {
            cb.done(false, "", "error:" + e.getClass().getSimpleName());
        }
    }

    // ───────────────────────────── ความพร้อมใช้ ─────────────────────────────

    private static boolean keyguardSecure(Activity a) {
        try {
            KeyguardManager km = (KeyguardManager) a.getSystemService(Context.KEYGUARD_SERVICE);
            return km != null && km.isDeviceSecure();
        } catch (Throwable e) {
            return false;
        }
    }

    private static boolean hasSensor(Activity a) {
        try {
            PackageManager pm = a.getPackageManager();
            if (pm.hasSystemFeature(PackageManager.FEATURE_FINGERPRINT)) return true;
            if (Build.VERSION.SDK_INT >= 29
                    && (pm.hasSystemFeature(PackageManager.FEATURE_FACE) || pm.hasSystemFeature(PackageManager.FEATURE_IRIS))) return true;
            return false;
        } catch (Throwable e) {
            return false;
        }
    }

    /** เครื่องนี้ใช้ “ปลดล็อกด้วยเครื่อง” ได้ไหม (ใช้ตัดสินว่าโชว์ปุ่มหรือบอกสาเหตุ) */
    static boolean available(Activity a) {
        try {
            // ⚠️ แยกเมธอดตามรุ่น — เครื่องรุ่นเก่าจะไม่ต้องโหลดคลาสที่ยังไม่มี (ดูคำอธิบายหัวไฟล์)
            if (Build.VERSION.SDK_INT >= 30) return availableApi30(a);
            if (Build.VERSION.SDK_INT >= 28) return hasSensor(a) || keyguardSecure(a);
            return keyguardSecure(a);
        } catch (Throwable e) {
            return false;
        }
    }

    /** Android 11+ — ถามระบบตรง ๆ ว่ามีลายนิ้วมือ/ใบหน้า/รหัสเครื่องให้ใช้ไหม */
    private static boolean availableApi30(Activity a) {
        BiometricManager bm = a.getSystemService(BiometricManager.class);
        if (bm == null) return keyguardSecure(a);
        int ok = bm.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK | BiometricManager.Authenticators.DEVICE_CREDENTIAL);
        if (ok == BiometricManager.BIOMETRIC_SUCCESS) return true;
        if (ok == BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED) return keyguardSecure(a);
        return false;
    }

    // ───────────────────────────── เรียกหน้าปลดล็อก ─────────────────────────────

    /**
     * enroll = true → ลงทะเบียนเครื่องนี้ให้ uid (สำเร็จแล้วสร้างรหัส credential ใหม่)
     * enroll = false → ยืนยันตัวตนด้วยรหัสที่ลงทะเบียนไว้
     * ⚠️ ต้องเรียกจาก UI thread เท่านั้น
     */
    static void start(final Activity a, final String uid, final boolean enroll, final Cb cb) {
        if (promptShowing || pendingCb != null) {
            cb.done(false, "", "busy");
            return;
        }
        if (!available(a)) {
            cb.done(false, "", "unavailable");
            return;
        }
        if (!enroll && !has(a, uid)) {
            cb.done(false, "", "not-enrolled");
            return;
        }
        try {
            if (Build.VERSION.SDK_INT >= 30) { startApi30(a, uid, enroll, cb); return; }
            if (Build.VERSION.SDK_INT >= 28 && hasSensor(a)) { startApi28(a, uid, enroll, cb); return; }
            startKeyguard(a, uid, enroll, cb);
        } catch (Throwable e) {
            promptShowing = false;
            cb.done(false, "", "error:" + e.getClass().getSimpleName());
        }
    }

    private static String descOf(boolean enroll) {
        return enroll ? "ลงทะเบียนเครื่องนี้เพื่อปลดล็อกแทนการพิมพ์ PIN" : "ปลดล็อกเพื่อยืนยันรายการสำคัญ";
    }

    /** Android 11+ — หน้าปลดล็อกของระบบ (ลายนิ้วมือ · ใบหน้า · รหัสเครื่อง) */
    private static void startApi30(Activity a, String uid, boolean enroll, Cb cb) {
        // ⚠️ Executor = java.util.concurrent.Executor (ไม่ใช่ android.os.Executor ที่ไม่มีอยู่จริง)
        java.util.concurrent.Executor ex = a.getMainExecutor();
        BiometricPrompt.Builder b = new BiometricPrompt.Builder(a)
                .setTitle(TITLE)
                .setDescription(descOf(enroll))
                .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_WEAK | BiometricManager.Authenticators.DEVICE_CREDENTIAL);
        BiometricPrompt bp = b.build();
        promptShowing = true;
        bp.authenticate(new CancellationSignal(), ex, new PromptCb(a, uid, enroll, cb));
    }

    /** Android 9–10 — BiometricPrompt รุ่นแรก (เฉพาะเซนเซอร์ · มีปุ่มยกเลิกเอง) */
    private static void startApi28(final Activity a, final String uid, final boolean enroll, final Cb cb) {
        java.util.concurrent.Executor ex = a.getMainExecutor();
        BiometricPrompt.Builder b = new BiometricPrompt.Builder(a)
                .setTitle(TITLE)
                .setDescription(descOf(enroll))
                .setNegativeButton("ยกเลิก", ex, new android.content.DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(android.content.DialogInterface d, int which) {
                        promptShowing = false;
                        cb.done(false, "", "canceled");
                    }
                });
        BiometricPrompt bp = b.build();
        promptShowing = true;
        bp.authenticate(new CancellationSignal(), ex, new PromptCb(a, uid, enroll, cb));
    }

    /** ทางสำรอง (Android 8 หรือเครื่องที่ไม่มีเซนเซอร์): หน้า “ยืนยันรหัสของเครื่อง” ของระบบ */
    private static void startKeyguard(Activity a, String uid, boolean enroll, Cb cb) {
        KeyguardManager km = (KeyguardManager) a.getSystemService(Context.KEYGUARD_SERVICE);
        Intent i = (km == null) ? null : km.createConfirmDeviceCredentialIntent(TITLE, descOf(enroll));
        if (i == null) {
            cb.done(false, "", "no-keyguard");
            return;
        }
        pendingCb = cb;
        pendingUid = uid;
        pendingEnroll = enroll;
        a.startActivityForResult(i, REQ);
    }

    /** MainActivity เรียกจาก onActivityResult — คืน true = คำขอนี้เป็นของชั้นนี้ (จัดการแล้ว) */
    static boolean onActivityResult(Activity a, int req, int res) {
        if (req != REQ) return false;
        final Cb cb = pendingCb;
        final String uid = pendingUid;
        final boolean enroll = pendingEnroll;
        pendingCb = null;
        pendingUid = null;
        pendingEnroll = false;
        promptShowing = false;
        if (cb == null) return true;
        if (res != Activity.RESULT_OK) cb.done(false, "", "canceled");
        else complete(a, uid, enroll, cb);
        return true;
    }

    // ───────────────────────────── ตัวรับผลจาก BiometricPrompt ─────────────────────────────

    /**
     * แปลงรหัสข้อผิดพลาดของ BiometricPrompt เป็น “คีย์สั้น ๆ” (ข้อความไทยอยู่ฝั่งเว็บ)
     *   canceled    = ผู้ใช้กดยกเลิก / หมดเวลา / กดปุ่มลบ
     *   locked      = ยืนยันผิดหลายครั้งเกินไป (ระบบล็อกชั่วคราว)
     *   unavailable = เครื่องไม่พร้อม (ไม่มีเซนเซอร์/ไม่มีรหัสล็อกจอ)
     */
    private static String errKey(int code) {
        switch (code) {
            case BiometricPrompt.BIOMETRIC_ERROR_CANCELED:
            case BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED:
            case BiometricPrompt.BIOMETRIC_ERROR_TIMEOUT:
            case ERR_NEGATIVE_BUTTON:
                return "canceled";
            case BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT:
            case BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT_PERMANENT:
                return "locked";
            case BiometricPrompt.BIOMETRIC_ERROR_HW_UNAVAILABLE:
            case BiometricPrompt.BIOMETRIC_ERROR_HW_NOT_PRESENT:
            case BiometricPrompt.BIOMETRIC_ERROR_NO_BIOMETRICS:
            case BiometricPrompt.BIOMETRIC_ERROR_NO_DEVICE_CREDENTIAL:
                return "unavailable";
            default:
                return "error-" + code;
        }
    }

    /** ⚠️ อ้างคลาส BiometricPrompt ของ API 28 ⇒ สร้างเฉพาะในเส้นทางที่ SDK >= 28 เท่านั้น */
    private static final class PromptCb extends BiometricPrompt.AuthenticationCallback {
        private final Activity act;
        private final String uid;
        private final boolean enroll;
        private final Cb cb;
        private boolean answered;

        PromptCb(Activity act, String uid, boolean enroll, Cb cb) {
            this.act = act;
            this.uid = uid;
            this.enroll = enroll;
            this.cb = cb;
        }

        @Override
        public void onAuthenticationSucceeded(BiometricPrompt.AuthenticationResult result) {
            promptShowing = false;
            if (answered) return;
            answered = true;
            complete(act, uid, enroll, cb);
        }

        @Override
        public void onAuthenticationError(int code, CharSequence msg) {
            promptShowing = false;
            if (answered) return;
            answered = true;
            cb.done(false, "", errKey(code));
        }

        @Override
        public void onAuthenticationFailed() {
            // ยังไม่ปิดหน้าต่าง — ปล่อยให้ผู้ใช้ลองใหม่ (ไม่ตอบกลับ)
        }
    }

}
