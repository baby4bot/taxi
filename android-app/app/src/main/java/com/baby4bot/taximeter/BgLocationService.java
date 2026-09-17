package com.baby4bot.taximeter;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
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
            Intent i = new Intent(c, BgLocationService.class);
            i.setAction(ACTION_START);
            c.startForegroundService(i);
        } catch (Exception e) {
            Log.w(TAG, "start failed: " + e.getMessage());
        }
    }

    static void stop(Context c) {
        try {
            c.stopService(new Intent(c, BgLocationService.class));
        } catch (Exception e) {
            Log.w(TAG, "stop failed: " + e.getMessage());
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
