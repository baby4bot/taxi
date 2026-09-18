package com.baby4bot.taximeter;

import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;
import androidx.car.app.CarContext;
import androidx.car.app.Screen;
import androidx.car.app.model.Action;
import androidx.car.app.model.Pane;
import androidx.car.app.model.PaneTemplate;
import androidx.car.app.model.Row;
import androidx.car.app.model.Template;

import org.json.JSONObject;

/**
 * 🚗 (18 ก.ย. 69) การ์ด “มิเตอร์สด” บนจอรถ
 *
 * ตัวเลขทั้งหมดมาจากหน้าเว็บ (ผ่าน CarMeterState) — ฝั่งนี้แค่วาดเป็นเทมเพลตที่ผ่านมาตรฐาน
 * เรื่องการรบกวนผู้ขับของ Google (ห้ามวาดหน้าจอเอง)
 *
 * ⚠️ ข้อจำกัดที่ต้องรู้ตรง ๆ:
 *  - ตัวเลขจะเดินต่อได้ตราบที่หน้าเว็บยังอยู่ในเครื่อง (แอปบนมือถือยังไม่ถูกปิดสนิท)
 *    ถ้าถูกปิด สแนปช็อตล่าสุดยังโชว์อยู่ แต่จะขึ้นเตือนว่า “เก่าแล้ว” ให้เปิดแอปบนมือถือ
 *  - ปุ่มจากรถส่งเป็น “คำสั่ง” กลับไปให้หน้าเว็บทำ (CarMeterState.takeCommand) ⇒ ต้องมีแอปบนมือถืออยู่
 *  - จบเที่ยวไม่ให้ทำจากรถโดยเจตนา (กันกดพลาดตอนขับ) — ให้ทำจากมือถือเท่านั้น
 *  - ใช้เฉพาะ API ที่มีในทุกเวอร์ชัน: onGetTemplate() + invalidate() (ไม่พึ่ง lifecycle ของ Screen)
 */
public class MeterCarScreen extends Screen {

    private final Handler handler = new Handler(Looper.getMainLooper());
    private boolean ticking = false;

    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            try {
                invalidate();
            } catch (Exception ignored) {
            }
            if (ticking) handler.postDelayed(this, 1000);
        }
    };

    public MeterCarScreen(@NonNull CarContext carContext) {
        super(carContext);
        // ให้ฝั่งสะพานบอกได้ว่ามีข้อมูลใหม่ → วาดทันที (ไม่ต้องรอรอบ 1 วินาที)
        CarMeterState.setInvalidator(new Runnable() {
            @Override
            public void run() {
                try {
                    handler.post(new Runnable() {
                        @Override
                        public void run() {
                            try {
                                invalidate();
                            } catch (Exception ignored) {
                            }
                        }
                    });
                } catch (Exception ignored) {
                }
            }
        });
        ticking = true;
        handler.postDelayed(tick, 1000);
    }

    @NonNull
    @Override
    public Template onGetTemplate() {
        JSONObject s = readSnapshot();
        boolean has = s != null;
        boolean running = has && s.optBoolean("running", false);
        boolean paused = has && s.optBoolean("paused", false);
        double km = has ? s.optDouble("km", 0) : 0;
        long trafficSec = has ? Math.round(s.optDouble("trafficSec", 0)) : 0;
        int fare = has ? s.optInt("fare", 0) : 0;
        double remain = has ? s.optDouble("remainKm", -1) : -1;
        String dest = has ? s.optString("dest", "") : "";
        long ageSec = has ? Math.max(0, (System.currentTimeMillis() - s.optLong("at", 0)) / 1000) : -1;

        Pane.Builder pane = new Pane.Builder();

        if (!running) {
            pane.addRow(row("ยังไม่เริ่มเที่ยว", "เปิดแอป “ค่าแท็กซี่” บนมือถือ แล้วกดเริ่มมิเตอร์"));
        } else {
            pane.addRow(row(paused ? "หยุดชั่วคราว" : "กำลังจับมิเตอร์", paused ? "กด “เริ่มต่อ” เมื่อพร้อม" : "จับระยะ + เวลารถติดอยู่"));
            pane.addRow(row("ระยะทางที่วิ่ง", fmt2(km) + " กม."));
            pane.addRow(row("เวลารถติด", clock(trafficSec)));
            if (remain >= 0) pane.addRow(row("เหลือถึงปลายทาง", fmt2(remain) + " กม."));
            if (dest != null && !dest.isEmpty()) pane.addRow(row("ปลายทาง", dest));
        }

        // เตือนตรง ๆ ถ้าตัวเลขอาจไม่สด (หน้าเว็บถูกปิด/แอปถูกฆ่า)
        if (has && ageSec >= 15) {
            pane.addRow(row("เลขอาจไม่สดแล้ว", "อัปเดตล่าสุด " + humanAge(ageSec) + " — เปิดแอปบนมือถือ"));
        } else if (has) {
            pane.addRow(row("อัปเดตล่าสุด", humanAge(ageSec)));
        }

        if (running) {
            pane.addAction(new Action.Builder()
                    .setTitle(paused ? "เริ่มต่อ" : "หยุดชั่วคราว")
                    .setOnClickListener(() -> CarMeterState.addCommand(paused ? "resume" : "pause"))
                    .build());
        }

        return new PaneTemplate.Builder(pane.build())
                .setTitle(running ? (fare + " บาท") : "ค่าแท็กซี่")
                .setHeaderAction(Action.APP_ICON)
                .build();
    }

    private static Row row(String title, String text) {
        // ⚠️ ไม่เรียก setSingleLine(): ชื่อเมธอดนี้ไม่ยืนยันว่ามีใน car-app 1.4.0
        //    (แถวของ Pane แสดงบรรทัดเดียวอยู่แล้ว) — เลี่ยงความเสี่ยง build ล้มโดยไม่จำเป็น
        return new Row.Builder()
                .setTitle(title)
                .addText(text)
                .build();
    }

    private static String fmt2(double v) {
        return String.format(java.util.Locale.US, "%.2f", v);
    }

    private static String clock(long sec) {
        long s = Math.max(0, sec);
        long h = s / 3600, m = (s % 3600) / 60, ss = s % 60;
        if (h > 0) return String.format(java.util.Locale.US, "%d:%02d:%02d", h, m, ss);
        return String.format(java.util.Locale.US, "%02d:%02d", m, ss);
    }

    private static String humanAge(long sec) {
        if (sec < 3) return "เมื่อสักครู่";
        if (sec < 60) return sec + " วินาทีที่แล้ว";
        long m = sec / 60;
        if (m < 60) return m + " นาทีที่แล้ว";
        return (m / 60) + " ชั่วโมงที่แล้ว";
    }

    /** อ่าน JSON ที่หน้าเว็บส่งมา — ถ้าพัง/ว่าง คืน null (จอรถต้องไม่ล้มเพราะข้อมูลเสีย) */
    private JSONObject readSnapshot() {
        try {
            String raw = CarMeterState.snapshot(getCarContext());
            if (raw == null || raw.trim().isEmpty()) return null;
            JSONObject o = new JSONObject(raw);
            if (o.optLong("at", 0) <= 0) o.put("at", CarMeterState.snapshotAt());
            return o;
        } catch (Exception e) {
            return null;
        }
    }
}
