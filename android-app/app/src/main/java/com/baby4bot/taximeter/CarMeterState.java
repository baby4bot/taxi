package com.baby4bot.taximeter;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.concurrent.CopyOnWriteArrayList;

/**
 * 🚗 (18 ก.ย. 69) สะพานข้อมูล “หน้าเว็บ → จอรถ (Android Auto)”
 *
 * ทำไมต้องมี: ตัวเลขมิเตอร์คำนวณอยู่ใน WebView แต่หน้าจอรถถูกวาดโดย Car App Library
 * ในโปรเซสเดียวกัน ⇒ ต้องมีที่พักข้อมูลกลางสั้น ๆ ให้ทั้งสองฝั่งอ่าน/เขียนได้
 *
 * กติกา:
 *  - เก็บ “สแนปช็อตล่าสุด” ลง SharedPreferences ด้วย → ถ้าถูกเปิดจากรถก่อนที่หน้าเว็บจะตื่น
 *    ยังโชว์เลขล่าสุดได้ (พร้อมบอกว่าเก่ากี่วินาที) ไม่ใช่จอว่าง
 *  - คำสั่งจากรถ (หยุดชั่วคราว/เริ่มต่อ/จบเที่ยว) เข้าคิวไว้ให้หน้าเว็บมาเบิก (takeCommand)
 *    ⇒ ไม่ต้องให้ชั้น Android ไปสั่ง DOM เอง และคำสั่งหายไปได้ถ้าแอปบนมือถือไม่ได้เปิดอยู่
 */
public final class CarMeterState {

    private static final String PREFS = "taxi_car_state";
    private static final String KEY = "snapshot";
    private static final int MAX_COMMANDS = 8;

    private static volatile String snapshotJson = null;
    private static volatile long snapshotAt = 0L;
    private static final CopyOnWriteArrayList<String> commands = new CopyOnWriteArrayList<>();
    private static volatile Runnable invalidator = null;   // ใช้บอกจอรถว่ามีข้อมูลใหม่

    private CarMeterState() {
    }

    /** หน้าเว็บเรียกทุกราว 2 วินาที (ผ่านสะพาน TaxiNative.publishCarState) */
    public static void publish(Context ctx, String json) {
        if (json == null || json.trim().isEmpty()) return;
        snapshotJson = json;
        snapshotAt = System.currentTimeMillis();
        try {
            if (ctx != null) {
                SharedPreferences p = ctx.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
                p.edit().putString(KEY, json).putLong(KEY + "_at", snapshotAt).apply();
            }
        } catch (Exception ignored) {
        }
        Runnable r = invalidator;
        if (r != null) {
            try {
                r.run();
            } catch (Exception ignored) {
            }
        }
    }

    /** จอรถอ่านค่าล่าสุด (หน่วยความจำก่อน แล้วค่อยถอยไปอ่านจากดิสก์) */
    public static String snapshot(Context ctx) {
        String s = snapshotJson;
        if (s != null && !s.isEmpty()) return s;
        try {
            if (ctx != null) {
                SharedPreferences p = ctx.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
                s = p.getString(KEY, null);
                if (s != null && !s.isEmpty()) {
                    snapshotAt = p.getLong(KEY + "_at", 0L);
                    return s;
                }
            }
        } catch (Exception ignored) {
        }
        return "";
    }

    /** เวลา (มิลลิวินาที) ของสแนปช็อตล่าสุด — จอรถใช้บอกว่า “อัปเดตล่าสุดกี่วินาทีที่แล้ว” */
    public static long snapshotAt() {
        return snapshotAt;
    }

    /** จอรถลงทะเบียนเพื่อให้รู้ว่ามีข้อมูลใหม่ (จะได้วาดใหม่ทันที ไม่ต้องรอรอบถัดไป) */
    public static void setInvalidator(Runnable r) {
        invalidator = r;
    }

    /** คำสั่งจากจอรถ → เข้าคิวรอหน้าเว็บมาเบิก */
    public static void addCommand(String cmd) {
        String c = (cmd == null) ? "" : cmd.trim().toLowerCase(java.util.Locale.ROOT);
        if (!"pause".equals(c) && !"resume".equals(c) && !"finish".equals(c)) return;
        if (commands.size() >= MAX_COMMANDS) commands.remove(0);
        commands.add(c);
    }

    /** หน้าเว็บเบิกคำสั่ง (คืน "" = ไม่มี) */
    public static String takeCommand() {
        if (commands.isEmpty()) return "";
        return commands.remove(0);
    }

    /** ไว้ตรวจสอบบนเครื่องจริง: มีสแนปช็อตล่าสุดไหม/เก่ากี่วินาที/มีคำสั่งค้างไหม */
    public static String debug(Context ctx) {
        long age = (snapshotAt > 0) ? (System.currentTimeMillis() - snapshotAt) / 1000 : -1;
        String s = snapshot(ctx);
        return "{\"hasSnapshot\":" + (!s.isEmpty()) + ",\"ageSec\":" + age + ",\"pendingCommands\":" + commands.size() + "}";
    }
}
