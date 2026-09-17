package com.baby4bot.taximeter;

import android.Manifest;
import android.app.Activity;
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
    }
}
