package org.scholay.rimes.android;

import android.app.Activity;
import android.app.Application;
import android.app.Instrumentation;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.ActivityInfo;
import android.content.res.Configuration;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.Looper;
import android.os.Parcel;
import android.os.SystemClock;
import android.text.InputType;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.TextView;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicReference;

/** Attached native settings UI and actual preference writes; synthetic text never leaves this test. */
final class AppSettingsContract {
    private static final String SENTINEL="RIMES_APP_UI_SYNTHETIC_NEVER_SAVE_927";
    private static final String[] KEYS={"schema","layout","theme","translation_direction","learning","ai_mock_enabled",OpenAiSettings.KEY};
    private final Instrumentation instrumentation;
    private final Context context;
    private final SharedPreferences preferences;
    private final SettingsLifecycle lifecycle=new SettingsLifecycle();
    private Application application;
    private SetupActivity activity;
    private int checks;

    private AppSettingsContract(Instrumentation instrumentation) {
        this.instrumentation=instrumentation; context=instrumentation.getTargetContext();
        preferences=context.getSharedPreferences("keyboard",Context.MODE_PRIVATE);
    }

    /** Dedicated mode; no engine initialization or default-input-method changes. */
    static int run(Instrumentation instrumentation) {
        if(Looper.myLooper()==Looper.getMainLooper()) throw new IllegalStateException("AppSettingsContract must run off main");
        AppSettingsContract contract=new AppSettingsContract(instrumentation);
        Map<String,Object> original=new LinkedHashMap<>();
        Map<String,?> stored=contract.preferences.getAll();
        for(String key:KEYS) if(stored.containsKey(key)) original.put(key,stored.get(key));
        try {
            contract.main(() -> {
                Context owner=contract.context.getApplicationContext();
                if(!(owner instanceof Application)) throw new AssertionError("Target Application unavailable");
                contract.application=(Application)owner;
                contract.application.registerActivityLifecycleCallbacks(contract.lifecycle); return null;
            });
            contract.check(contract.preferences.edit().putString("schema","rimes_pinyin").putString("layout","qwerty")
                    .putString("theme","apple").putString("translation_direction","auto")
                    .putBoolean("learning",true).putBoolean("ai_mock_enabled",true).commit(),"test settings baseline persisted");
            contract.launch();
            contract.navigation();
            contract.nestedNavigation();
            contract.schemaAndLayout();
            contract.optionsAndPersistence();
            contract.cometConfiguration();
            contract.pageRestoration();
            contract.playgroundPrivacy();
            return contract.checks;
        } finally {
            // Restore only keys deliberately exercised; no word-learning files or other preferences.
            SharedPreferences.Editor restore=contract.preferences.edit();
            for(String key:KEYS) {
                Object value=original.get(key);
                if(!original.containsKey(key)) restore.remove(key);
                else if(value instanceof String) restore.putString(key,(String)value);
                else if(value instanceof Boolean) restore.putBoolean(key,(Boolean)value);
                else if(value instanceof Integer) restore.putInt(key,(Integer)value);
                else if(value instanceof Long) restore.putLong(key,(Long)value);
                else if(value instanceof Float) restore.putFloat(key,(Float)value);
                else if(value instanceof Set) {
                    java.util.HashSet<String> strings=new java.util.HashSet<>();
                    for(Object item:(Set<?>)value) strings.add((String)item);
                    restore.putStringSet(key,strings);
                }
                else throw new AssertionError("Unexpected preference type for "+key);
            }
            boolean restored=restore.commit();
            contract.main(() -> {
                SetupActivity latest=contract.lifecycle.created.get();
                if(latest!=null && !latest.isDestroyed()) latest.finish();
                if(contract.activity!=null && contract.activity!=latest && !contract.activity.isDestroyed()) contract.activity.finish();
                if(contract.application!=null) contract.application.unregisterActivityLifecycleCallbacks(contract.lifecycle);
                return null;
            });
            if(!restored) throw new AssertionError("Test settings restoration failed");
        }
    }

    /** Application callbacks remain registered across launches and framework recreation. */
    private static final class SettingsLifecycle implements Application.ActivityLifecycleCallbacks {
        final AtomicReference<SetupActivity> created=new AtomicReference<>();
        final AtomicReference<SetupActivity> resumed=new AtomicReference<>();
        volatile String lastEvent="registered";
        @Override public void onActivityCreated(Activity value,Bundle state) {
            if(value instanceof SetupActivity) { created.set((SetupActivity)value); lastEvent="created"; }
        }
        @Override public void onActivityResumed(Activity value) {
            if(value instanceof SetupActivity) { resumed.set((SetupActivity)value); lastEvent="resumed"; }
        }
        @Override public void onActivityPaused(Activity value) {
            if(value instanceof SetupActivity) { resumed.compareAndSet((SetupActivity)value,null); lastEvent="paused"; }
        }
        @Override public void onActivityDestroyed(Activity value) {
            if(value instanceof SetupActivity) {
                created.compareAndSet((SetupActivity)value,null); resumed.compareAndSet((SetupActivity)value,null); lastEvent="destroyed";
            }
        }
        @Override public void onActivityStarted(Activity value) {}
        @Override public void onActivityStopped(Activity value) {}
        @Override public void onActivitySaveInstanceState(Activity value,Bundle state) {}
    }

    private interface Action<T> { T run() throws Exception; }
    private <T> T main(Action<T> action) {
        AtomicReference<T> result=new AtomicReference<>(); AtomicReference<Throwable> failure=new AtomicReference<>();
        instrumentation.runOnMainSync(() -> { try { result.set(action.run()); } catch(Throwable error) { failure.set(error); } });
        if(failure.get()!=null) throw new AssertionError("Settings main-thread action failed",failure.get());
        return result.get();
    }
    private void check(boolean value,String label) { checks++; if(!value) throw new AssertionError("App settings: "+label); }
    private View find(String tag) { return main(() -> activity.getWindow().getDecorView().findViewWithTag(tag)); }
    private View waitView(String tag) {
        long deadline=SystemClock.uptimeMillis()+8000;
        do {
            View value=find(tag);
            if(value!=null && main(() -> value.isAttachedToWindow() && value.isShown() && value.getWidth()>0 && value.getHeight()>0)) return value;
            SystemClock.sleep(30);
        } while(SystemClock.uptimeMillis()<deadline);
        throw new AssertionError("Missing attached settings view "+tag);
    }
    private void tap(String tag) {
        View view=waitView(tag);
        main(() -> { view.requestRectangleOnScreen(new Rect(0,0,view.getWidth(),view.getHeight()),true); return null; });
        instrumentation.waitForIdleSync();
        check(main(() -> {
            if(!view.isEnabled() || !view.isClickable() || !view.getGlobalVisibleRect(new Rect())) return false;
            boolean before=view instanceof CompoundButton && ((CompoundButton)view).isChecked();
            boolean handled=view.performClick();
            // CompoundButton toggles before View.performClick; without an OnClickListener the
            // returned value can be false although its native toggle and checked listener ran.
            return view instanceof CompoundButton?((CompoundButton)view).isChecked()!=before:handled;
        }),"native click "+tag);
        instrumentation.waitForIdleSync();
    }
    private void page(String name) { check(waitView("settings.page."+name)!=null,"page "+name+" visible"); }
    private void back(String name) { tap("settings.back"); page(name); }
    private void home() { back("home"); }
    private void open(String name) { tap("settings.home."+name); page(name.equals("enable")?"setup":name); }
    private void launch() {
        String component=context.getPackageName()+"/"+SetupActivity.class.getName();
        SetupActivity previous=activity;
        String shellOutput;
        try(android.os.ParcelFileDescriptor.AutoCloseInputStream command=new android.os.ParcelFileDescriptor.AutoCloseInputStream(
                instrumentation.getUiAutomation().executeShellCommand("am start -W -f 0x10008000 -n "+component));
                java.io.ByteArrayOutputStream bytes=new java.io.ByteArrayOutputStream()) {
            byte[] block=new byte[1024]; int count;
            while((count=command.read(block))!=-1) bytes.write(block,0,count);
            shellOutput=new String(bytes.toByteArray(),StandardCharsets.UTF_8);
        } catch(java.io.IOException error) { throw new AssertionError("Settings activity launch failed",error); }
        activity=freshActivity(previous,"home",0,"launch; shell output:\n"+shellOutput);
        main(() -> { activity.getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN); return null; });
        page("home");
    }
    private int editableCount(View root) {
        int count=root instanceof EditText?1:0;
        if(root instanceof ViewGroup) for(int i=0;i<((ViewGroup)root).getChildCount();i++) count+=editableCount(((ViewGroup)root).getChildAt(i));
        return count;
    }
    private void cometConfiguration() {
        main(() -> { new OpenAiSettings(context).clear(); return null; });
        open("ai"); EditText key=(EditText)waitView("settings.ai.comet.key");
        check(main(() -> !key.isSaveEnabled() && key.getTransformationMethod() instanceof android.text.method.PasswordTransformationMethod),"API key masked and excluded from saved view state");
        check(main(() -> key.getImportantForAutofill()==View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS),"key has no autofill export");
        EditText address=(EditText)waitView("settings.ai.base_url");
        main(() -> { address.setText("https://compatible.example.test/v1"); key.setText("synthetic-ui-test-key"); return null; });
        tap("settings.ai.comet.enabled"); tap("settings.ai.comet.translation"); tap("settings.ai.comet.save");
        OpenAiSettings comet=new OpenAiSettings(context);
        check("https://compatible.example.test/v1/chat/completions".equals(comet.snapshot().endpoint()),"custom API URL saved by native settings");
        check(comet.snapshot().enabled && comet.snapshot().translation && comet.snapshot().hasKey(),"native settings save encrypted online profile");
        check(!preferences.getString(OpenAiSettings.KEY,"").contains("synthetic-ui-test-key"),"UI key not stored in plaintext");
        EditText saved=(EditText)waitView("settings.ai.comet.key");
        check(main(() -> saved.getText().length())==0,"saved key never rendered back into field");
        tap("settings.ai.comet.clear"); check(!comet.snapshot().enabled && !comet.snapshot().hasKey(),"native remove-key action disables service"); home();
    }
    private void navigation() {
        check(main(() -> editableCount(activity.getWindow().getDecorView()))==0,"home has no trial text fields");
        for(String name:new String[]{"enable","playground","schema","chords","appearance","resources","translation","ai","data","privacy","differences"}) {
            open(name); home();
        }
    }
    private String selectableText(View root) {
        if(root instanceof TextView && ((TextView)root).isTextSelectable()) return ((TextView)root).getText().toString();
        if(root instanceof ViewGroup) for(int i=0;i<((ViewGroup)root).getChildCount();i++) {
            String text=selectableText(((ViewGroup)root).getChildAt(i));
            if(text!=null) return text;
        }
        return null;
    }
    private void licenseText(String filename) {
        String expected;
        try(java.io.InputStream input=context.getAssets().open("licenses/"+filename);
                java.io.ByteArrayOutputStream bytes=new java.io.ByteArrayOutputStream()) {
            byte[] block=new byte[8192]; int count;
            while((count=input.read(block))!=-1) bytes.write(block,0,count);
            expected=new String(bytes.toByteArray(),StandardCharsets.UTF_8);
        } catch(java.io.IOException error) { throw new AssertionError("Packaged license unavailable: "+filename,error); }
        check(!expected.isEmpty(),"packaged license is nonempty "+filename);
        long deadline=SystemClock.uptimeMillis()+8000;
        do {
            if(expected.equals(main(() -> selectableText(activity.getWindow().getDecorView())))) {
                check(true,"license viewer displays complete packaged text "+filename); return;
            }
            SystemClock.sleep(30);
        } while(SystemClock.uptimeMillis()<deadline);
        throw new AssertionError("License viewer did not finish displaying "+filename);
    }
    private void nestedNavigation() {
        open("chords"); tap("settings.chords.mappings"); page("mappings");
        String table=main(() -> selectableText(activity.getWindow().getDecorView()));
        check(table!=null && table.split("\n").length==427,"mapping reader displays all 427 built-in entries");
        check(main(() -> editableCount(activity.getWindow().getDecorView()))==0,"mapping reader is read-only");
        recreate("mappings"); back("chords"); home();

        open("privacy"); tap("settings.privacy.licenses"); page("licenses");
        tap("settings.license.RIMES-Apache-2.0.txt"); page("license"); licenseText("RIMES-Apache-2.0.txt");
        recreate("license"); licenseText("RIMES-Apache-2.0.txt"); back("licenses"); back("privacy"); home();

        open("resources"); tap("settings.resources.licenses"); page("licenses"); back("resources"); home();
        open("translation"); tap("settings.translation.license"); page("license");
        licenseText("CC-CEDICT-CC-BY-SA-4.0.txt"); back("translation"); home();
    }
    private void preference(String key,String value) { check(value.equals(preferences.getString(key,"")),key+" stored as "+value); }
    private void selected(String prefix,List<String> values,String wanted) {
        int count=0;
        for(String value:values) {
            View option=find(prefix+value);
            if(option==null) continue; // Ordinary and chord layout choices occupy separate pages.
            boolean marked=main(() -> option instanceof CompoundButton?((CompoundButton)option).isChecked():option.isSelected());
            check(marked==value.equals(wanted),"exclusive selection "+prefix+value);
            if(marked) count++;
        }
        check(count==1,"one selected option in "+prefix);
    }
    private void schemaAndLayout() {
        open("schema"); tap("settings.schema.rimes_wubi"); preference("schema","rimes_wubi"); preference("layout","qwerty");
        selected("settings.schema.",KeyboardSettings.schemaValues(),"rimes_wubi"); home();
        open("appearance"); tap("settings.layout.nineKey"); preference("layout","nineKey"); preference("schema","rimes_pinyin");
        selected("settings.layout.",KeyboardSettings.layoutValues(),"nineKey"); home();
        open("schema"); selected("settings.schema.",KeyboardSettings.schemaValues(),"rimes_pinyin");
        tap("settings.schema.rimes_ziranma"); preference("schema","rimes_ziranma"); preference("layout","qwerty"); home();
        open("chords"); tap("settings.layout.orthogonal"); preference("layout","orthogonal"); preference("schema","rimes_ziranma");
        selected("settings.layout.",KeyboardSettings.layoutValues(),"orthogonal");
        tap("settings.layout.splitOrthogonal"); preference("layout","splitOrthogonal");
        selected("settings.layout.",KeyboardSettings.layoutValues(),"splitOrthogonal"); home();
        open("schema"); tap("settings.schema.rimes_pinyin"); preference("schema","rimes_pinyin"); preference("layout","qwerty"); home();
        open("schema"); tap("settings.schema.rimes_wubi"); home();
        open("chords"); tap("settings.layout.orthogonal"); preference("schema","rimes_wubi"); preference("layout","orthogonal"); home();
        open("schema"); tap("settings.schema.rimes_wubi"); preference("schema","rimes_wubi"); preference("layout","qwerty"); home();
        open("appearance"); tap("settings.layout.qwerty"); preference("layout","qwerty");
        String alternate=KeyboardTheme.ALL[1].id;
        tap("settings.theme."+alternate); preference("theme",alternate);
        selected("settings.theme.",KeyboardSettings.themeValues(),alternate); home();
    }
    private void flag(String tag,String key,boolean wanted) {
        View view=waitView(tag); check(view instanceof CompoundButton,"real settings switch "+tag);
        if(main(() -> ((CompoundButton)view).isChecked())!=wanted) tap(tag);
        check(preferences.getBoolean(key,!wanted)==wanted,"actual boolean preference "+key);
        check(checked(tag)==wanted,"switch reflects stored "+key);
    }
    private boolean checked(String tag) { CompoundButton value=(CompoundButton)waitView(tag); return main(value::isChecked); }
    private void optionsAndPersistence() {
        open("translation");
        for(String direction:KeyboardSettings.translationDirectionValues()) {
            tap("settings.translation."+direction); preference("translation_direction",direction);
            selected("settings.translation.",KeyboardSettings.translationDirectionValues(),direction);
        }
        home(); open("data"); flag("settings.learning","learning",false); home();
        open("ai"); flag("settings.ai_mock_enabled","ai_mock_enabled",false); home();
        check(preferences.edit().commit(),"queued UI preference writes flush to disk");
        Map<String,String> disk=diskPreferences();
        check("false".equals(disk.get("learning")) && "false".equals(disk.get("ai_mock_enabled")),"both toggles exist in actual preference file");
        check("en-zh".equals(disk.get("translation_direction")),"chosen translation direction exists on disk");
        reopen();
        open("data"); check(!checked("settings.learning"),"learning survives reopening"); home();
        open("ai"); check(!checked("settings.ai_mock_enabled"),"AI mock gate survives reopening"); home();
        open("translation"); selected("settings.translation.",KeyboardSettings.translationDirectionValues(),"en-zh"); home();
        open("schema"); selected("settings.schema.",KeyboardSettings.schemaValues(),"rimes_wubi"); home();
        open("appearance"); selected("settings.layout.",KeyboardSettings.layoutValues(),"qwerty");
        selected("settings.theme.",KeyboardSettings.themeValues(),KeyboardTheme.ALL[1].id); home();
        open("data"); flag("settings.learning","learning",true); home();
        open("ai"); flag("settings.ai_mock_enabled","ai_mock_enabled",true); home();
    }
    private void reopen() {
        SetupActivity previous=activity;
        main(() -> { previous.finish(); return null; });
        long deadline=SystemClock.uptimeMillis()+15000;
        while(!main(previous::isDestroyed) && SystemClock.uptimeMillis()<deadline) SystemClock.sleep(30);
        check(main(previous::isDestroyed),"old Activity fully destroyed before reopening");
        instrumentation.waitForIdleSync(); launch();
    }
    private SetupActivity freshActivity(SetupActivity old,String page,int wantedOrientation,String operation) {
        long deadline=SystemClock.uptimeMillis()+15000;
        do {
            SetupActivity next=lifecycle.resumed.get();
            if(next!=null && next!=old && main(() -> {
                if(next!=lifecycle.created.get() || next!=lifecycle.resumed.get()) return false;
                View root=next.getWindow().getDecorView().findViewWithTag("settings.page."+page);
                return !next.isFinishing() && !next.isDestroyed() && root!=null
                        && root.isAttachedToWindow() && root.isShown() && root.getWidth()>0 && root.getHeight()>0
                        && (wantedOrientation==0 || next.getResources().getConfiguration().orientation==wantedOrientation);
            })) {
                check(true,"new Activity created, resumed and attached on "+page); return next;
            }
            SystemClock.sleep(30);
        } while(SystemClock.uptimeMillis()<deadline);
        throw new AssertionError("Settings Activity has no fresh resumed instance on page "+page
                +"; lifecycle="+lifecycle.lastEvent+"; "+operation);
    }
    private void replaced(SetupActivity old,String page,int wantedOrientation) {
        activity=freshActivity(old,page,wantedOrientation,"framework recreation"); page(page);
    }
    private void recreate(String page) {
        SetupActivity old=activity; main(() -> { old.recreate(); return null; }); replaced(old,page,0);
    }
    private void rotate(String page,boolean landscape) {
        int orientation=landscape?Configuration.ORIENTATION_LANDSCAPE:Configuration.ORIENTATION_PORTRAIT;
        if(main(() -> activity.getResources().getConfiguration().orientation)==orientation) return;
        SetupActivity old=activity;
        main(() -> { old.setRequestedOrientation(landscape?ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE:ActivityInfo.SCREEN_ORIENTATION_PORTRAIT); return null; });
        replaced(old,page,orientation);
        check(main(() -> activity.getResources().getConfiguration().orientation)==orientation,"actual orientation "+orientation);
    }
    private void pageRestoration() {
        open("translation"); recreate("translation");
        selected("settings.translation.",KeyboardSettings.translationDirectionValues(),"en-zh");
        rotate("translation",true); rotate("translation",false); home();
        open("privacy"); main(() -> { activity.onBackPressed(); return null; }); page("home");
    }
    private EditText field(String name) {
        View view=waitView("settings.playground."+name); check(view instanceof EditText,"actual trial field "+name); return (EditText)view;
    }
    private void playgroundPrivacy() {
        open("playground");
        EditText primary=field("primary"),secondary=field("secondary"),password=field("password"),privateField=field("private");
        check(main(() -> !primary.isSaveEnabled() && !secondary.isSaveEnabled() && !password.isSaveEnabled() && !privateField.isSaveEnabled()),"all trial fields disable view state saving");
        check(main(() -> (password.getInputType()&InputType.TYPE_MASK_VARIATION)==InputType.TYPE_TEXT_VARIATION_PASSWORD),"trial password field retains password semantics");
        check(main(() -> (privateField.getImeOptions()&EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING)!=0),"trial private field forbids personalized learning");
        main(() -> { primary.setText(SENTINEL+"😀"); secondary.setText(SENTINEL+"-second"); password.setText(SENTINEL+"-password"); privateField.setText(SENTINEL+"-private"); primary.requestFocus(); return null; });
        main(() -> { context.getSystemService(InputMethodManager.class).showSoftInput(primary,InputMethodManager.SHOW_IMPLICIT); return null; });
        Bundle state=new Bundle(); main(() -> {
            java.lang.reflect.Method save=SetupActivity.class.getDeclaredMethod("onSaveInstanceState",Bundle.class);
            save.setAccessible(true); save.invoke(activity,state); return null;
        });
        Parcel parcel=Parcel.obtain(); byte[] saved;
        try { parcel.writeBundle(state); saved=parcel.marshall(); } finally { parcel.recycle(); }
        check(!contains(saved,SENTINEL.getBytes(StandardCharsets.UTF_8)) && !contains(saved,SENTINEL.getBytes(StandardCharsets.UTF_16LE)),"saved Activity/view state contains no trial text");
        recreate("playground");
        for(String name:new String[]{"primary","secondary","password","private"}) {
            EditText restored=field(name); check(main(() -> restored.getText().length())==0,"recreation clears trial "+name);
        }
        EditText before=field("primary"); main(() -> { before.setText(SENTINEL); before.requestFocus(); return null; });
        home(); check(!main(before::isAttachedToWindow),"leaving trial page retires old field");
        check(main(() -> editableCount(activity.getWindow().getDecorView()))==0,"returning home removes all input targets");
        open("playground");
        for(String name:new String[]{"primary","secondary","password","private"}) {
            EditText fresh=field(name); check(main(() -> fresh.getText().length())==0,"navigation does not retain trial "+name);
        }
        home(); check(preferences.edit().commit(),"settings writes settled after trial");
        check(!preferences.getAll().values().toString().contains(SENTINEL),"trial text never becomes a preference value");
        try {
            String xml=new String(Files.readAllBytes(new File(context.getApplicationInfo().dataDir,"shared_prefs/keyboard.xml").toPath()),StandardCharsets.UTF_8);
            check(!xml.contains(SENTINEL),"trial text absent from persisted settings file");
        } catch(java.io.IOException error) { throw new AssertionError("Settings persistence read failed",error); }
    }
    private static boolean contains(byte[] value,byte[] needle) {
        outer:for(int start=0;start<=value.length-needle.length;start++) {
            for(int i=0;i<needle.length;i++) if(value[start+i]!=needle[i]) continue outer;
            return true;
        }
        return false;
    }
    private Map<String,String> diskPreferences() {
        Map<String,String> result=new LinkedHashMap<>();
        try(java.io.Reader reader=Files.newBufferedReader(new File(context.getApplicationInfo().dataDir,"shared_prefs/keyboard.xml").toPath(),StandardCharsets.UTF_8)) {
            org.xmlpull.v1.XmlPullParser parser=android.util.Xml.newPullParser(); parser.setInput(reader);
            while(parser.next()!=org.xmlpull.v1.XmlPullParser.END_DOCUMENT) {
                if(parser.getEventType()!=org.xmlpull.v1.XmlPullParser.START_TAG) continue;
                String name=parser.getAttributeValue(null,"name");
                if(name==null) continue;
                result.put(name,"string".equals(parser.getName())?parser.nextText():parser.getAttributeValue(null,"value"));
            }
        } catch(Exception error) { throw new AssertionError("Written settings file unavailable",error); }
        return result;
    }
}
