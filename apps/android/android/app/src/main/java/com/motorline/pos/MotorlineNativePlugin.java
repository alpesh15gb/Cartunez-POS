package com.motorline.pos;

import android.Manifest;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import android.print.PrintManager;
import androidx.activity.result.ActivityResult;
import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.ActivityCallback;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;
import com.journeyapps.barcodescanner.ScanIntentResult;
import com.journeyapps.barcodescanner.ScanOptions;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

@CapacitorPlugin(name = "MotorlineNative", permissions = {
    @Permission(alias = "camera", strings = { Manifest.permission.CAMERA })
})
public class MotorlineNativePlugin extends Plugin {
    private SQLiteOpenHelper database;
    private final ExecutorService storageWorker = Executors.newSingleThreadExecutor();

    @Override
    public void load() {
        database = new SQLiteOpenHelper(getContext(), "motorline-workspaces.db", null, 1) {
            @Override
            public void onConfigure(SQLiteDatabase db) {
                db.setForeignKeyConstraintsEnabled(true);
            }

            @Override
            public void onCreate(SQLiteDatabase db) {
                db.execSQL("CREATE TABLE workspace_values (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL)");
            }

            @Override
            public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {
                throw new IllegalStateException("Unsupported workspace migration " + oldVersion + " to " + newVersion);
            }
        };
        database.setWriteAheadLoggingEnabled(true);
    }

    private String key(PluginCall call) {
        String value = call.getString("key");
        if (value == null || value.trim().isEmpty() || value.length() > 512) {
            call.reject("A nonempty scoped storage key is required.");
            return null;
        }
        return value;
    }

    @PluginMethod
    public void get(PluginCall call) {
        String key = key(call);
        if (key == null) return;
        storageWorker.execute(() -> {
            try {
                SQLiteDatabase db = database.getReadableDatabase();
                JSObject result = new JSObject();
                int length;
                try (Cursor cursor = db.rawQuery("SELECT length(value) FROM workspace_values WHERE key = ?", new String[] { key })) {
                    if (!cursor.moveToFirst()) {
                        result.put("value", JSObject.NULL);
                        call.resolve(result);
                        return;
                    }
                    length = cursor.getInt(0);
                }
                // Keep each CursorWindow below Android's size limit for large catalogs.
                StringBuilder value = new StringBuilder(length);
                final int chunkSize = 128 * 1024;
                for (int offset = 1; offset <= length; offset += chunkSize) {
                    try (Cursor cursor = db.rawQuery("SELECT substr(value, ?, ?) FROM workspace_values WHERE key = ?", new String[] { String.valueOf(offset), String.valueOf(chunkSize), key })) {
                        if (!cursor.moveToFirst()) throw new IllegalStateException("Workspace disappeared while reading.");
                        value.append(cursor.getString(0));
                    }
                }
                result.put("value", value.toString());
                call.resolve(result);
            } catch (Exception error) {
                call.reject("Could not read the local workspace.", error);
            }
        });
    }

    @PluginMethod
    public void set(PluginCall call) {
        String key = key(call);
        String value = call.getString("value");
        if (key == null) return;
        if (value == null || value.length() > 32 * 1024 * 1024) {
            call.reject("The workspace value is missing or exceeds 32 MB.");
            return;
        }
        storageWorker.execute(() -> {
            SQLiteDatabase db = null;
            try {
                db = database.getWritableDatabase();
                db.beginTransaction();
                ContentValues values = new ContentValues();
                values.put("key", key);
                values.put("value", value);
                values.put("updated_at", System.currentTimeMillis());
                if (db.insertWithOnConflict("workspace_values", null, values, SQLiteDatabase.CONFLICT_REPLACE) < 0) {
                    throw new IllegalStateException("Workspace write failed.");
                }
                db.setTransactionSuccessful();
            } catch (Exception error) {
                call.reject("Could not save the local workspace.", error);
                return;
            } finally {
                if (db != null && db.inTransaction()) db.endTransaction();
            }
            call.resolve();
        });
    }

    @PluginMethod
    public void remove(PluginCall call) {
        String key = key(call);
        if (key == null) return;
        storageWorker.execute(() -> {
            try {
                database.getWritableDatabase().delete("workspace_values", "key = ?", new String[] { key });
                call.resolve();
            } catch (Exception error) {
                call.reject("Could not remove the local workspace.", error);
            }
        });
    }

    @PluginMethod
    public void scan(PluginCall call) {
        if (getPermissionState("camera") != PermissionState.GRANTED) {
            requestPermissionForAlias("camera", call, "cameraPermission");
            return;
        }
        launchScanner(call);
    }

    @PermissionCallback
    private void cameraPermission(PluginCall call) {
        if (getPermissionState("camera") != PermissionState.GRANTED) {
            call.reject("Camera permission is required to scan a part barcode.");
            return;
        }
        launchScanner(call);
    }

    private void launchScanner(PluginCall call) {
        ScanOptions options = new ScanOptions();
        options.setPrompt("Scan the part barcode");
        options.setBeepEnabled(false);
        options.setOrientationLocked(false);
        options.setDesiredBarcodeFormats(ScanOptions.ALL_CODE_TYPES);
        startActivityForResult(call, options.createScanIntent(getContext()), "scannerResult");
    }

    @ActivityCallback
    private void scannerResult(PluginCall call, ActivityResult activityResult) {
        if (call == null) return;
        ScanIntentResult result = ScanIntentResult.parseActivityResult(activityResult.getResultCode(), activityResult.getData());
        JSObject response = new JSObject();
        response.put("value", result.getContents() == null ? JSObject.NULL : result.getContents());
        call.resolve(response);
    }

    @PluginMethod
    public void print(PluginCall call) {
        getActivity().runOnUiThread(() -> {
            try {
                PrintManager manager = (PrintManager) getContext().getSystemService(Context.PRINT_SERVICE);
                manager.print("Motorline receipt", getBridge().getWebView().createPrintDocumentAdapter("Motorline receipt"), null);
                call.resolve();
            } catch (Exception error) {
                call.reject("The Android print service could not be opened.", error);
            }
        });
    }

    @Override
    protected void handleOnDestroy() {
        storageWorker.execute(() -> database.close());
        storageWorker.shutdown();
        super.handleOnDestroy();
    }
}
