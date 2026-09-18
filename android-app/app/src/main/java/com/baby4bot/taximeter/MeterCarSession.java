package com.baby4bot.taximeter;

import android.content.Intent;

import androidx.car.app.Screen;
import androidx.car.app.Session;
import androidx.annotation.NonNull;

/** 🚗 เปิดครั้งเดียวต่อการเชื่อมต่อรถ — มีจอเดียว (การ์ดเลขมิเตอร์) */
public class MeterCarSession extends Session {

    @NonNull
    @Override
    public Screen onCreateScreen(@NonNull Intent intent) {
        return new MeterCarScreen(getCarContext());
    }
}
