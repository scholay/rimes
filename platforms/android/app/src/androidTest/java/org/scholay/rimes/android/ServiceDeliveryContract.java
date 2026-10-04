package org.scholay.rimes.android;

import android.app.Instrumentation;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.SharedPreferences;
import android.inputmethodservice.InputMethodService;
import android.os.Binder;
import android.os.Handler;
import android.os.Looper;
import android.os.Message;
import android.os.Process;
import android.os.SystemClock;
import android.view.View;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.InputBinding;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import org.scholay.rimes.core.BufferSession;
import org.scholay.rimes.core.ChordGesture;
import org.scholay.rimes.core.ChordLayout;
import org.scholay.rimes.core.PluginSession;
import org.scholay.rimes.core.RimeEngine;

/**
 * Calls the real service delivery methods with a local, synchronously rejecting connection.
 * A remote editor's false return can be obscured by InputConnection IPC, so this deliberately
 * tests below IPC. No service onCreate, native engine, network, real IME binding or app data.
 * Reflection accesses only app state/entries and the public API's protected context attachment;
 * the framework connection is installed through InputMethodImpl.bindInput, never hidden fields.
 */
final class ServiceDeliveryContract {
    private static final String SOURCE="你好😀";
    private static final String OUTPUT="Hello 😀\nA complete generated block.";
    private final Context context;
    private int checks;

    private ServiceDeliveryContract(Context context) { this.context=context; }

    /** Call on the instrumentation thread. Each fixture/connection runs on the actual main Looper. */
    static int run(Instrumentation instrumentation) {
        if(Looper.myLooper()==Looper.getMainLooper()) throw new IllegalStateException("ServiceDeliveryContract must run off main");
        AtomicReference<Throwable> failure=new AtomicReference<>();
        ServiceDeliveryContract contract=new ServiceDeliveryContract(instrumentation.getTargetContext());
        instrumentation.runOnMainSync(() -> {
            try {
                contract.rejectThenRetry(false,false);
                contract.rejectThenRetry(false,true);
                contract.rejectThenRetry(true,true);
                for(boolean plugin:new boolean[]{false,true}) {
                    contract.lostFrameworkBinding(plugin,false);
                    contract.lostFrameworkBinding(plugin,true);
                    contract.retireDuringCommit(plugin);
                }
                contract.translationDirectionPolicy();
                contract.disabledMockPolicy();
                contract.translationSurvivesMockPolicy();
                contract.remoteConfigurationPolicy();
                contract.pluginAuthorizationPolicy();
            } catch(Throwable error) { failure.set(error); }
        });
        if(failure.get()!=null) throw new AssertionError("Service delivery contract failed",failure.get());
        try {
            contract.runningMockPolicy(instrumentation);
            contract.atomicSettingsPair(instrumentation);
            contract.deferredSettingsPair(instrumentation);
        } catch(Throwable error) { throw new AssertionError("Service settings contract failed",error); }
        return contract.checks;
    }

    private void check(boolean condition,String label) {
        checks++; if(!condition) throw new AssertionError(label);
    }

    private void rejectThenRetry(boolean plugin,boolean all) throws Exception {
        try(Fixture fixture=new Fixture(plugin)) {
            String wanted=plugin?OUTPUT:SOURCE;
            List<Integer> before=fixture.expectations();
            fixture.connection.accept=false;
            fixture.send(all);
            check(fixture.connection.attempts==1,"rejected commit is actually attempted");
            check(fixture.connection.accepted.isEmpty(),"rejected commit does not mutate fake host");
            check(wanted.equals(fixture.connection.lastAttempt),"rejected commit contains exact ordinary/generated text");
            check(SOURCE.equals(fixture.buffer.text()),"rejection retains full source");
            check(fixture.selection()==7 && fixture.selectionStart()==7,"rejection keeps both selection positions");
            check(before.equals(fixture.expectations()),"rejection does not add or remove expected selections");
            if(plugin) {
                check(fixture.plugins.snapshot(fixture.buffer).status==PluginSession.Status.READY,"rejected plugin output remains READY");
                check(OUTPUT.equals(fixture.plugins.prepare(fixture.buffer).text),"rejected plugin output remains complete and retryable");
            }
            fixture.connection.accept=true;
            fixture.send(all);
            check(fixture.connection.attempts==2,"retry makes exactly one further commit attempt");
            check(fixture.connection.accepted.size()==1 && wanted.equals(fixture.connection.accepted.get(0)),"retry commits exact text once");
            check(fixture.buffer.text().isEmpty() && fixture.buffer.blockCount()==0,"accepted complete block consumes source once");
            check(fixture.selection()==7+wanted.length() && fixture.selectionStart()==7+wanted.length(),"accepted commit advances by UTF16 units");
            List<Integer> after=new ArrayList<>(before); after.add(7+wanted.length());
            check(after.equals(fixture.expectations()),"accepted commit registers only its actual expected selection");
            if(plugin) {
                check(fixture.plugins.snapshot(fixture.buffer).status==PluginSession.Status.IDLE,"accepted plugin result becomes idle");
                check(fixture.plugins.prepare(fixture.buffer)==null,"accepted plugin result is no longer sendable");
            }
            fixture.send(all);
            check(fixture.connection.attempts==2 && fixture.connection.accepted.size()==1,"repeated Send cannot duplicate consumed output");
            check(after.equals(fixture.expectations()),"empty repeated Send cannot manufacture another selection expectation");
        }
    }

    private void lostFrameworkBinding(boolean plugin,boolean duringCommit) throws Exception {
        try(Fixture fixture=new Fixture(plugin)) {
            Connection next=new Connection(context);
            List<Integer> before=fixture.expectations();
            if(duringCommit) fixture.connection.beforeReturn=() -> fixture.bind(next);
            else fixture.bind(next);
            fixture.connection.accept=true;
            fixture.send(true);
            check(fixture.connection.attempts==(duringCommit?1:0),"old delivery requires the current framework binding");
            check(next.attempts==0,"old delivery never calls the new connection");
            check(SOURCE.equals(fixture.buffer.text()),"lost authorization does not consume captured source");
            check(fixture.selection()==7 && fixture.selectionStart()==7,"lost authorization does not advance selection");
            check(before.equals(fixture.expectations()),"lost authorization leaves expected selections unchanged");
            if(plugin) check(OUTPUT.equals(fixture.plugins.snapshot(fixture.buffer).output),"authorization loss does not acknowledge old plugin result");
        }
    }

    private void retireDuringCommit(boolean plugin) throws Exception {
        try(Fixture fixture=new Fixture(plugin)) {
            Connection next=new Connection(context);
            fixture.connection.accept=true;
            fixture.connection.beforeReturn=() -> {
                // Use the service's real retirement callback, then install a fresh synthetic target.
                fixture.service.onUnbindInput();
                fixture.bind(next);
                set(fixture.service,"target",next);
                fixture.buffer.beginTarget(true); fixture.buffer.setEnabled(true);
                fixture.buffer.appendCommittedBlock("新目标😀");
                set(fixture.service,"selection",19); set(fixture.service,"selectionStart",19);
                fixture.expected().add(17);
            };
            fixture.send(true);
            check(fixture.connection.attempts==1 && fixture.connection.accepted.size()==1,"old connection may accept before retirement returns");
            check(next.attempts==0,"commit-time retirement never forwards output to new target");
            check("新目标😀".equals(fixture.buffer.text()),"old acknowledgement cannot consume the new target draft");
            check(fixture.selection()==19 && fixture.selectionStart()==19,"old commit cannot overwrite new target selection");
            check(fixture.expectations().size()==1 && fixture.expectations().get(0)==17,"old commit cannot add an expectation to new target");
            check(fixture.plugins.snapshot(fixture.buffer).plugin==null && fixture.plugins.snapshot(fixture.buffer).output.isEmpty(),"retirement clears plugin selection and output");
        }
    }

    private void translationDirectionPolicy() throws Exception {
        try(Fixture fixture=new Fixture(true)) {
            PluginSession.Request old=fixture.preparedRequest;
            long serial=fixture.plugins.snapshot(fixture.buffer).requestSerial;
            fixture.settings.setTranslationDirection("auto");
            check(fixture.plugins.snapshot(fixture.buffer).status==PluginSession.Status.READY
                    && fixture.plugins.snapshot(fixture.buffer).requestSerial==serial,"unchanged direction preserves a completed translation");
            fixture.settings.setTranslationDirection("en-zh");
            check("en-zh".equals(get(fixture.service,"translationDirection")),"external direction notification updates service policy");
            check(fixture.plugins.snapshot(fixture.buffer).status==PluginSession.Status.IDLE
                    && fixture.plugins.snapshot(fixture.buffer).output.isEmpty(),"external direction change invalidates old output");
            check(SOURCE.equals(fixture.buffer.text()) && fixture.connection.attempts==0,"direction change retains source without host delivery");
            check(!fixture.plugins.update(old,fixture.buffer,OUTPUT,true)
                    && !fixture.plugins.fail(old,fixture.buffer,"late failure"),"old direction request rejects late success and failure");
            fixture.settings.setTranslationDirection("auto");
            check(!fixture.plugins.update(old,fixture.buffer,OUTPUT,true)
                    && fixture.plugins.prepare(fixture.buffer)==null,"returning to old direction cannot revive its request");
            fixture.send(true);
            check(fixture.connection.attempts==0 && SOURCE.equals(fixture.buffer.text()),"invalidated translation is unsendable");
        }
        try(Fixture fixture=new Fixture(false)) {
            fixture.prepare("ask",OUTPUT);
            fixture.settings.setTranslationDirection("zh-en");
            check(fixture.plugins.snapshot(fixture.buffer).status==PluginSession.Status.READY
                    && OUTPUT.equals(fixture.plugins.snapshot(fixture.buffer).output),"translation direction does not discard unrelated AI output");
        }
    }

    private void disabledMockPolicy() throws Exception {
        try(Fixture fixture=new Fixture(false)) {
            PluginSession.Request old=fixture.prepare("ask",OUTPUT);
            fixture.settings.setAiMockEnabled(false);
            check(!(Boolean)get(fixture.service,"aiMockEnabled"),"external Mock setting reaches service");
            check(fixture.plugins.snapshot(fixture.buffer).status==PluginSession.Status.IDLE
                    && fixture.plugins.snapshot(fixture.buffer).output.isEmpty(),"disabling Mock invalidates completed AI output");
            check(SOURCE.equals(fixture.buffer.text()) && fixture.connection.attempts==0,"disabling Mock preserves source and host");
            invoke(fixture.service,"runPlugin",new Class<?>[0]);
            fixture.send(false);
            check(get(fixture.service,"pluginJob")==null && fixture.connection.attempts==0
                    && fixture.plugins.snapshot(fixture.buffer).status==PluginSession.Status.IDLE,"disabled Mock rejects Run and Send");
            // Exercise the insertion gate independently from request invalidation.
            PluginSession.Request injected=fixture.prepare("ask",OUTPUT);
            fixture.send(true);
            check(fixture.plugins.snapshot(fixture.buffer).status==PluginSession.Status.READY
                    && fixture.connection.attempts==0 && SOURCE.equals(fixture.buffer.text()),"disabled Mock rejects even a current completed result");
            fixture.settings.setAiMockEnabled(true);
            check(!fixture.plugins.update(old,fixture.buffer,OUTPUT,true)
                    && !fixture.plugins.update(injected,fixture.buffer,OUTPUT,true)
                    && fixture.plugins.prepare(fixture.buffer)==null,"re-enabling Mock never revives pre-policy results");
        }
    }

    private void translationSurvivesMockPolicy() throws Exception {
        try(Fixture fixture=new Fixture(true)) {
            fixture.settings.setAiMockEnabled(false);
            check(fixture.plugins.snapshot(fixture.buffer).status==PluginSession.Status.READY
                    && SOURCE.equals(fixture.buffer.text()),"Mock switch preserves offline translation and source");
            fixture.connection.accept=true; fixture.send(true);
            check(fixture.connection.accepted.size()==1 && OUTPUT.equals(fixture.connection.accepted.get(0))
                    && fixture.buffer.text().isEmpty(),"translation remains sendable while AI Mock is disabled");
        }
    }

    private interface MainAction { void run() throws Exception; }
    private void onMain(Instrumentation instrumentation,MainAction action) throws Exception {
        AtomicReference<Throwable> failure=new AtomicReference<>();
        instrumentation.runOnMainSync(() -> { try { action.run(); } catch(Throwable error) { failure.set(error); } });
        Throwable error=failure.get();
        if(error instanceof Error) throw (Error)error;
        if(error instanceof Exception) throw (Exception)error;
    }
    private void engineIdle(Instrumentation instrumentation) throws Exception {
        EngineWorker.QUEUE.submit(() -> {}).get(10,TimeUnit.SECONDS);
        instrumentation.waitForIdleSync();
    }

    /** Hold the real service's posted worker callbacks, then replay them after an off/on cycle. */
    private void runningMockPolicy(Instrumentation instrumentation) throws Exception {
        AtomicReference<Fixture> reference=new AtomicReference<>();
        onMain(instrumentation,() -> {
            Fixture fixture=new Fixture(false); reference.set(fixture);
            fixture.holding=new HoldingHandler(); set(fixture.service,"main",fixture.holding);
            set(fixture.service,"activePlugin","ask"); fixture.plugins.select("ask");
            invoke(fixture.service,"runPlugin",new Class<?>[0]);
            check(fixture.plugins.snapshot(fixture.buffer).status==PluginSession.Status.RUNNING
                    && get(fixture.service,"pluginJob")!=null,"real Mock worker starts under enabled policy");
        });
        try {
            AtomicInteger held=new AtomicInteger(); long deadline=SystemClock.elapsedRealtime()+15000;
            do {
                onMain(instrumentation,() -> held.set(reference.get().holding.callbacks.size()));
                if(held.get()>0) break;
                SystemClock.sleep(20);
            } while(SystemClock.elapsedRealtime()<deadline);
            check(held.get()>0,"real worker posted an observable callback within 15s");
            onMain(instrumentation,() -> {
                Fixture fixture=reference.get();
                BufferPluginExecutor.Job old=(BufferPluginExecutor.Job)get(fixture.service,"pluginJob");
                fixture.settings.setAiMockEnabled(false);
                Field token=old.getClass().getDeclaredField("cancellation"); token.setAccessible(true);
                check(((PluginCancellation)token.get(old)).isCancelled() && get(fixture.service,"pluginJob")==null,"disabling Mock cancels and detaches the actual Job");
                invoke(fixture.service,"runPlugin",new Class<?>[0]); fixture.send(true);
                check(fixture.connection.attempts==0 && fixture.plugins.snapshot(fixture.buffer).status==PluginSession.Status.IDLE,"disabled running Mock cannot restart or send");
                fixture.settings.setAiMockEnabled(true);
                fixture.holding.replay();
                check(fixture.plugins.snapshot(fixture.buffer).status==PluginSession.Status.IDLE
                        && fixture.plugins.snapshot(fixture.buffer).output.isEmpty(),"already-posted callbacks cannot revive request after off/on");
                check(SOURCE.equals(fixture.buffer.text()) && fixture.connection.attempts==0,"cancelled callback replay retains source and host");
            });
        } finally { onMain(instrumentation,() -> { if(reference.get()!=null) reference.get().close(); }); }
    }

    private void atomicSettingsPair(Instrumentation instrumentation) throws Exception {
        AtomicReference<Fixture> reference=new AtomicReference<>(); RecordingEngine engine=new RecordingEngine("nihk");
        onMain(instrumentation,() -> {
            Fixture fixture=new Fixture(false); reference.set(fixture);
            fixture.preferences.edit().putString(KeyboardSettings.KEY_SCHEMA,"rimes_wubi").apply();
            set(fixture.service,"engine",engine); set(fixture.service,"session",1L); set(fixture.service,"ready",true);
            set(fixture.service,"snapshot",engine.current);
            for(String flag:new String[]{"numeric","symbols","emoji","uppercase","english"}) set(fixture.service,flag,true);
            fixture.settings.setLayout("nineKey");
            check("rimes_pinyin".equals(get(fixture.service,"schema")) && "nineKey".equals(get(fixture.service,"layout")),"per-key notifications apply the final schema/layout pair");
            check((Integer)get(fixture.service,"pending")==1,"one atomic pair dispatches one old-code settlement");
            for(String flag:new String[]{"numeric","symbols","emoji","uppercase","english"}) check(!(Boolean)get(fixture.service,flag),"external nine-key change resets "+flag);
        });
        try {
            engineIdle(instrumentation);
            onMain(instrumentation,() -> {
                Fixture fixture=reference.get();
                check(engine.clears.get()==1 && engine.snapshots.get()==1 && engine.selections.get()==1,"atomic notifications clear/read/switch engine exactly once");
                check("rimes_pinyin9".equals(engine.selected),"final pair selects the nine-key Pinyin engine");
                check((SOURCE+"nihk").equals(fixture.buffer.text()) && fixture.connection.attempts==0,"old raw code settles once into existing Buffer");
                check((Integer)get(fixture.service,"pending")==0,"single settlement finishes without stale pending count");
            });
        } finally { onMain(instrumentation,() -> { if(reference.get()!=null) reference.get().close(); }); }
    }

    private void deferredSettingsPair(Instrumentation instrumentation) throws Exception {
        AtomicReference<Fixture> reference=new AtomicReference<>(); RecordingEngine engine=new RecordingEngine("");
        onMain(instrumentation,() -> {
            Fixture fixture=new Fixture(false); reference.set(fixture);
            char[] full=new char[BufferSession.MAX_CHARACTERS]; java.util.Arrays.fill(full,'x');
            fixture.buffer.clear(); fixture.buffer.appendCommittedBlock(new String(full));
            // The service itself creates an undeliverable literal and retains it at the capacity bound.
            invoke(fixture.service,"type",new Class<?>[]{String.class},"!");
            check(!((String)get(fixture.service,"retained")).isEmpty(),"capacity failure creates real retained delivery");
            set(fixture.service,"engine",engine); set(fixture.service,"session",1L); set(fixture.service,"ready",true);
            set(fixture.service,"snapshot",engine.current);
            fixture.settings.setLayout("nineKey");
            check("qwerty".equals(get(fixture.service,"layout")) && get(fixture.service,"deferredSettingsPair")!=null,"settings pair defers while old delivery cannot be consumed");
            check(engine.clears.get()==0 && (Integer)get(fixture.service,"pending")==0,"deferred mode does not prematurely settle or switch engine");
            fixture.buffer.deleteLastBlock();
            invoke(fixture.service,"retryRetained",new Class<?>[0]);
            check("nineKey".equals(get(fixture.service,"layout")) && get(fixture.service,"deferredSettingsPair")==null,"successful retained retry applies saved settings pair");
        });
        try {
            engineIdle(instrumentation);
            onMain(instrumentation,() -> {
                Fixture fixture=reference.get();
                check("!".equals(fixture.buffer.text()) && fixture.connection.attempts==0,"retry preserves old literal without sending it to the host");
                check(engine.clears.get()==0 && engine.snapshots.get()==1 && engine.selections.get()==1,"deferred atomic pair switches once after successful retry");
            });
        } finally { onMain(instrumentation,() -> { if(reference.get()!=null) reference.get().close(); }); }
    }

    private final class Fixture implements AutoCloseable {
        final RimesInputMethodService service=new RimesInputMethodService();
        final InputMethodService.InputMethodImpl input;
        final BufferSession buffer;
        final PluginSession plugins;
        final MemoryPreferences preferences=new MemoryPreferences();
        final KeyboardSettings settings=new KeyboardSettings(preferences);
        final PluginTestContext pluginContext;
        final OfficialPluginStore officialPlugins;
        final BufferPluginExecutor executor;
        final Connection connection=new Connection(context);
        PluginSession.Request preparedRequest;
        HoldingHandler holding;
        Fixture(boolean plugin) throws Exception {
            pluginContext=new PluginTestContext(context,true);
            officialPlugins=new OfficialPluginStore(pluginContext); executor=new BufferPluginExecutor(pluginContext);
            set(service,"officialPlugins",officialPlugins);
            Method attach=ContextWrapper.class.getDeclaredMethod("attachBaseContext",Context.class);
            attach.setAccessible(true); attach.invoke(service,context);
            input=(InputMethodService.InputMethodImpl)service.onCreateInputMethodInterface();
            bind(connection);
            check(service.getCurrentInputConnection()==connection,"public framework bind installs the exact fake connection");
            set(service,"target",connection); set(service,"selection",7); set(service,"selectionStart",7);
            set(service,"preferences",preferences); set(service,"settings",settings); set(service,"pluginExecutor",executor);
            set(service,"cometSettings",new OpenAiSettings(preferences));
            preferences.registerOnSharedPreferenceChangeListener((SharedPreferences.OnSharedPreferenceChangeListener)get(service,"preferenceListener"));
            invoke(service,"restoreSettings",new Class<?>[0]);
            // No UI is created. A real idle ChordSurface satisfies the ordinary send policy gate.
            set(service,"chords",new ChordSurface(context,new ChordSurface.Handler() {
                public void onChord(String code) {}
                public void onKey(String text) {}
                public void onPreview(ChordGesture.Preview preview) {}
                public void onControl(ChordLayout.Action action) {}
                public String label(ChordLayout.Action action) { return ""; }
                public String description(ChordLayout.Action action) { return ""; }
            }));
            buffer=(BufferSession)get(service,"buffer"); plugins=(PluginSession)get(service,"pluginSession");
            buffer.beginTarget(true); buffer.setEnabled(true); buffer.appendCommittedBlock(SOURCE);
            expected().add(3);
            if(plugin) preparedRequest=prepare("translate",OUTPUT);
        }
        PluginSession.Request prepare(String plugin,String output) throws Exception {
            set(service,"activePlugin",plugin); plugins.select(plugin);
            set(service,"pluginResultAuthorization",officialPlugins.grant(plugin));
            PluginSession.Request request=plugins.start(buffer);
            check(request!=null && plugins.update(request,buffer,output,true),"real model prepares a completed captured-source result");
            return request;
        }
        void bind(Connection target) { input.bindInput(new InputBinding(target,new Binder(),Process.myUid(),Process.myPid())); }
        void send(boolean all) throws Exception { invoke(service,"insertNow",new Class<?>[]{boolean.class},all); }
        int selection() throws Exception { return (Integer)get(service,"selection"); }
        int selectionStart() throws Exception { return (Integer)get(service,"selectionStart"); }
        @SuppressWarnings("unchecked") ArrayDeque<Integer> expected() throws Exception { return (ArrayDeque<Integer>)get(service,"expectedSelections"); }
        List<Integer> expectations() throws Exception { return new ArrayList<>(expected()); }
        @Override public void close() throws Exception {
            executor.close(); preferences.unregisterOnSharedPreferenceChangeListener((SharedPreferences.OnSharedPreferenceChangeListener)get(service,"preferenceListener"));
            ((Handler)get(service,"main")).removeCallbacksAndMessages(null);
            if(holding!=null) holding.callbacks.clear();
            input.unbindInput(); pluginContext.close();
        }
    }
    private void pluginAuthorizationPolicy() throws Exception {
        try(Fixture fixture=new Fixture(true)) {
            OfficialPluginStore.Entry entry=fixture.officialPlugins.entry("translate");
            fixture.officialPlugins.setEnabled(entry,false);
            fixture.officialPlugins.setEnabled(entry,true);
            fixture.send(true);
            check(fixture.connection.attempts==0,"disable and reenable cannot deliver a completed result under the old grant");
            check(SOURCE.equals(fixture.buffer.text()),"plugin revocation preserves Buffer source");
            fixture.prepare("translate",OUTPUT); fixture.send(true);
            check(fixture.connection.attempts==1,"fresh generation under current grant reaches the host");
        }
    }
    private void remoteConfigurationPolicy() throws Exception {
        try(Fixture fixture=new Fixture(false)) {
            fixture.settings.setAiMockEnabled(false);
            fixture.preferences.edit().putString(OpenAiSettings.KEY,"{\"enabled\":true,\"translation\":true,\"model\":\"deepseek-v4-flash\"}").apply();
            PluginSession.Request old=fixture.prepare("ask",OUTPUT);
            check((Boolean)invoke(fixture.service,"pluginAllowed",new Class<?>[0]),"online AI works independently of demo toggle");
            fixture.preferences.edit().putString(OpenAiSettings.KEY,"{\"enabled\":true,\"translation\":true,\"model\":\"changed-model\"}").apply();
            check(fixture.plugins.snapshot(fixture.buffer).status==PluginSession.Status.IDLE,"provider setting change revokes completed output");
            check(!fixture.plugins.update(old,fixture.buffer,OUTPUT,true),"old provider callback cannot restore revoked result");
            check(SOURCE.equals(fixture.buffer.text()),"provider setting change retains source");
            fixture.prepare("ask",OUTPUT);
            fixture.preferences.edit().remove(OpenAiSettings.KEY).apply();
            fixture.send(true);
            check(fixture.connection.attempts==0,"disable blocks stale online delivery");
            check(!(Boolean)invoke(fixture.service,"pluginAllowed",new Class<?>[0]),"disabled remote and mock deny AI");
        }
    }

    /** Main-Looper messages are genuinely dispatched, but their app callbacks await explicit replay. */
    private static final class HoldingHandler extends Handler {
        final ArrayDeque<Runnable> callbacks=new ArrayDeque<>();
        HoldingHandler() { super(Looper.getMainLooper()); }
        @Override public void dispatchMessage(Message message) {
            Runnable callback=message.getCallback();
            if(callback==null) super.dispatchMessage(message); else callbacks.add(callback);
        }
        void replay() { while(!callbacks.isEmpty()) callbacks.remove().run(); }
    }

    private static final class RecordingEngine implements RimeEngine {
        final AtomicInteger snapshots=new AtomicInteger(),clears=new AtomicInteger(),selections=new AtomicInteger();
        volatile Snapshot current;
        volatile String selected="";
        RecordingEngine(String raw) { current=new Snapshot(true,raw,raw,raw.length(),"",new String[0],new String[0],0,0,true); }
        private void offMain() { if(Looper.myLooper()==Looper.getMainLooper()) throw new AssertionError("engine policy operation ran on main"); }
        public void initialize(String system,String user) { throw new AssertionError("fixture cannot initialize a native engine"); }
        public long createSession() { throw new AssertionError("fixture cannot create a native session"); }
        public void destroySession(long session) { offMain(); }
        public boolean selectSchema(long session,String schema) { offMain(); selected=schema; selections.incrementAndGet(); return true; }
        public Snapshot processKey(long session,int key) { throw new AssertionError("fixture cannot invent key processing"); }
        public Snapshot selectCandidate(long session,int index) { throw new AssertionError("fixture cannot invent candidates"); }
        public Snapshot snapshot(long session) { offMain(); snapshots.incrementAndGet(); return current; }
        public void clearComposition(long session) { offMain(); clears.incrementAndGet(); current=Snapshot.EMPTY; }
    }

    /** Isolated atomic storage; uses the production Settings model and production service listener. */
    private static final class MemoryPreferences implements SharedPreferences {
        private final Map<String,Object> values=new HashMap<>();
        private final Set<OnSharedPreferenceChangeListener> listeners=new LinkedHashSet<>();
        public Map<String,?> getAll() { return new HashMap<>(values); }
        public String getString(String key,String fallback) { return (String)values.getOrDefault(key,fallback); }
        @SuppressWarnings("unchecked") public Set<String> getStringSet(String key,Set<String> fallback) { return (Set<String>)values.getOrDefault(key,fallback); }
        public int getInt(String key,int fallback) { return (Integer)values.getOrDefault(key,fallback); }
        public long getLong(String key,long fallback) { return (Long)values.getOrDefault(key,fallback); }
        public float getFloat(String key,float fallback) { return (Float)values.getOrDefault(key,fallback); }
        public boolean getBoolean(String key,boolean fallback) { return (Boolean)values.getOrDefault(key,fallback); }
        public boolean contains(String key) { return values.containsKey(key); }
        public void registerOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener listener) { listeners.add(listener); }
        public void unregisterOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener listener) { listeners.remove(listener); }
        public Editor edit() { return new Editor() {
            private final Map<String,Object> pending=new LinkedHashMap<>();
            private boolean clear;
            public Editor putString(String key,String value) { pending.put(key,value); return this; }
            public Editor putStringSet(String key,Set<String> value) { pending.put(key,value==null?null:new LinkedHashSet<>(value)); return this; }
            public Editor putInt(String key,int value) { pending.put(key,value); return this; }
            public Editor putLong(String key,long value) { pending.put(key,value); return this; }
            public Editor putFloat(String key,float value) { pending.put(key,value); return this; }
            public Editor putBoolean(String key,boolean value) { pending.put(key,value); return this; }
            public Editor remove(String key) { pending.put(key,null); return this; }
            public Editor clear() { clear=true; return this; }
            public boolean commit() { apply(); return true; }
            public void apply() {
                if(Looper.myLooper()!=Looper.getMainLooper()) throw new AssertionError("fixture preferences must notify on main");
                Set<String> changed=new LinkedHashSet<>();
                if(clear) { changed.addAll(values.keySet()); values.clear(); }
                for(Map.Entry<String,Object> entry:pending.entrySet()) {
                    String key=entry.getKey(); Object value=entry.getValue();
                    if(!java.util.Objects.equals(values.get(key),value)) changed.add(key);
                    if(value==null) values.remove(key); else values.put(key,value);
                }
                // Publish all mutations before individual notifications, matching SharedPreferences.
                for(String key:changed) for(OnSharedPreferenceChangeListener listener:new ArrayList<>(listeners)) listener.onSharedPreferenceChanged(MemoryPreferences.this,key);
            }
        }; }
    }

    private interface BeforeReturn { void run() throws Exception; }
    private static final class Connection extends BaseInputConnection {
        boolean accept;
        int attempts;
        String lastAttempt="";
        final List<String> accepted=new ArrayList<>();
        BeforeReturn beforeReturn;
        Connection(Context context) { super(new View(context),true); }
        @Override public boolean commitText(CharSequence text,int newCursorPosition) {
            if(Looper.myLooper()!=Looper.getMainLooper()) throw new AssertionError("service commit left the main owner");
            attempts++; lastAttempt=text.toString();
            if(newCursorPosition!=1) throw new AssertionError("service commit changed cursor semantics");
            if(accept) accepted.add(lastAttempt);
            if(beforeReturn!=null) {
                BeforeReturn action=beforeReturn; beforeReturn=null;
                try { action.run(); }
                catch(Exception error) { throw new AssertionError("commit-time target transition failed",error); }
            }
            return accept;
        }
    }

    private static Object get(Object instance,String name) throws Exception {
        Field field=RimesInputMethodService.class.getDeclaredField(name); field.setAccessible(true); return field.get(instance);
    }
    private static void set(Object instance,String name,Object value) throws Exception {
        Field field=RimesInputMethodService.class.getDeclaredField(name); field.setAccessible(true); field.set(instance,value);
    }
    private static Object invoke(Object instance,String name,Class<?>[] types,Object... values) throws Exception {
        Method method=RimesInputMethodService.class.getDeclaredMethod(name,types); method.setAccessible(true);
        try { return method.invoke(instance,values); }
        catch(InvocationTargetException error) {
            Throwable cause=error.getCause();
            if(cause instanceof Error) throw (Error)cause;
            if(cause instanceof Exception) throw (Exception)cause;
            throw error;
        }
    }
}
