package com.baby4bot.taximeter;

import android.content.Intent;

import androidx.car.app.CarAppService;
import androidx.car.app.Session;
import androidx.car.app.validation.HostValidator;

/**
 * 🚗 (18 ก.ย. 69) ประตูเข้าแอปบนรถ (Android Auto / Android Automotive)
 *
 * ทำไมต้องมี: Android Auto ไม่ให้แอปวาดหน้าจอเอง ⇒ ต้องประกาศ CarAppService แล้ววาดด้วย
 * “เทมเพลต” ของ Car App Library (ดู MeterCarScreen) — สิ่งที่ขึ้นบนจอรถคือการ์ดของเรา
 * ไม่ใช่หน้าจอเว็บทั้งหน้าของบนมือถือ
 *
 * สิทธิ์/ข้อจำกัดที่ต้องรู้:
 *  - แอปที่ไม่ได้มาจาก Play Store จะขึ้นในรถได้ก็ต่อเมื่อเปิด Developer mode → “Unknown sources”
 *    ในแอป Android Auto บนมือถือ (ทำครั้งเดียวต่อเครื่อง)
 *  - createHostValidator() แบบ ALLOW_ALL_HOSTS_VALIDATOR จำเป็นสำหรับ APK ที่โหลดเอง
 *    (ถ้าปล่อยค่าเริ่มต้น จะยอมรับเฉพาะโฮสต์ที่ Google รับรอง ⇒ รถจะไม่เห็นแอป)
 */
public class TaxiCarAppService extends CarAppService {

    @Override
    public HostValidator createHostValidator() {
        return HostValidator.ALLOW_ALL_HOSTS_VALIDATOR;
    }

    @Override
    public Session onCreateSession() {
        return new MeterCarSession();
    }
}
