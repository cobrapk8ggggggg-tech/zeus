package com.zeus.lab.ime;

import android.inputmethodservice.InputMethodService;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import android.util.Base64;
import android.view.inputmethod.InputConnection;
import java.nio.charset.StandardCharsets;

/** Only installed on the disposable cloud Android device. No networking/storage. */
public final class LabIME extends InputMethodService {
    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            if ("com.zeus.lab.READY".equals(intent.getAction())) {
                setResultCode(getCurrentInputConnection() == null ? 0 : 1); return;
            }
            if (!"com.zeus.lab.INPUT".equals(intent.getAction())) return;
            String encoded = intent.getStringExtra("payload");
            InputConnection connection = getCurrentInputConnection();
            if (encoded == null || encoded.length() > 32000 || connection == null) return;
            try {
                String text = new String(Base64.decode(encoded, Base64.DEFAULT), StandardCharsets.UTF_8);
                if (text.length() <= 8000 && connection.commitText(text, 1)) setResultCode(1);
            } catch (IllegalArgumentException ignored) { }
        }
    };
    @Override public void onCreate() {
        super.onCreate();
        IntentFilter filter = new IntentFilter("com.zeus.lab.INPUT");
        filter.addAction("com.zeus.lab.READY");
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED);
        else registerReceiver(receiver, filter);
    }
    @Override public void onDestroy() { unregisterReceiver(receiver); super.onDestroy(); }
}
