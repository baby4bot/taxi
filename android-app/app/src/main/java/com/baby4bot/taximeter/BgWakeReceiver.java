package com.baby4bot.taximeter;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * 🔋 ตัวปลุกบริการเก็บพิกัด (18 ก.ย. 69)
 *
 * ทำไมต้องมีตัวกลางแทนการปลุกบริการตรง ๆ:
 *   Android 12+ ห้ามแอปที่อยู่ฉากหลัง "เริ่มบริการเบื้องหน้า" เอง (จะโยน exception)
 *   ถ้าให้ AlarmManager เรียกบริการตรง ๆ แล้วระบบปฏิเสธ แอปอาจพังทั้งตัว
 *   → ปลุกผ่าน receiver นี้แทน แล้วห่อ try/catch ไว้ (ถูกปฏิเสธ = เงียบ ๆ ไม่พัง)
 *
 * ใช้ 2 จังหวะ:
 *   1) ผู้ใช้ปัดแอปออกจากรายการล่าสุด (onTaskRemoved) → ปลุกกลับใน ~1.5 วิ
 *   2) ตัวเฝ้าระยะยาว ทุก 15 นาที ระหว่างจับเที่ยว → ถ้าบริการถูก OEM ฆ่า จะได้กลับมาเก็บพิกัดต่อ
 */
public class BgWakeReceiver extends BroadcastReceiver {

    private static final String TAG = "TaxiMeterGps";

    @Override
    public void onReceive(Context c, Intent i) {
        try {
            if (!BgLocationService.wantOn(c)) return;   // จบเที่ยวไปแล้ว — ไม่ต้องปลุก
            BgLocationService.start(c);
        } catch (Exception e) {
            Log.w(TAG, "wake blocked: " + e.getMessage());
        }
    }
}
