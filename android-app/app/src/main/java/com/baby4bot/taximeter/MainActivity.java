package com.baby4bot.taximeter;

import android.Manifest;
import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.util.Log;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.webkit.ConsoleMessage;
import android.webkit.GeolocationPermissions;
import android.webkit.JavascriptInterface;
import android.webkit.PermissionRequest;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.Toast;

import com.google.android.gms.auth.api.signin.GoogleSignIn;
import com.google.android.gms.auth.api.signin.GoogleSignInAccount;
import com.google.android.gms.auth.api.signin.GoogleSignInClient;
import com.google.android.gms.auth.api.signin.GoogleSignInOptions;
import com.google.android.gms.common.api.ApiException;

import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;

/**
 * 📱 เปลือกแอป Android: WebView โหลด "เว็บแอปจริง" จาก GitHub Pages
 *
 * จุดสำคัญที่ต้องมี ไม่งั้นฟีเจอร์เดิมของเว็บจะ "พังเงียบ" บนมือถือ:
 *   1) onGeolocationPermissionsShowPrompt — ถ้าไม่อนุญาต navigator.geolocation จะใช้ไม่ได้เลย
 *   2) onShowFileChooser — ปุ่มอัปโหลดรูป (จอโหลด/QR Code) ต้องเปิดหน้าต่างเลือกรูปได้
 *   3) DOM storage + database — ให้ Firestore (IndexedDB) และ service worker ทำงาน
 *   4) สะพาน JS (window.TaxiNative) — ให้หน้าเว็บเริ่ม/หยุด "บริการเก็บพิกัดฉากหลัง" ได้
 *
 * อัปเดตแอปครั้งต่อไป: แก้ index.html บนเว็บได้เลย ไม่ต้องออก APK ใหม่
 * (ยกเว้นแก้ "ชั้น Android" เช่นสิทธิ์/โค้ด Java นี้ → ต้องออก APK ใหม่)
 */
public class MainActivity extends Activity {

    private static final String TAG = "TaxiMeterApp";
    private static final String FALLBACK_URL = "https://baby4bot.github.io/taxi/";
    private static final String PREFS = "taxi_native";
    private static final int REQ_PERMS = 1001;
    private static final int REQ_FILE = 1002;
    private static final int REQ_GOOGLE = 1003;
    // 🔓 (20 ก.ย. 69) คำขอ “ยืนยันด้วยรหัสเครื่อง” ผ่านหน้า Keyguard (ดู DeviceUnlock.REQ)

    private WebView web;
    private ValueCallback<Uri[]> filePathCallback;
    private boolean pendingTracking = false;

    // ───────────────────────── lifecycle ─────────────────────────

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        try {
            getWindow().setStatusBarColor(0xFF090A0F);
            getWindow().setNavigationBarColor(0xFF090A0F);
        } catch (Exception ignored) {
        }
        if (BuildConfig.DEBUG) {
            WebView.setWebContentsDebuggingEnabled(true);   // เปิด chrome://inspect เพื่อดีบักได้
        }

        web = new WebView(this);
        web.setLayoutParams(new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        web.setBackgroundColor(0xFF090A0F);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setGeolocationEnabled(true);              // จำเป็นสำหรับ WebView (deprecated เฉย ๆ ไม่ใช่ใช้งานไม่ได้)
        s.setAllowFileAccess(false);                // ⛔ ไม่เปิด file:// — ปลอดภัยกว่า และไม่กระทบการอัปโหลด (ใช้ SAF)
        s.setAllowContentAccess(true);
        s.setLoadWithOverviewMode(false);
        s.setUseWideViewPort(false);
        s.setBuiltInZoomControls(false);
        s.setDisplayZoomControls(false);
        s.setSupportZoom(false);
        s.setTextZoom(100);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setCacheMode(WebSettings.LOAD_DEFAULT);   // ปล่อยให้ sw.js จัดการ "ได้เวอร์ชันใหม่เสมอ" (network-first)
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        s.setUserAgentString(s.getUserAgentString() + " TaxiMeterApp/" + BuildConfig.VERSION_NAME);

        web.addJavascriptInterface(new Bridge(), "TaxiNative");

        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest req) {
                return handleUrl(req.getUrl());
            }

            @Override
            @SuppressWarnings("deprecation")
            public boolean shouldOverrideUrlLoading(WebView v, String url) {
                return handleUrl(Uri.parse(url));
            }

            @Override
            public void onPageFinished(WebView v, String url) {
                Log.i(TAG, "page finished: " + url);
            }
        });

        web.setWebChromeClient(new WebChromeClient() {
            // 🔴 ข้อ 1: ต้องอนุญาตตำแหน่งให้ origin นี้ ไม่งั้น navigator.geolocation ล้มเหลวทั้งแอป
            @Override
            public void onGeolocationPermissionsShowPrompt(String origin, GeolocationPermissions.Callback cb) {
                cb.invoke(origin, true, true);
            }

            // 🔴 ข้อ 2: ปุ่มอัปโหลดรูปในเว็บ (จอโหลด/QR) ต้องเปิดหน้าต่างเลือกรูปได้
            @Override
            public boolean onShowFileChooser(WebView v, ValueCallback<Uri[]> cb, FileChooserParams params) {
                if (filePathCallback != null) {
                    filePathCallback.onReceiveValue(null);
                    filePathCallback = null;
                }
                filePathCallback = cb;
                try {
                    Intent i = new Intent(Intent.ACTION_GET_CONTENT);
                    i.addCategory(Intent.CATEGORY_OPENABLE);
                    i.setType("image/*");
                    i.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
                    startActivityForResult(Intent.createChooser(i, "เลือกรูป"), REQ_FILE);
                    return true;
                } catch (Exception e) {
                    filePathCallback = null;
                    Toast.makeText(MainActivity.this, "เปิดหน้าต่างเลือกรูปไม่ได้", Toast.LENGTH_SHORT).show();
                    return false;
                }
            }

            // ไม่อนุญาตกล้อง/ไมค์ (แอปนี้ไม่ใช้) — ถ้าไม่ได้เขียนไว้ WebView จะถามผู้ใช้เองแบบกำกวม
            @Override
            public void onPermissionRequest(PermissionRequest req) {
                req.deny();
            }

            // ส่งข้อความจาก console ของหน้าเว็บเข้า logcat — ใช้ไล่ปัญหาบนมือถือจริงได้
            @Override
            public boolean onConsoleMessage(ConsoleMessage m) {
                Log.d(TAG, "console[" + m.messageLevel() + "] " + m.message());
                return true;
            }
        });

        setContentView(web);
        if (saved != null) {
            web.restoreState(saved);
        } else {
            web.loadUrl(appUrl());
        }
        requestNeededPermissions();
    }

    /** URL ของเว็บแอป — เปลี่ยนชั่วคราวได้จากในแอป (TaxiNative.setAppUrl) ไว้ทดสอบกับเซิร์ฟเวอร์ในเครื่อง */
    private String appUrl() {
        SharedPreferences sp = getSharedPreferences(PREFS, MODE_PRIVATE);
        String u = sp.getString("app_url", null);
        if (u == null || u.trim().isEmpty()) u = BuildConfig.APP_URL;
        if (u == null || u.trim().isEmpty()) u = FALLBACK_URL;
        return u;
    }

    // ───────────────── 🌐 เปิดลิงก์นอกแอป (สำรองเวลาดาวน์โหลด/ติดตั้งในแอปทำไม่ได้) ─────────────────
    private void openInBrowser(String url) {
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
        } catch (Exception ignored) {
        }
    }

    // ───────────────── 📦 ดาวน์โหลด APK รุ่นใหม่ + เปิดหน้าติดตั้งให้ (18 ก.ย. 2026) ─────────────────
    //  ทำไมต้องมี: ผู้ใช้ขอ "ให้แอปรู้ว่ามีรุ่นใหม่ แล้วดาวน์โหลด/ติดตั้งให้เลย"
    //  ความจริงของ Android ที่ต้องบอกตรง ๆ: แอปทั่วไป "ติดตั้งเงียบ" ไม่ได้ — ระบบจะให้ผู้ใช้กด
    //  "ติดตั้ง" ยืนยันเสมอ 1 ครั้ง (ยกเว้นแอปแบบ MDM/เจ้าของเครื่อง) ⇒ สิ่งที่ทำให้ได้คือ
    //  ดาวน์โหลดให้เองเสร็จ แล้ว "เปิดหน้าติดตั้ง" ให้ทันที เหลือแค่กดครั้งเดียว
    //  ⚠️ ยังต้องให้ผู้ใช้เปิด "ติดตั้งจากแหล่งที่ไม่รู้จัก" ให้แอปนี้ (ปุ่มในเว็บเรียกให้เปิดหน้าตั้งค่าได้)
    private static final long APK_MAX_BYTES = 60L * 1024 * 1024;   // กันไฟล์ผิดขนาด (APK จริง ~3-4 MB)

    private File apkCacheDir() {
        File d = new File(getCacheDir(), ApkFileProvider.APK_DIR);
        if (!d.exists()) d.mkdirs();
        return d;
    }

    /** ดาวน์โหลด APK (เธรดแยก — ห้ามทำในเธรด UI) แล้วเรียกติดตั้งบนเธรด UI */
    private void downloadApkInBackground(final String url) {
        final String u = url == null ? "" : url.trim();
        if (u.isEmpty()) {
            runOnUiThread(() -> Toast.makeText(MainActivity.this, "ไม่มีลิงก์ดาวน์โหลด", Toast.LENGTH_SHORT).show());
            return;
        }
        runOnUiThread(() -> Toast.makeText(MainActivity.this, "กำลังดาวน์โหลดรุ่นใหม่…", Toast.LENGTH_SHORT).show());
        new Thread(() -> {
            File out = new File(apkCacheDir(), "update.apk");
            try {
                HttpURLConnection c = (HttpURLConnection) new URL(u).openConnection();   // GitHub Release → 302 ไป CDN
                c.setInstanceFollowRedirects(true);
                c.setConnectTimeout(15000);
                c.setReadTimeout(60000);
                c.setRequestProperty("User-Agent", "TaxiMeterApp/" + BuildConfig.VERSION_NAME);
                int code = c.getResponseCode();
                if (code != 200) throw new IOException("HTTP " + code);
                long total = 0;
                try (InputStream in = c.getInputStream(); FileOutputStream fo = new FileOutputStream(out)) {
                    byte[] buf = new byte[16384];
                    int n;
                    while ((n = in.read(buf)) > 0) {
                        total += n;
                        if (total > APK_MAX_BYTES) throw new IOException("ไฟล์ใหญ่เกินคาด");
                        fo.write(buf, 0, n);
                    }
                }
                if (total < 1024 * 100) throw new IOException("ไฟล์เล็กเกินไป (" + total + " ไบต์)");
                final long size = total;
                Log.i(TAG, "downloaded apk: " + size + " bytes -> " + out.getAbsolutePath());
                runOnUiThread(() -> installDownloadedApk(out, u));
            } catch (Exception e) {
                Log.w(TAG, "download apk failed: " + e.getMessage());
                final String msg = String.valueOf(e.getMessage());
                runOnUiThread(() -> {
                    Toast.makeText(MainActivity.this, "ดาวน์โหลดในแอปไม่สำเร็จ — เปิดลิงก์ดาวน์โหลดให้แทน", Toast.LENGTH_LONG).show();
                    Log.w(TAG, "reason: " + msg);
                    openInBrowser(u);
                });
            }
        }).start();
    }

    /** เปิดหน้าติดตั้งของระบบด้วยไฟล์ที่โหลดไว้ (ต้องใช้ content:// จาก ApkFileProvider) */
    private void installDownloadedApk(File apk, String fallbackUrl) {
        try {
            if (apk == null || !apk.isFile()) throw new IOException("ไม่พบไฟล์ที่ดาวน์โหลด");
            Uri uri = Uri.parse("content://" + getPackageName() + ApkFileProvider.AUTHORITY_SUFFIX + "/" + apk.getName());
            Intent i = new Intent(Intent.ACTION_VIEW);
            i.setDataAndType(uri, "application/vnd.android.package-archive");
            i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(i);
        } catch (Exception e) {
            Toast.makeText(this, "เปิดหน้าติดตั้งไม่ได้ — เปิดลิงก์ดาวน์โหลดให้แทน", Toast.LENGTH_LONG).show();
            openInBrowser(fallbackUrl);
        }
    }

    /** คุมว่า URL ไหน "อยู่ในแอป" และ URL ไหน "ออกไปเบราว์เซอร์" */
    private boolean handleUrl(Uri u) {
        if (u == null) return false;
        String host = u.getHost() == null ? "" : u.getHost().toLowerCase();
        String scheme = u.getScheme() == null ? "" : u.getScheme().toLowerCase();

        if (scheme.equals("http") || scheme.equals("https")) {
            // เว็บของเรา + บริการที่หน้าเว็บใช้ → อยู่ในแอป
            if (host.endsWith("baby4bot.github.io")
                    || host.equals("localhost")
                    || host.equals("127.0.0.1")
                    || host.endsWith("firebaseapp.com")
                    || host.endsWith("firebaseio.com")
                    || host.endsWith("googleapis.com")
                    || host.endsWith("gstatic.com")
                    || host.endsWith("jsdelivr.net")
                    || host.endsWith("i.ibb.co")
                    || host.endsWith("tomtom.com")
                    || host.endsWith("googleusercontent.com")) {
                return false;
            }
            // หน้าล็อกอิน Google ถูกบล็อกใน WebView (นโยบายของ Google) → ส่งออกเบราว์เซอร์จริง
            //    ⇒ ในแอป Android ให้เข้าใช้ด้วย "ไอดี + รหัสผ่าน" หรือ PIN (ดูข้อจำกัดใน README)
            try {
                startActivity(new Intent(Intent.ACTION_VIEW, u));
            } catch (Exception ignored) {
            }
            return true;
        }
        // เบอร์โทร/LINE ฯลฯ — ให้ระบบจัดการ
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, u));
        } catch (Exception ignored) {
        }
        return true;
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        // 🔓 ผลจากหน้า “ยืนยันรหัสเครื่อง” (Android 8–9 หรือเครื่องที่ไม่มีเซนเซอร์) — คืนผลให้หน้าเว็บต่อ
        if (DeviceUnlock.onActivityResult(this, req, res)) return;
        if (req == REQ_GOOGLE) {
            try {
                GoogleSignInAccount acc = GoogleSignIn.getSignedInAccountFromIntent(data).getResult(ApiException.class);
                sendGoogleResult(acc, null);
            } catch (ApiException e) {
                // 12501 = ผู้ใช้กดยกเลิก · 10 = DEVELOPER_ERROR (ยังไม่ได้เพิ่มแอป/SHA-1 ในคอนโซล)
                sendGoogleResult(null, "google-signin-" + e.getStatusCode());
            } catch (Exception e) {
                sendGoogleResult(null, "google-signin-unknown");
            }
            return;
        }
        if (req == REQ_FILE) {
            Uri[] out = null;
            if (res == RESULT_OK && data != null) {
                if (data.getClipData() != null) {
                    int n = data.getClipData().getItemCount();
                    ArrayList<Uri> list = new ArrayList<>();
                    for (int i = 0; i < n; i++) list.add(data.getClipData().getItemAt(i).getUri());
                    out = list.toArray(new Uri[0]);
                } else if (data.getData() != null) {
                    out = new Uri[]{data.getData()};
                }
            }
            if (filePathCallback != null) {
                filePathCallback.onReceiveValue(out);
                filePathCallback = null;
            }
            return;
        }
        super.onActivityResult(req, res, data);
    }

    @Override
    protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        if (web != null) web.saveState(out);
    }

    // ⛔ จงใจไม่เรียก web.onPause()/onResume(): ต้องการให้หน้าเว็บ "มีชีวิต" ต่อมากที่สุด
    //    (ตัว Chromium ยังแช่แข็งเองตามนโยบายของระบบ — พิกัดช่วงนั้นอยู่ในคิวของ BgLocationService แล้ว)

    @Override
    @SuppressWarnings("deprecation")
    public void onBackPressed() {
        if (web != null && web.canGoBack()) web.goBack();
        else moveTaskToBack(true);   // ย่อแอป ไม่ปิด (คนขับมักกลับมาใช้ต่อ)
    }

    // ───────────────────── 🔐 ล็อกอิน Google แบบ native (18 ก.ย. 2026) ─────────────────────
    //  ทำไมต้องมี: Google ห้ามหน้า OAuth ใน WebView (นโยบาย) ⇒ ล็อกอินในเว็บวิวทำไม่ได้เลย
    //  วิธีที่ถูกต้อง: เปิดหน้าล็อกอินของ Google ในชั้น Android (Play Services) → ได้ idToken
    //                 → ส่ง idToken กลับเข้าเว็บ → ฝั่งเว็บเรียก signInWithCredential(...) ของ Firebase
    //  ต้องมีในคอนโซล Firebase: เพิ่มแอป Android (แพ็กเกจนี้ + SHA-1 ของกุญแจเซ็น) และส่ง “Web client ID” จากฝั่งเว็บมา
    private GoogleSignInClient googleClient(String serverClientId) {
        GoogleSignInOptions opts = new GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN)
                .requestIdToken(serverClientId)   // ⭐ audience = Web client ID ⇒ Firebase ยอมรับ
                .requestEmail()
                .build();
        return GoogleSignIn.getClient(this, opts);
    }

    /** เรียกจาก JS: TaxiNative.googleSignIn('<Web client ID>') — เลือกบัญชีทุกครั้ง (เหมือน prompt: select_account) */
    private void startNativeGoogleSignIn(final String serverClientId) {
        final String cid = serverClientId == null ? "" : serverClientId.trim();
        if (cid.isEmpty()) { sendGoogleResult(null, "missing-client-id"); return; }
        try {
            final GoogleSignInClient client = googleClient(cid);
            client.signOut().addOnCompleteListener(task -> {
                try {
                    startActivityForResult(client.getSignInIntent(), REQ_GOOGLE);
                } catch (Exception e) {
                    sendGoogleResult(null, "cannot-open-google");
                }
            });
        } catch (Exception e) {
            sendGoogleResult(null, "google-unavailable");
        }
    }

    /** ส่งผลลัพธ์กลับเข้าเว็บ: window.__onNativeGoogleResult(ok, errCode, payload) */
    private void sendGoogleResult(GoogleSignInAccount acc, String errCode) {
        String err = errCode;
        String idToken = acc == null ? null : acc.getIdToken();
        if (err == null && (idToken == null || idToken.isEmpty())) err = "no-id-token";
        JSONObject payload = null;
        if (acc != null) {
            payload = new JSONObject();
            try {
                payload.put("idToken", idToken == null ? "" : idToken);
                payload.put("email", acc.getEmail() == null ? "" : acc.getEmail());
                payload.put("name", acc.getDisplayName() == null ? "" : acc.getDisplayName());
                Uri photo = acc.getPhotoUrl();
                payload.put("photo", photo == null ? "" : photo.toString());
            } catch (Exception ignored) {
            }
        }
        String js = "window.__onNativeGoogleResult(" + (err == null ? "true" : "false") + ","
                + (err == null ? "null" : JSONObject.quote(err)) + ","
                + (payload == null ? "null" : payload.toString()) + ");";
        final String script = js;
        runOnUiThread(() -> {
            try {
                if (web != null) web.evaluateJavascript(script, null);
            } catch (Exception ignored) {
            }
        });
    }

    /** 🔓 ส่งผลลัพธ์ของ “ปลดล็อกด้วยเครื่อง” กลับให้หน้าเว็บ (เธรด UI ของแอป) */
    private void sendDeviceUnlockResult(String reqId, boolean ok, String credId, String err) {
        final String script = "window.__onNativeDeviceUnlock(" + JSONObject.quote(reqId == null ? "" : reqId) + ","
                + (ok ? "true" : "false") + ","
                + JSONObject.quote(credId == null ? "" : credId) + ","
                + (err == null ? "null" : JSONObject.quote(err)) + ");";
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                try {
                    if (web != null) web.evaluateJavascript(script, null);
                } catch (Exception ignored) {
                }
            }
        });
    }

    /** 🔓 ตัวรับผลจากชั้น DeviceUnlock → แปลงเป็นสคริปต์ให้หน้าเว็บ (เรียกจาก UI thread แล้ว) */
    private DeviceUnlock.Cb deviceUnlockCb(final String reqId) {
        return new DeviceUnlock.Cb() {
            @Override
            public void done(boolean ok, String credId, String err) {
                sendDeviceUnlockResult(reqId, ok, credId, err);
            }
        };
    }

    // 🔋 (18 ก.ย. 69) ขอยกเว้น "การประหยัดแบตเตอรี่" หนึ่งครั้งต่อการติดตั้ง — ครั้งแรกที่เริ่มจับเที่ยว
    //    ทำไมต้องมี: ถ้าไม่ยกเว้น ระบบจะเข้าสู่ Doze เมื่อจอดับ → หยุดส่งพิกัดให้แอป
    //    ⇒ ช่วงนั้นแอปไม่มีหลักฐานว่าวิ่งหรือจอด = "เวลารถติด" เพี้ยน (ต้นเหตุที่ผู้ใช้แจ้ง)
    private void askBackgroundPermissionOnce() {
        try {
            if (Build.VERSION.SDK_INT < 23) return;
            SharedPreferences sp = getSharedPreferences(PREFS, MODE_PRIVATE);
            if (sp.getBoolean("asked_bg", false)) return;
            sp.edit().putBoolean("asked_bg", true).apply();
            android.os.PowerManager pm = (android.os.PowerManager) getSystemService(POWER_SERVICE);
            if (pm != null && pm.isIgnoringBatteryOptimizations(getPackageName())) return;   // ยกเว้นอยู่แล้ว
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    try {
                        Toast.makeText(MainActivity.this,
                                "เพื่อให้เก็บพิกัดแม่นแม้ปิดจอ — กรุณากด “อนุญาต” ในหน้าต่างถัดไป",
                                Toast.LENGTH_LONG).show();
                        Intent i = new Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
                        i.setData(Uri.parse("package:" + getPackageName()));
                        startActivity(i);
                    } catch (Exception ignored) {
                    }
                }
            });
        } catch (Exception ignored) {
        }
    }

    private boolean hasFineLocation() {
        return checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    private void requestNeededPermissions() {
        ArrayList<String> need = new ArrayList<>();
        if (!hasFineLocation()) {
            need.add(Manifest.permission.ACCESS_FINE_LOCATION);
            need.add(Manifest.permission.ACCESS_COARSE_LOCATION);
        }
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission("android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED) {
            need.add("android.permission.POST_NOTIFICATIONS");
        }
        if (!need.isEmpty()) {
            requestPermissions(need.toArray(new String[0]), REQ_PERMS);
        }
    }

    @Override
    public void onRequestPermissionsResult(int req, String[] perms, int[] grants) {
        super.onRequestPermissionsResult(req, perms, grants);
        if (req != REQ_PERMS) return;
        if (pendingTracking && hasFineLocation()) {
            pendingTracking = false;
            BgLocationService.start(this);
        }
    }

    // ─────────────────── สะพานให้หน้าเว็บเรียกใช้ (window.TaxiNative) ───────────────────
    // ⚠️ เมธอดในคลาสนี้ถูกเรียกจาก "เธรดของ WebView" ไม่ใช่ UI thread ⇒ ห้ามแตะ UI ตรง ๆ
    public class Bridge {

        @JavascriptInterface
        public boolean isNativeApp() {
            return true;
        }

        // ─────────────────────────── 🔓 ปลดล็อกด้วยเครื่อง (ลายนิ้วมือ/ใบหน้า/รหัสเครื่อง) ───────────────────────────
        //  ทำไมต้องมีสะพานนี้: WebAuthn (navigator.credentials) ใช้ใน Android WebView ไม่ได้
        //  ⇒ บน APK ปุ่ม “ลงทะเบียนปลดล็อกด้วยเครื่อง” เดิมขึ้นว่าใช้ไม่ได้ทุกครั้ง (ผู้ใช้แจ้ง 20 ก.ย. 69)
        //  ฝั่งเว็บตัดสินใจจาก hasNativeDeviceUnlock() → ใช้เส้นทางนี้แทน WebAuthn

        /** APK รุ่นนี้มีสะพานปลดล็อกด้วยเครื่องหรือยัง (รุ่นเก่าจะไม่มีเมธอดนี้ → undefined) */
        @JavascriptInterface
        public boolean hasNativeDeviceUnlock() {
            return true;
        }

        /** เครื่องนี้มีลายนิ้วมือ/ใบหน้า/รหัสเครื่องให้ใช้ไหม */
        @JavascriptInterface
        public boolean deviceUnlockAvailable() {
            return DeviceUnlock.available(MainActivity.this);
        }

        /** ลงทะเบียนเครื่องนี้ให้บัญชี uid — ผลลัพธ์ส่งกลับทาง window.__onNativeDeviceUnlock(reqId, ok, credId, err) */
        @JavascriptInterface
        public void deviceUnlockEnroll(final String uid, final String reqId) {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    DeviceUnlock.start(MainActivity.this, uid, true, deviceUnlockCb(reqId));
                }
            });
        }

        /** ยืนยันตัวตนด้วยหน้าปลดล็อกของเครื่อง (ต้องลงทะเบียนไว้ก่อน) */
        @JavascriptInterface
        public void deviceUnlockAuth(final String uid, final String reqId) {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    DeviceUnlock.start(MainActivity.this, uid, false, deviceUnlockCb(reqId));
                }
            });
        }

        /** ลงทะเบียนเครื่องนี้ให้บัญชีนี้ไว้แล้วหรือยัง (อ่านจากที่เก็บของแอป — ไม่ใช่ของหน้าเว็บ) */
        @JavascriptInterface
        public boolean deviceUnlockHas(final String uid) {
            return DeviceUnlock.has(MainActivity.this, uid);
        }

        /** ยกเลิกการลงทะเบียนของบัญชีนี้ */
        @JavascriptInterface
        public boolean deviceUnlockRemove(final String uid) {
            return DeviceUnlock.remove(MainActivity.this, uid);
        }

        /** APK รุ่นนี้รองรับล็อกอิน Google ในตัวหรือยัง (ฝั่งเว็บใช้ตัดสินว่าโชว์ปุ่มหรือบอกให้ใช้ไอดี/PIN) */
        @JavascriptInterface
        public boolean hasNativeGoogleSignIn() {
            return true;
        }

        /** เปิดหน้าล็อกอิน Google ของเครื่อง — ผลลัพธ์ส่งกลับทาง window.__onNativeGoogleResult */
        @JavascriptInterface
        public void googleSignIn(final String serverClientId) {
            runOnUiThread(() -> startNativeGoogleSignIn(serverClientId));
        }

        /** 🔋 ยกเว้น "การประหยัดแบตเตอรี่" แล้วหรือยัง — ฝั่งเว็บใช้แสดงสถานะ/เตือนคนขับ */
        @JavascriptInterface
        public boolean isIgnoringBatteryOptimizations() {
            try {
                if (Build.VERSION.SDK_INT < 23) return true;
                android.os.PowerManager pm = (android.os.PowerManager) getSystemService(POWER_SERVICE);
                return pm != null && pm.isIgnoringBatteryOptimizations(getPackageName());
            } catch (Exception e) {
                return false;
            }
        }

        /** เปิดหน้าต่างของระบบให้ผู้ใช้อนุญาตทำงานฉากหลัง (เรียกซ้ำได้ทุกเมื่อ) */
        @JavascriptInterface
        public void requestIgnoreBatteryOptimizations() {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    try {
                        if (Build.VERSION.SDK_INT < 23) return;
                        android.os.PowerManager pm = (android.os.PowerManager) getSystemService(POWER_SERVICE);
                        if (pm != null && pm.isIgnoringBatteryOptimizations(getPackageName())) {
                            Toast.makeText(MainActivity.this, "ได้รับอนุญาตอยู่แล้ว — จับพิกัดฉากหลังได้เต็มที่", Toast.LENGTH_SHORT).show();
                            return;
                        }
                        Intent i = new Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
                        i.setData(Uri.parse("package:" + getPackageName()));
                        startActivity(i);
                    } catch (Exception ignored) {
                        try {
                            openSystemAppSettings();
                        } catch (Exception ignored2) {
                        }
                    }
                }
            });
        }

        @JavascriptInterface
        public String platform() {
            return "android-webview";
        }

        @JavascriptInterface
        public int androidSdk() {
            return Build.VERSION.SDK_INT;
        }

        @JavascriptInterface
        public String appVersion() {
            return BuildConfig.VERSION_NAME + " (" + BuildConfig.VERSION_CODE + ")";
        }

        /** 🔢 รหัสรุ่นของ APK ที่ติดตั้งอยู่ (ตัวเลขล้วน — ใช้เทียบกับ apk-version.json ได้ตรง ๆ) */
        @JavascriptInterface
        public int appVersionCode() {
            return BuildConfig.VERSION_CODE;
        }

        /** 🏷 ชื่อรุ่นที่มนุษย์อ่านได้ เช่น "1.4.0" (ไว้แสดงบนป้ายเตือนเท่านั้น) */
        @JavascriptInterface
        public String appVersionName() {
            return BuildConfig.VERSION_NAME;
        }

        /** ผู้ใช้เปิดสิทธิ์ "ติดตั้งจากแหล่งที่ไม่รู้จัก" ให้แอปนี้แล้วหรือยัง (Android 8+ เท่านั้นที่ต้องขอ) */
        @JavascriptInterface
        public boolean canInstallPackages() {
            try {
                if (Build.VERSION.SDK_INT >= 26) return getPackageManager().canRequestPackageInstalls();
                return true;
            } catch (Exception e) {
                return true;   // อ่านไม่ได้ = อย่าบล็อกผู้ใช้ ให้ลองเปิดหน้าติดตั้งแทน
            }
        }

        /** เปิดหน้าตั้งค่า "ติดตั้งแอปที่ไม่รู้จัก" ของแอปนี้ (เรียกก่อนติดตั้งครั้งแรก) */
        @JavascriptInterface
        public void openInstallPermissionSettings() {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    try {
                        if (Build.VERSION.SDK_INT >= 26) {
                            Intent i = new Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + getPackageName()));
                            startActivity(i);
                            return;
                        }
                    } catch (Exception ignored) {
                    }
                    openSystemAppSettings();
                }
            });
        }

        /** 🏷 ยี่ห้อเครื่อง (Build.MANUFACTURER) — ฝั่งเว็บใช้ปรับคำเตือนเฉพาะรุ่น เช่น Samsung Auto Blocker
         *  ⚠️ userAgent ของ WebView บอกยี่ห้อเครื่องไม่ได้ ⇒ ต้องถามสะพานนี้ (ตัวพิมพ์เล็กเสมอ) */
        @JavascriptInterface
        public String deviceBrand() {
            try {
                String b = Build.MANUFACTURER;
                return (b == null) ? "" : b.toLowerCase(java.util.Locale.ROOT);
            } catch (Exception e) {
                return "";
            }
        }

        /** 🧱 เครื่อง Samsung (One UI 6+) มี “ตัวบล็อกอัตโนมัติ (Auto Blocker)” ที่บล็อกการติดตั้ง APK
         *  ⇒ ถ้าเปิดอยู่ กด “ติดตั้งทันที” แล้วจะ “เงียบ” ไม่ขึ้นอะไรเลย (ผู้ใช้หาสาเหตุไม่ได้)
         *  วิธีหา: ค้น activity ที่ชื่อเกี่ยวกับ autoblock ในแอปตั้งค่าของเครื่องก่อน (แม่นสุด — ไม่ต้องเดาชื่อ)
         *  แล้วค่อยไล่ทางสำรอง: component ที่รู้จัก → Security & privacy → หน้าอนุญาตติดตั้งจากแหล่งที่ไม่รู้จัก */
        @JavascriptInterface
        public void openAutoBlockerSettings() {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    try {
                        ComponentName autoBlocker = findAutoBlockerActivity();
                        if (autoBlocker != null) {
                            Intent i = new Intent();
                            i.setComponent(autoBlocker);
                            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                            if (startActivitySafely(i)) {
                                toastShort("ปิด “ตัวบล็อกอัตโนมัติ” แล้วกลับมากดติดตั้งอีกครั้ง");
                                return;
                            }
                        }
                        String[][] candidates = new String[][]{
                                {"com.samsung.android.settings", "com.samsung.android.settings.autoblocker.AutoBlockerActivity"},
                                {"com.samsung.android.settings", "com.samsung.android.settings.autoblocker.AutoBlockerTopActivity"},
                                {"com.samsung.android.settings", "com.samsung.android.settings.Settings$AutoBlockerSettingsActivity"}
                        };
                        for (String[] c : candidates) {
                            Intent i = new Intent();
                            i.setComponent(new ComponentName(c[0], c[1]));
                            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                            if (startActivitySafely(i)) {
                                toastShort("ปิด “ตัวบล็อกอัตโนมัติ” แล้วกลับมากดติดตั้งอีกครั้ง");
                                return;
                            }
                        }
                        if (startActivitySafely(new Intent("android.settings.SECURITY_SETTINGS"))) {
                            toastShort("เปิด “ความปลอดภัยและความเป็นส่วนตัว” ให้แล้ว — เลือก “ตัวบล็อกอัตโนมัติ” แล้วปิด");
                            return;
                        }
                        openInstallPermissionSettings();
                        toastShort("เปิดหน้าตั้งค่าให้แล้ว — ปิด “ตัวบล็อกอัตโนมัติ” แล้วติดตั้งอีกครั้ง");
                    } catch (Exception e) {
                        try {
                            openInstallPermissionSettings();
                        } catch (Exception ignored) {
                        }
                    }
                }
            });
        }

        /** 🔎 หา activity ของ “ตัวบล็อกอัตโนมัติ” ในแอปตั้งค่าของเครื่อง (คืน null = ไม่เจอ)
         *  ต้องมี <queries> ของ package นี้ใน manifest ไม่งั้น Android 11+ จะไม่ให้มองเห็น activity */
        private ComponentName findAutoBlockerActivity() {
            ComponentName anyMatch = null;
            String[] pkgs = new String[]{"com.samsung.android.settings", "com.android.settings"};
            for (String pkg : pkgs) {
                try {
                    android.content.pm.PackageInfo pi = getPackageManager().getPackageInfo(pkg, PackageManager.GET_ACTIVITIES);
                    if (pi == null || pi.activities == null) continue;
                    for (android.content.pm.ActivityInfo a : pi.activities) {
                        if (a == null || a.name == null) continue;
                        String n = a.name.toLowerCase(java.util.Locale.ROOT);
                        if (!n.contains("autoblock")) continue;
                        // ตัวที่เปิดให้แอปอื่นเรียกได้ = ใช้เลย · ตัวที่ไม่ exported เก็บไว้ลองเป็นทางเลือกท้ายสุด (เผื่อรุ่นที่ไม่ได้ตั้งค่าไว้)
                        if (a.exported) return new ComponentName(pkg, a.name);
                        if (anyMatch == null) anyMatch = new ComponentName(pkg, a.name);
                    }
                } catch (Exception ignored) {
                }
            }
            return anyMatch;
        }

        private boolean startActivitySafely(Intent i) {
            try {
                startActivity(i);
                return true;
            } catch (Exception e) {
                return false;
            }
        }

        private void toastShort(final String msg) {
            try {
                Toast.makeText(MainActivity.this, msg, Toast.LENGTH_SHORT).show();
            } catch (Exception ignored) {
            }
        }

        /** 📦 ดาวน์โหลด APK รุ่นใหม่แล้วเปิดหน้าติดตั้งให้ (เว็บเรียกตอนผู้ใช้กด "ติดตั้งทันที")
         *  สำเร็จหรือไม่ ฝั่งเว็บรู้จาก canInstallPackages() และจากพฤติกรรมจริง (มี toast บอกผู้ใช้) */
        @JavascriptInterface
        public void downloadAndInstallApk(final String url) {
            downloadApkInBackground(url == null ? "" : url.trim());
        }

        @JavascriptInterface
        public String getAppUrl() {
            return appUrl();
        }

        /** เปลี่ยน URL ที่โหลด (ไว้ทดสอบกับเซิร์ฟเวอร์ในเครื่อง) — ส่งสตริงว่าง = กลับไปค่าเดิม */
        @JavascriptInterface
        public void setAppUrl(final String url) {
            SharedPreferences sp = getSharedPreferences(PREFS, MODE_PRIVATE);
            String v = url == null ? "" : url.trim();
            sp.edit().putString("app_url", v).apply();
        }

        @JavascriptInterface
        public void reload() {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    if (web != null) web.reload();
                }
            });
        }

        /**
         * ย่อแอปไปอยู่เบื้องหลัง (เหมือนกดปุ่ม Home) — ไม่ปิดแอป ไม่หยุดมิเตอร์/จีพีเอส
         * ใช้เมื่อผู้ใช้กด “ย้อนกลับ” หรือ ESC บนจอมิเตอร์ใหญ่ (ฝั่งเว็บเรียก TaxiNative.minimizeApp())
         * ⇒ แทนพฤติกรรมเดิมที่ปิดจอมิเตอร์แล้วไปโผล่หน้าแรกซึ่งซ้ำซ้อนกับจอมิเตอร์ใหญ่
         */
        @JavascriptInterface
        public void minimizeApp() {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    moveTaskToBack(true);
                }
            });
        }

        @JavascriptInterface
        public boolean hasLocationPermission() {
            return hasFineLocation();
        }

        @JavascriptInterface
        public void requestLocationPermission() {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    requestNeededPermissions();
                }
            });
        }

        /** เริ่มเก็บพิกัดฉากหลัง (เรียกตอนเริ่มจับเที่ยว) — คืน false ถ้ายังไม่มีสิทธิ์ตำแหน่ง */
        @JavascriptInterface
        public boolean startTracking() {
            if (!hasFineLocation()) {
                pendingTracking = true;
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        requestNeededPermissions();
                    }
                });
                return false;
            }
            BgLocationService.start(MainActivity.this);
            askBackgroundPermissionOnce();   // 🔋 ขอยกเว้นการประหยัดแบตฯ ครั้งแรก (เก็บพิกัดฉากหลังจะไม่ถูกระงับ)
            return true;
        }

        /** หยุดเก็บพิกัด (เรียกตอนจบเที่ยว) */
        @JavascriptInterface
        public void stopTracking() {
            BgLocationService.stop(MainActivity.this);
        }

        @JavascriptInterface
        public boolean isTracking() {
            return BgLocationService.isRunning();
        }

        /** เบิกพิกัดที่เก็บไว้ทั้งหมด (JSON array) แล้วล้างคิว — หน้าเว็บเรียกเป็นระยะ */
        @JavascriptInterface
        public String drainFixes() {
            return BgLocationService.drainJson();
        }

        /** ดูสถานะอย่างเดียว ไม่ล้างคิว */
        @JavascriptInterface
        public String peekStats() {
            return BgLocationService.statsJson();
        }

        /** บริการมีธง "ควรเก็บพิกัดอยู่" ค้างไว้หรือยัง (รอดข้ามการถูกฆ่า/ปัดแอปทิ้ง) */
        @JavascriptInterface
        public boolean trackingWanted() {
            return BgLocationService.wantOn(MainActivity.this);
        }

        @JavascriptInterface
        public void clearFixes() {
            BgLocationService.clear();
        }

        /** บังคับจอค้าง (สำรองของ Wake Lock API) — ค่าเริ่มต้นของแอปคือให้หน้าเว็บเป็นคนสั่ง */
        @JavascriptInterface
        public void setKeepScreenOn(final boolean on) {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    try {
                        if (on) {
                            getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                        } else {
                            getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                        }
                    } catch (Exception ignored) {
                    }
                }
            });
        }

        @JavascriptInterface
        public void vibrate(final int ms) {
            try {
                Vibrator v = (Vibrator) getSystemService(VIBRATOR_SERVICE);
                if (v == null || !v.hasVibrator()) return;
                int d = ms <= 0 ? 120 : (ms > 2000 ? 2000 : ms);
                v.vibrate(VibrationEffect.createOneShot(d, VibrationEffect.DEFAULT_AMPLITUDE));
            } catch (Exception ignored) {
            }
        }

        /** เปิดหน้าตั้งค่าแอปของระบบ (ให้ผู้ใช้เปิดสิทธิ์ตำแหน่ง/แจ้งเตือนเอง) */
        @JavascriptInterface
        public void openSystemAppSettings() {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    try {
                        Intent i = new Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
                        i.setData(Uri.parse("package:" + getPackageName()));
                        startActivity(i);
                    } catch (Exception ignored) {
                    }
                }
            });
        }

        // ───────────────────────── 🚗 จอรถ (Android Auto) ─────────────────────────
        // ตัวเลขมิเตอร์อยู่ในหน้าเว็บ แต่จอรถวาดด้วย Car App Library ⇒ หน้าเว็บ “ประกาศ”
        // สแนปช็อตสั้น ๆ ทุกราว 2 วินาที แล้วฝั่งจอรถดึงไปวาด (ดู CarMeterState + MeterCarScreen)

        /**
         * หน้าเว็บประกาศตัวเลขล่าสุดให้จอรถ (เรียกทุกราว 2 วินาที)
         * json = {running?, paused?, km?, trafficSec?, fare?, remainKm?, dest?, at?}
         */
        @JavascriptInterface
        public void publishCarState(final String json) {
            try {
                CarMeterState.publish(getApplicationContext(), json);
            } catch (Exception ignored) {
            }
        }

        /**
         * หน้าเว็บเบิกคำสั่งที่กดจากจอรถ ("" = ไม่มี)
         * ค่าที่เป็นไปได้: pause · resume · finish — หน้าเว็บ polls ทุกราว 2 วินาที
         */
        @JavascriptInterface
        public String takeCarCommand() {
            try {
                return CarMeterState.takeCommand();
            } catch (Exception ignored) {
                return "";
            }
        }

        /** ไว้ตรวจบนเครื่องจริง: มีสแนปช็อตไหม/เก่ากี่วินาที/มีคำสั่งค้างไหม */
        @JavascriptInterface
        public String carStateDebug() {
            try {
                return CarMeterState.debug(getApplicationContext());
            } catch (Exception e) {
                return "{}";
            }
        }
    }
}
