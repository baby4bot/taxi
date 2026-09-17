package com.baby4bot.taximeter;

import android.app.AlarmManager;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ServiceInfo;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Build;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayDeque;

/**
 * 📍 บริการเก็บพิกัดฉากหลัง (หัวใจของความแม่นเรื่อง "เวลารถติด")
 *
 * ทำไมต้องมี: เบราว์เซอร์/WebView จะ "แช่แข็ง" หน้าเว็บและหยุดส่งพิกัดเมื่อจอดับ/ล็อกจอ/สลับแอป
 * ⇒ ช่วงนั้นแอปไม่รู้เลยว่ารถติดหรือวิ่ง ได้แต่ "เดา" (ต้นเหตุที่เวลารถติดเพี้ยน เช่น 18 นาที)
 *
 * บริการนี้ทำงานเป็น Foreground Service (มีป้ายบนแถบสถานะ) จึงเก็บพิกัดต่อได้จริงแม้จอดับ
 * แล้วเก็บใส่คิวในหน่วยความจำ — หน้าเว็บค่อย "เบิก" ไปใช้เมื่อกลับมา (TaxiNative.drainFixes())
 *
 * ⛔ ห้ามใช้ ACCESS_BACKGROUND_LOCATION: Foreground Service + สิทธิ์ "ขณะใช้งาน" เพียงพอ
 */
public class BgLocationService extends Service implements LocationListener {

    private static final String TAG = "TaxiMeterGps";
    private static final String CH_ID = "taxi_gps";
    private static final int NOTI_ID = 4201;
    private static final int MAX_FIXES = 20000;            // ~8 ชม. ที่ 1 จุด/1.5 วิ
    private static final long WAKE_TIMEOUT_MS = 12L * 60 * 60 * 1000; // กันลืมปิด — ปล่อยเองใน 12 ชม.

    static final String ACTION_START = "com.baby4bot.taximeter.action.START";

    // 🔋 (18 ก.ย. 69) ให้บริการ "อยู่รอด" เป็นโปรแกรมฉากหลังจริง
    //    - PREFS.want = ธงจำว่า "ผู้ใช้ยังจับเที่ยวอยู่ไหม" — ถ้าถูกฆ่า/ปัดทิ้ง เครื่องมือข้างล่างจะปลุกกลับมาได้
    //    - ตัวปลุก (watchdog) ตั้งทุก 15 นาที: ถ้าบริการหายไป จะถูกเรียก onStartCommand ใหม่ = เริ่มเก็บพิกัดต่อ
    private static final String PREFS = "taxi_bg";
    private static final int REQ_WATCHDOG = 7711;
    private static final int REQ_TASK_REMOVED = 7712;
    private static final long WATCHDOG_MS = 15L * 60 * 1000;

    // คิวพิกัด (static = อยู่ได้แม้ activity ถูกทำลาย · เข้าถึงพร้อมกันจากหลายเธรด → synchronized ทุกจุด)
    private static final Object LOCK = new Object();
    private static final ArrayDeque<JSONObject> FIXES = new ArrayDeque<>();
    private static volatile boolean running = false;
    private static volatile long lastFixAt = 0L;

    private LocationManager lm;
    private PowerManager.WakeLock wake;

    static boolean isRunning() {
        return running;
    }

    static void start(Context c) {
        try {
            wantFlag(c, true);
            Intent i = new Intent(c, BgLocationService.class);
            i.setAction(ACTION_START);
            c.startForegroundService(i);
        } catch (Exception e) {
            Log.w(TAG, "start failed: " + e.getMessage());
        }
    }

    static void stop(Context c) {
        try {
            wantFlag(c, false);
            c.stopService(new Intent(c, BgLocationService.class));
        } catch (Exception e) {
            Log.w(TAG, "stop failed: " + e.getMessage());
        }
    }

    /** ธงจำว่า "ควรเก็บพิกัดอยู่ไหม" — เก็บลงดิสก์ เพราะตัวแปรในหน่วยความจำหายเมื่อโปรเซสถูกฆ่า */
    private static void wantFlag(Context c, boolean on) {
        try {
            SharedPreferences sp = c.getSharedPreferences(PREFS, MODE_PRIVATE);
            sp.edit().putBoolean("want", on).apply();
        } catch (Exception ignored) {
        }
    }

    static boolean wantOn(Context c) {
        try {
            return c.getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean("want", false);
        } catch (Exception e) {
            return false;
        }
    }

    static void clear() {
        synchronized (LOCK) {
            FIXES.clear();
        }
    }

    /** เบิกพิกัดทั้งหมดที่เก็บไว้ (คืนเป็น JSON แล้วล้างคิว) — หน้าเว็บเรียกตัวนี้ */
    static String drainJson() {
        JSONArray a = new JSONArray();
        try {
            synchronized (LOCK) {
                while (!FIXES.isEmpty()) {
                    a.put(FIXES.pollFirst());
                }
            }
        } catch (Exception ignored) {
            // org.json บางเวอร์ชันประกาศ throws ไว้ — ห่อไว้กันไม่ให้บริการล้ม
        }
        return a.toString();
    }

    static String statsJson() {
        JSONObject o = new JSONObject();
        try {
            o.put("tracking", running);
            synchronized (LOCK) {
                o.put("count", FIXES.size());
            }
            o.put("lastFixAt", lastFixAt);
            o.put("now", System.currentTimeMillis());
        } catch (Exception ignored) {
        }
        return o.toString();
    }

    @Override
    public void onCreate() {
        super.onCreate();
        lm = (LocationManager) getSystemService(Context.LOCATION_SERVICE);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        startAsForeground();
        startUpdates();
        // ถูกฆ่าแล้วให้ระบบปลุกกลับมา (ยังจับเที่ยวอยู่) — พิกัดจะถูกเก็บต่อ
        return START_STICKY;
    }

    /** ตั้งตัวปลุกเป็นระยะ — ถ้าบริการถูกระบบ/OEM ฆ่าทิ้งระหว่างเที่ยว จะได้เริ่มเก็บพิกัดต่อเอง */
    private void armWatchdog() {
        try {
            AlarmManager am = (AlarmManager) getSystemService(Context.ALARM_SERVICE);
            if (am == null) return;
            Intent i = new Intent(this, BgWakeReceiver.class);   // ปลุกผ่าน receiver (ดูเหตุผลใน BgWakeReceiver)
            i.setAction(ACTION_START);
            // ⚠️ ปลุกผ่าน receiver ไม่ใช่เรียกบริการตรง ๆ — Android 12+ ห้ามแอปฉากหลังเริ่มบริการเอง
            //    (ถ้าปลุกตรง ๆ แล้วระบบปฏิเสธ จะกลายเป็นแอปพัง · ผ่าน receiver แล้วจับได้ = เงียบ ๆ)
            PendingIntent pi = PendingIntent.getBroadcast(this, REQ_WATCHDOG, i,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
            long at = System.currentTimeMillis() + WATCHDOG_MS;
            // ⛔ ตั้งใจใช้แบบไม่เป๊ะ (setAndAllowWhileIdle) — ไม่ต้องขอสิทธิ์ SCHEDULE_EXACT_ALARM
            //    ปลุกช้าหน่อยไม่เป็นไร ขอแค่ "ไม่หายไปเลย"
            if (Build.VERSION.SDK_INT >= 23) {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi);
            } else {
                am.set(AlarmManager.RTC_WAKEUP, at, pi);
            }
        } catch (Exception e) {
            Log.w(TAG, "watchdog failed: " + e.getMessage());
        }
    }

    /** ผู้ใช้ปัดแอปออกจากรายการล่าสุด — ต้องไม่ทำให้การเก็บพิกัดหยุด (คนขับปัดทิ้งบ่อยแต่ยังขับต่อ) */
    @Override
    public void onTaskRemoved(Intent rootIntent) {
        Log.i(TAG, "task removed — keeping tracking alive");
        try {
            if (running && wantOn(this)) {
                AlarmManager am = (AlarmManager) getSystemService(Context.ALARM_SERVICE);
                if (am != null) {
                    Intent i = new Intent(this, BgWakeReceiver.class);   // ปลุกผ่าน receiver
                    i.setAction(ACTION_START);
                    PendingIntent pi = PendingIntent.getBroadcast(this, REQ_TASK_REMOVED, i,
                            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
                    am.set(AlarmManager.RTC_WAKEUP, System.currentTimeMillis() + 1500, pi);
                }
            }
        } catch (Exception ignored) {
        }
        super.onTaskRemoved(rootIntent);
    }

    private void startAsForeground() {
        try {
            NotificationChannel ch = new NotificationChannel(CH_ID, "บันทึกตำแหน่งเที่ยว", NotificationManager.IMPORTANCE_LOW);
            ch.setShowBadge(false);
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm != null) nm.createNotificationChannel(ch);
        } catch (Exception ignored) {
        }
        Intent open = new Intent(this, MainActivity.class);
        int piFlags = PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE;
        PendingIntent pi = PendingIntent.getActivity(this, 0, open, piFlags);
        Notification n = new Notification.Builder(this, CH_ID)
                .setContentTitle("กำลังบันทึกตำแหน่งเที่ยว")
                .setContentText("เก็บพิกัดต่อเนื่องแม้ปิดจอ — แตะเพื่อเปิดแอป")
                .setSmallIcon(android.R.drawable.ic_menu_mylocation)
                .setOngoing(true)
                .setContentIntent(pi)
                .build();
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTI_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION);
        } else {
            startForeground(NOTI_ID, n);
        }
    }

    private void startUpdates() {
        if (lm == null) return;
        running = true;
        acquireWake();
        armWatchdog();
        int ok = 0;
        try {
            if (lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000L, 0f, this, Looper.getMainLooper());
                ok++;
            }
            if (lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                lm.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 2000L, 0f, this, Looper.getMainLooper());
                ok++;
            }
            Log.i(TAG, "tracking started (providers=" + ok + ")");
        } catch (SecurityException e) {
            running = false;
            Log.w(TAG, "no location permission: " + e.getMessage());
        } catch (Exception e) {
            Log.w(TAG, "requestLocationUpdates failed: " + e.getMessage());
        }
    }

    private void acquireWake() {
        try {
            if (wake == null) {
                PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
                if (pm == null) return;
                wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "TaxiMeter::gps");
                wake.setReferenceCounted(false);
            }
            if (!wake.isHeld()) wake.acquire(WAKE_TIMEOUT_MS);
        } catch (Exception ignored) {
        }
    }

    @Override
    public void onLocationChanged(Location l) {
        if (l == null) return;
        try {
            JSONObject o = new JSONObject();
            // ⏱️ ใช้เวลาของ "จุดพิกัด" ไม่ใช่เวลาที่ประมวลผล — สำคัญมากเพราะหน้าเว็บคิดเวลารถติดตามนาฬิกา
            o.put("t", l.getTime());
            o.put("lat", l.getLatitude());
            o.put("lon", l.getLongitude());
            o.put("acc", l.hasAccuracy() ? (double) l.getAccuracy() : -1d);
            o.put("spd", l.hasSpeed() ? (double) l.getSpeed() : -1d);       // เมตร/วินาที
            o.put("brg", l.hasBearing() ? (double) l.getBearing() : -1d);
            o.put("prov", String.valueOf(l.getProvider()));
            synchronized (LOCK) {
                if (FIXES.size() >= MAX_FIXES) FIXES.pollFirst();
                FIXES.addLast(o);
                lastFixAt = System.currentTimeMillis();
            }
        } catch (Exception ignored) {
        }
    }

    @Override
    public void onStatusChanged(String provider, int status, Bundle extras) {
    }

    @Override
    public void onProviderEnabled(String provider) {
    }

    @Override
    public void onProviderDisabled(String provider) {
    }

    @Override
    public void onDestroy() {
        running = false;
        try {
            if (lm != null) lm.removeUpdates(this);
        } catch (Exception ignored) {
        }
        try {
            if (wake != null && wake.isHeld()) wake.release();
        } catch (Exception ignored) {
        }
        Log.i(TAG, "tracking stopped");
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
