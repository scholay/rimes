package org.scholay.rimes.android;

import android.app.Instrumentation;
import android.content.Context;
import android.content.SharedPreferences;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;

/** Production preference transitions in an isolated store; no IME, JNI or scheme imports. */
final class KeyboardSettingsLayoutContract {
    private final SharedPreferences preferences;
    private final KeyboardSettings settings;
    private int checks;

    private KeyboardSettingsLayoutContract(SharedPreferences preferences) {
        this.preferences=preferences;
        settings=new KeyboardSettings(preferences);
    }

    static int run(Instrumentation instrumentation) throws Exception {
        Context context=instrumentation.getTargetContext();
        String name="layout-contract-"+UUID.randomUUID();
        AtomicReference<Throwable> failure=new AtomicReference<>();
        int[] result={0};
        instrumentation.runOnMainSync(() -> {
            try {
                KeyboardSettingsLayoutContract test=new KeyboardSettingsLayoutContract(
                        context.getSharedPreferences(name,Context.MODE_PRIVATE));
                test.transitions();
                test.atomicNotifications();
                test.legacyProjectionAndEscape();
                result[0]=test.checks;
            } catch(Throwable error) { failure.set(error); }
            finally { context.deleteSharedPreferences(name); }
        });
        Throwable error=failure.get();
        if(error instanceof Exception) throw (Exception)error;
        if(error instanceof Error) throw (Error)error;
        return result[0];
    }

    private void check(boolean value,String label) {
        checks++;
        if(!value) throw new AssertionError(label);
    }
    private void pair(String schema,String layout,String label) {
        KeyboardSettings.Snapshot selected=settings.snapshot();
        check(schema.equals(selected.schema) && layout.equals(selected.layout),label+" projected pair");
        check(schema.equals(preferences.getString(KeyboardSettings.KEY_SCHEMA,""))
                && layout.equals(preferences.getString(KeyboardSettings.KEY_LAYOUT,"")),label+" stored pair");
        // A new model restores preferences; full process/Activity persistence belongs to AppSettingsContract.
        KeyboardSettings.Snapshot restored=new KeyboardSettings(preferences).snapshot();
        check(schema.equals(restored.schema) && layout.equals(restored.layout),label+" new model restores pair");
    }

    private void transitions() {
        settings.setLearningEnabled(false);
        settings.setAiMockEnabled(false);
        settings.setTranslationDirection("en-zh");
        settings.setTheme(KeyboardSettings.themeValues().get(1));
        settings.setLayout("nineKey");
        pair("rimes_pinyin","nineKey","select nine-key");
        settings.setLayout("qwerty");
        pair("rimes_pinyin","qwerty","explicit nine-key to 26-key");

        for(String schema:new String[]{"rimes_ziranma","rimes_wubi"}) {
            settings.setLayout("nineKey");
            settings.setSchema(schema);
            pair(schema,"qwerty","nine-key to "+schema);
            settings.setSchema("rimes_pinyin");
            pair("rimes_pinyin","qwerty","regular scheme retains selected 26-key");
            settings.setSchema(schema);
            settings.setLayout("orthogonal");
            pair(schema,"orthogonal","chord keeps ordinary scheme");
            settings.setLayout("qwerty");
            pair(schema,"qwerty","chord to 26-key restores ordinary scheme");
        }
        KeyboardSettings.Snapshot saved=new KeyboardSettings(preferences).snapshot();
        check(!saved.learning && !saved.aiMockEnabled,"layout changes preserve learning and AI settings");
        check("en-zh".equals(saved.translationDirection)
                && KeyboardSettings.themeValues().get(1).equals(saved.theme),"layout changes preserve direction and theme");
    }

    private void atomicNotifications() {
        List<String> observed=new ArrayList<>();
        SharedPreferences.OnSharedPreferenceChangeListener listener=(changed,key) -> {
            if(!KeyboardSettings.KEY_SCHEMA.equals(key) && !KeyboardSettings.KEY_LAYOUT.equals(key)) return;
            KeyboardSettings.Snapshot pair=settings.snapshot();
            String rawSchema=changed.getString(KeyboardSettings.KEY_SCHEMA,"");
            String rawLayout=changed.getString(KeyboardSettings.KEY_LAYOUT,"");
            check(pair.schema.equals(rawSchema) && pair.layout.equals(rawLayout),"notification sees complete persisted pair");
            check(!"nineKey".equals(rawLayout) || "rimes_pinyin".equals(rawSchema),"notification never sees non-Pinyin nine-key");
            observed.add(rawSchema+"/"+rawLayout);
        };
        preferences.registerOnSharedPreferenceChangeListener(listener);
        try {
            settings.setLayout("nineKey");
            check(!observed.isEmpty(),"layout selection emits preference notifications");
            check(observed.stream().allMatch("rimes_pinyin/nineKey"::equals),"all nine-key notifications share final pair");
            observed.clear();
            settings.setSchema("rimes_wubi");
            check(!observed.isEmpty(),"scheme selection emits preference notifications");
            check(observed.stream().allMatch("rimes_wubi/qwerty"::equals),"all scheme notifications share final pair");
        } finally { preferences.unregisterOnSharedPreferenceChangeListener(listener); }
    }

    private void seed(Object schema,Object layout) {
        SharedPreferences.Editor editor=preferences.edit().clear();
        if(schema instanceof String) editor.putString(KeyboardSettings.KEY_SCHEMA,(String)schema);
        else editor.putInt(KeyboardSettings.KEY_SCHEMA,7);
        if(layout instanceof String) editor.putString(KeyboardSettings.KEY_LAYOUT,(String)layout);
        else editor.putBoolean(KeyboardSettings.KEY_LAYOUT,true);
        check(editor.commit(),"synthetic legacy preferences stored");
    }
    private void readOnlyProjection(String schema,String layout,String label) {
        Map<String,?> before=new HashMap<>(preferences.getAll());
        KeyboardSettings.Snapshot projected=new KeyboardSettings(preferences).snapshot();
        check(schema.equals(projected.schema) && layout.equals(projected.layout),label+" safe projection");
        check(before.equals(preferences.getAll()),label+" read never rewrites raw preferences");
    }
    private void legacyProjectionAndEscape() {
        seed("rimes_wubi","nineKey");
        readOnlyProjection("rimes_wubi","qwerty","incompatible legacy scheme/layout");
        settings.setLayout("qwerty");
        pair("rimes_wubi","qwerty","legacy pair explicitly returns to 26-key");

        // A raw unknown ID is not an imported scheme. Verify it cannot prevent explicit layout recovery.
        seed("wanxiang","nineKey");
        Map<String,?> before=new HashMap<>(preferences.getAll());
        check("rimes_pinyin".equals(settings.getSchema()),"unrecognized stored ID uses bundled fallback, not import");
        check(before.equals(preferences.getAll()),"unrecognized ID projection preserves raw preferences");
        settings.setLayout("qwerty");
        pair("rimes_pinyin","qwerty","unrecognized stored ID cannot lock nine-key");

        seed(7,true);
        readOnlyProjection("rimes_pinyin","qwerty","wrong-type legacy preferences");
        settings.setLayout("qwerty");
        pair("rimes_pinyin","qwerty","wrong-type preferences explicitly recover");
    }
}
