package com.baby4bot.taximeter;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;

import java.io.File;
import java.io.FileNotFoundException;

/**
 * 📦 ตัวแจกไฟล์ APK ที่ดาวน์โหลดไว้ใน cache ให้ "ตัวติดตั้งของระบบ" อ่านได้
 *
 * ทำไมต้องมี (และทำไมไม่ใช้ FileProvider ของ AndroidX):
 *   · Android 7+ ห้ามส่งไฟล์ด้วย `file://` ให้แอปอื่น (FileUriExposedException) ⇒ ต้องใช้ `content://`
 *   · โปรเจกต์นี้ตั้งใจ "ไม่พึ่งไลบรารีภายนอก" (ดู build.gradle) ⇒ เขียน ContentProvider เองสั้น ๆ ตัวเดียว
 *     แทนการเพิ่ม androidx.core ทั้งก้อน
 *
 * ความปลอดภัย (สำคัญ — provider นี้ถูกเรียกจากแอปอื่นได้ตามสิทธิ์ที่ให้เป็นครั้ง ๆ):
 *   · `exported="false"` + `grantUriPermissions="true"` ⇒ ปกติไม่มีใครเข้าถึงได้
 *     จะเปิดให้เฉพาะตอนที่เราแนบ FLAG_GRANT_READ_URI_PERMISSION ไปกับ install intent
 *   · อ่านได้เฉพาะไฟล์ใน `<cache>/apk/` เท่านั้น · ชื่อไฟล์ถูกตรวจ (ห้าม / และ ..) ⇒ ออกนอกโฟลเดอร์ไม่ได้
 *   · เปิดแบบอ่านอย่างเดียว (MODE_READ_ONLY) — ไม่มีทางเขียนทับ
 *
 * authority = "<รหัสแอป>.apkprovider" (ดู android:authorities ใน AndroidManifest.xml)
 */
public class ApkFileProvider extends ContentProvider {

    public static final String AUTHORITY_SUFFIX = ".apkprovider";
    /** โฟลเดอร์ย่อยใน cache ของแอปที่เก็บไฟล์อัปเดต (ต้องตรงกับ MainActivity) */
    public static final String APK_DIR = "apk";

    public static Uri uriFor(android.content.Context ctx, String fileName) {
        return Uri.parse("content://" + ctx.getPackageName() + AUTHORITY_SUFFIX + "/" + fileName);
    }

    private static File resolve(android.content.Context ctx, String name) throws FileNotFoundException {
        if (name == null || name.isEmpty() || name.indexOf('/') >= 0 || name.indexOf('\\') >= 0 || name.contains("..")) {
            throw new FileNotFoundException("ชื่อไฟล์ไม่ถูกต้อง");
        }
        File at = new File(new File(ctx.getCacheDir(), APK_DIR), name);
        if (!at.isFile()) throw new FileNotFoundException(name);
        return at;
    }

    @Override
    public boolean onCreate() {
        return true;
    }

    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (getContext() == null) throw new FileNotFoundException("ไม่มี context");
        File f = resolve(getContext(), uri.getLastPathSegment());
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY);
    }

    @Override
    public String getType(Uri uri) {
        return "application/vnd.android.package-archive";
    }

    // เมธอดที่เหลือไม่มีใช้ (provider นี้ให้อ่านไฟล์เท่านั้น) — คืนค่าว่างตามสัญญา
    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
        return null;
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        return null;
    }

    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) {
        return 0;
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
        return 0;
    }
}
