package org.scholay.rimes.android;

import android.content.SharedPreferences;
import android.content.res.Configuration;
import android.inputmethodservice.InputMethodService;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.view.View;
import android.view.WindowInsets;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.view.Gravity;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import org.scholay.rimes.core.BufferSession;
import org.scholay.rimes.core.InputEpoch;
import org.scholay.rimes.core.PluginSession;
import org.scholay.rimes.core.RimeEngine;
import org.scholay.rimes.core.KeyboardLayout;
import org.scholay.rimes.core.NineKeyPinyin;
import org.scholay.rimes.core.ChordGesture;
import org.scholay.rimes.core.ChordLayout;

/** All host mutations use the exact live InputConnection; engine results carry an editor lease. */
public final class RimesInputMethodService extends InputMethodService {
    private final BufferSession buffer=new BufferSession();
    private final InputEpoch epoch=new InputEpoch();
    private final Handler main=new Handler(Looper.getMainLooper());
    private final ArrayDeque<Integer> expectedSelections=new ArrayDeque<>();
    private InputConnection target;
    private SharedPreferences preferences;
    private KeyboardSettings settings;
    private OpenAiSettings cometSettings;
    private OpenAiSettings.Snapshot cometProfile=OpenAiSettings.disabled();
    private String translationDirection="auto";
    private boolean aiMockEnabled=true,learningEnabled=true,changingSettingsPair;
    private KeyboardSettings.Snapshot deferredSettingsPair;
    private final SharedPreferences.OnSharedPreferenceChangeListener preferenceListener=this::preferenceChanged;
    private KeyboardRoot keyboard;
    private LinearLayout bufferRow, candidateRow, spellingRow, chordFooter;
    private BufferRail bufferRail,pluginOutput;
    private final PluginSession pluginSession=new PluginSession();
    private BufferPluginExecutor pluginExecutor;
    private OfficialPluginStore officialPlugins;
    private SharedPreferences officialPluginPreferences;
    private final SharedPreferences.OnSharedPreferenceChangeListener officialPluginListener=(prefs,key) -> main.post(() -> {
        if(this.destroyed) return;
        cancelChord(); invalidatePlugin();
        if(this.activePlugin!=null && !officialPlugins.enabled(this.activePlugin)) { this.activePlugin=null; pluginSession.clear(); this.pluginSettingsOpen=false; }
        resetEngine(); render();
    });
    private BufferPluginExecutor.Job pluginJob;
    private ChordSurface chords;
    private TextView metrics;
    private final List<KeyButton> spellingButtons=new ArrayList<>();
    private final List<KeyButton> chordControls=new ArrayList<>();
    private String chordPreview="",hostPreedit="";
    private KeyboardSurface keys;
    private KeyboardAppearancePanel appearancePanel;
    private PluginShortcutBar pluginShortcuts;
    private BufferPluginPanel pluginPanel;
    private String activePlugin;
    private String pluginResultAuthorization;
    private boolean pluginSettingsOpen, renderedPluginMode;
    private LinearLayout bufferTop,bufferBottom;
    private KeyButton bufferSettings,pluginButton,pluginRunButton;
    private FrameLayout surfaceContainer;
    private KeyButton themeButton,layoutButton;
    private final List<KeyButton> chromeButtons=new ArrayList<>();
    private KeyboardTheme theme=KeyboardTheme.ALL[0];
    private String layout="qwerty";
    private boolean symbols,emoji,appearanceOpen,spellingOpen,punctuationOpen;
    private int spellingPage;
    private NineKeyPinyin spellings=new NineKeyPinyin(java.util.Collections.emptyList());
    private List<String> spellingChoices=java.util.Collections.emptyList();
    private static final String[] MARKS={",",".","?","!","、",":",";","'"};
    private static final String[] MARK_LABELS={"，","。","？","！","、","：","；","'"};
    private TextView preedit;
    private HorizontalScrollView candidateScroll;
    private ChordPreview chordReadout;
    private ChordGesture.Preview heldPreview;
    private String renderedRaw="";
    private int renderedPage=-1;
    private Button bufferButton, retryButton, previous, next, insertNext;
    private final List<Button> candidates=new ArrayList<>();
    private boolean uppercase, numeric, directOnly, privateField, english, ready, failed, destroyed;
    private boolean hostComposing;
    private int pending, selection=-1, selectionStart=-1, composingStart=-1;
    private String schema="rimes_pinyin", retained="";
    private final ArrayDeque<Result> retainedResults=new ArrayDeque<>();
    private RimeEngine.Snapshot snapshot=RimeEngine.Snapshot.EMPTY;
    // Worker-owned state. Access only inside EngineWorker.QUEUE.
    private RimeEngine engine;
    private long session;
    private static final String[] SCHEMAS={"rimes_pinyin","rimes_ziranma","rimes_wubi"};
    private static final String[] NAMES={"拼音","自然码","五笔"};

    @Override public void onCreate() {
        super.onCreate();
        officialPlugins=new OfficialPluginStore(this);
        officialPluginPreferences=getSharedPreferences(OfficialPluginStore.PREFERENCES,MODE_PRIVATE);
        officialPluginPreferences.registerOnSharedPreferenceChangeListener(officialPluginListener);
        preferences=getSharedPreferences(KeyboardSettings.PREFERENCES_NAME,MODE_PRIVATE);
        settings=new KeyboardSettings(preferences);
        cometSettings=new OpenAiSettings(this);
        preferences.registerOnSharedPreferenceChangeListener(preferenceListener);
        restoreSettings();
        pluginExecutor=new BufferPluginExecutor(getApplicationContext());
        initialize();
    }
    private void initialize() {
        failed=false; ready=false; render();
        EngineWorker.QUEUE.execute(() -> {
            try {
                java.io.File resources=EngineResources.prepare(getApplicationContext());
                org.json.JSONArray syllables=new org.json.JSONArray(new String(java.nio.file.Files.readAllBytes(new java.io.File(resources,"nine-key-syllables.json").toPath()),java.nio.charset.StandardCharsets.UTF_8));
                List<String> syllableList=new ArrayList<>();
                for(int i=0;i<syllables.length();i++) syllableList.add(syllables.getString(i));
                NineKeyPinyin spelling=new NineKeyPinyin(syllableList);
                if(engine==null) engine=new NativeRimeEngine();
                engine.initialize(resources.getAbsolutePath(),EngineResources.userDirectory(getApplicationContext()).getAbsolutePath());
                main.post(() -> { if(!destroyed) { spellings=spelling; ready=true; resetEngine(); render(); } });
            } catch(Exception | LinkageError error) {
                android.util.Log.e("RIMES","Engine initialization failed",error);
                main.post(() -> { if(!destroyed) { failed=true; ready=false; render(); } });
            }
        });
    }
    @Override public void onStartInput(EditorInfo info,boolean restarting) {
        super.onStartInput(info,restarting);
        endTarget();
        target=getCurrentInputConnection();
        configure(info);
    }
    private void configure(EditorInfo info) {
        restoreSettings();
        int kind=info.inputType&InputType.TYPE_MASK_CLASS;
        numeric=kind==InputType.TYPE_CLASS_NUMBER || kind==InputType.TYPE_CLASS_PHONE || kind==InputType.TYPE_CLASS_DATETIME;
        directOnly=numeric || isPassword(info) || kind!=InputType.TYPE_CLASS_TEXT;
        privateField=!allowsBuffer(info);
        uppercase=false; symbols=false; emoji=false; appearanceOpen=false; spellingOpen=false; punctuationOpen=false;
        selection=info.initialSelEnd; selectionStart=info.initialSelStart;
        buffer.beginTarget(target!=null && allowsBuffer(info));
        resetEngine(); rebuildKeys(); render();
    }
    @Override public void onStartInputView(EditorInfo info,boolean restarting) {
        super.onStartInputView(info,restarting);
        if(target==null) { target=getCurrentInputConnection(); configure(info); }
        render();
    }
    private String effectiveSchema() { return (chordLayout()?"rimes_ziranma":nineKeyEngine()?"rimes_pinyin9":schema)+(privateField || !learningEnabled ? "_private" : ""); }
    private void resetEngine() {
        if(!ready) return;
        final String selected=effectiveSchema();
        final boolean active=target!=null;
        final InputEpoch.Ticket ticket=epoch.issue();
        EngineWorker.QUEUE.execute(() -> {
            if(session!=0) engine.destroySession(session);
            session=active ? engine.createSession() : 0;
            if(active && (session==0 || !engine.selectSchema(session,selected))) main.post(() -> { if(epoch.current(ticket)) engineFailure(); });
        });
    }
    private void engineFailure() { if(!destroyed) { failed=true; ready=false; render(); } }
    @Override public boolean onEvaluateFullscreenMode() { return false; }
    @Override public void onFinishInputView(boolean finishingInput) { endTarget(); super.onFinishInputView(finishingInput); }
    @Override public void onFinishInput() { endTarget(); super.onFinishInput(); }
    @Override public void onUnbindInput() { endTarget(); super.onUnbindInput(); }
    @Override public void onDestroy() {
        preferences.unregisterOnSharedPreferenceChangeListener(preferenceListener);
        officialPluginPreferences.unregisterOnSharedPreferenceChangeListener(officialPluginListener);
        endTarget(); destroyed=true; pluginExecutor.close(); super.onDestroy();
    }
    private void restoreSettings() {
        KeyboardSettings.Snapshot saved=settings.snapshot();
        cometProfile=cometSettings.snapshot();
        schema=saved.schema; layout=saved.layout; theme=KeyboardTheme.named(saved.theme);
        translationDirection=saved.translationDirection; aiMockEnabled=saved.aiMockEnabled; learningEnabled=saved.learning;
    }
    private void changeSettingsPair(Runnable write) {
        changingSettingsPair=true;
        try { write.run(); KeyboardSettings.Snapshot saved=settings.snapshot(); schema=saved.schema; layout=saved.layout; }
        finally { changingSettingsPair=false; }
    }
    private void applySettingsPair(KeyboardSettings.Snapshot saved) {
        if(saved.schema.equals(schema) && saved.layout.equals(layout)) { deferredSettingsPair=null; return; }
        // A failed host insertion must be retried with its original route before switching modes.
        if(!retained.isEmpty()) { deferredSettingsPair=saved; return; }
        deferredSettingsPair=null;
        boolean layoutChanged=!layout.equals(saved.layout);
        Runnable change=() -> {
            schema=saved.schema; layout=saved.layout; spellingOpen=false;
            if(layoutChanged) { numeric=false; symbols=false; emoji=false; uppercase=false; if(chordLayout() || layout.equals("nineKey")) english=false; }
        };
        if(ownsTarget()) settleAndSwitch(change); else { cancelChord(); change.run(); render(); }
    }
    private boolean chordLayout() { return officialPlugins!=null && officialPlugins.enabled("chord") && (layout.equals("orthogonal") || layout.equals("splitOrthogonal")); }
    private boolean chordVisible() { return ready && chordLayout() && !directOnly && !numeric && !emoji; }
    private void cancelChord() {
        if(keyboard!=null) keyboard.cancelPendingInputEvents();
        heldPreview=null; chordPreview=""; if(chords!=null) chords.cancel();
    }
    private void chooseSchema(String selected) {
        settleAndSwitch(() -> { changeSettingsPair(() -> settings.setSchema(selected)); spellingOpen=false; });
    }
    private boolean nineKeyEngine() { return layout.equals("nineKey") && schema.equals("rimes_pinyin"); }
    private boolean nineKeyVisible() { return ready && nineKeyEngine() && !directOnly && !english && !numeric && !emoji && !uppercase; }
    private void preferenceChanged(SharedPreferences changed,String key) {
        if(destroyed || changingSettingsPair) return;
        KeyboardSettings.Snapshot saved=settings.snapshot();
        if(OpenAiSettings.KEY.equals(key)) {
            cometProfile=cometSettings.snapshot(); invalidatePlugin(); render(); return;
        }
        if(KeyboardSettings.KEY_THEME.equals(key)) { theme=KeyboardTheme.named(saved.theme); render(); return; }
        if(KeyboardSettings.KEY_SCHEMA.equals(key) || KeyboardSettings.KEY_LAYOUT.equals(key)) {
            // Both per-key notifications see the same atomic pair. Settle the old code only once.
            applySettingsPair(saved);
            return;
        }
        if(KeyboardSettings.KEY_TRANSLATION_DIRECTION.equals(key)) {
            if(!saved.translationDirection.equals(translationDirection)) {
                translationDirection=saved.translationDirection;
                if("translate".equals(activePlugin)) invalidatePlugin();
                render();
            }
            return;
        }
        if(KeyboardSettings.KEY_AI_MOCK_ENABLED.equals(key)) {
            if(saved.aiMockEnabled!=aiMockEnabled) {
                aiMockEnabled=saved.aiMockEnabled;
                if(activePlugin!=null && !"translate".equals(activePlugin)) invalidatePlugin();
                render();
            }
            return;
        }
        if(!KeyboardSettings.KEY_LEARNING.equals(key) || saved.learning==learningEnabled) return;
        learningEnabled=saved.learning;
        if(!ready || !ownsTarget() || privateField) return;
        final String selected=effectiveSchema();
        // Serialize policy changes before subsequent keys. Existing confirmed blocks stay intact;
        // unfinished code settles exactly like a schema switch, without selecting/learning a word.
        dispatch(() -> {
            Result settled=literal("");
            if(session!=0 && !engine.selectSchema(session,selected)) throw new IllegalStateException("Cannot change learning mode");
            return settled;
        },true);
    }
    private void endTarget() {
        deferredSettingsPair=null;
        cancelPlugin(); pluginSession.clear();
        // Clear the old composition before revoking its connection, never through the new target.
        if(target!=null && target==getCurrentInputConnection() && hostComposing) { target.setComposingText("",1); target.finishComposingText(); }
        cancelChord(); appearanceOpen=false; pluginSettingsOpen=false; activePlugin=null; spellingOpen=false; punctuationOpen=false;
        hostPreedit=""; target=null; hostComposing=false; composingStart=-1; selection=-1; selectionStart=-1;
        epoch.revoke(); pending=0; expectedSelections.clear(); snapshot=RimeEngine.Snapshot.EMPTY; retained=""; retainedResults.clear();
        buffer.finishTarget(); if(metrics!=null) { metrics.setText(""); metrics.setContentDescription(null); } if(bufferRail!=null) bufferRail.clearProjection(); if(pluginOutput!=null) pluginOutput.clearProjection(); resetEngine(); render();
    }
    static boolean isPassword(EditorInfo info) {
        int kind=info.inputType&InputType.TYPE_MASK_CLASS, variation=info.inputType&InputType.TYPE_MASK_VARIATION;
        return kind==InputType.TYPE_CLASS_NUMBER && variation==InputType.TYPE_NUMBER_VARIATION_PASSWORD
                || kind==InputType.TYPE_CLASS_TEXT && (variation==InputType.TYPE_TEXT_VARIATION_PASSWORD
                || variation==InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD || variation==InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD);
    }
    static boolean allowsBuffer(EditorInfo info) {
        return (info.inputType&InputType.TYPE_MASK_CLASS)==InputType.TYPE_CLASS_TEXT && !isPassword(info)
                && (info.imeOptions&EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING)==0;
    }
    private boolean ownsTarget() { return !destroyed && target!=null && target==getCurrentInputConnection(); }

    private interface Operation { Result run(); }
    private static final class Result {
        final RimeEngine.Snapshot state;
        final String text;
        final boolean block;
        final int action; // 0 text/snapshot, 1 host delete, 2 host Return
        Result(RimeEngine.Snapshot state,String text,boolean block,int action) { this.state=state; this.text=text; this.block=block; this.action=action; }
        static Result state(RimeEngine.Snapshot state) { return new Result(state,state.commit,true,0); }
    }
    private void dispatch(Operation operation) {
        dispatch(operation,false);
    }
    private void dispatch(Operation operation,boolean policyChange) {
        if(!ownsTarget()) { endTarget(); return; }
        if(!policyChange && !retained.isEmpty()) { notice(R.string.delivery_pending); return; }
        InputEpoch.Ticket ticket=epoch.issue(); InputConnection connection=target;
        pending++; render();
        EngineWorker.QUEUE.execute(() -> {
            // Revocation also cancels queued engine work, before it could learn an old selection.
            if(!epoch.current(ticket)) return;
            Result result;
            try { result=operation.run(); }
            catch(RuntimeException error) {
                android.util.Log.e("RIMES","Engine operation failed",error);
                main.post(() -> { if(epoch.current(ticket)) { pending--; engineFailure(); } }); return;
            }
            main.post(() -> {
                if(!epoch.accept(ticket) || connection!=target || !ownsTarget()) return;
                pending--;
                if(!retainedResults.isEmpty() || !applyResult(result)) {
                    retainedResults.add(result); retained="pending"; notice(buffer.isEnabled()?R.string.buffer_limit:R.string.delivery_pending);
                }
                render();
            });
        });
    }
    private boolean applyResult(Result result) {
        if(buffer.isEnabled() && (!result.text.isEmpty() || result.state.composing() && !snapshot.composing())) invalidatePlugin();
        if(!result.text.isEmpty() && !deliver(result.text,result.block)) return false;
        snapshot=result.state;
        if(result.action==1) deleteHostOrBuffer();
        if(result.action==2) returnHostOrBuffer();
        updateComposition(); return true;
    }
    private RimeEngine.Snapshot state() { return session==0 ? RimeEngine.Snapshot.EMPTY : engine.snapshot(session); }
    private Result literal(String text) {
        RimeEngine.Snapshot before=state();
        if(before.composing()) engine.clearComposition(session);
        return new Result(RimeEngine.Snapshot.EMPTY,before.raw+text,false,0);
    }
    private void type(String text) {
        if(!ownsTarget()) return;
        invalidatePlugin();
        if(!ready) {
            if(!retained.isEmpty()) { notice(R.string.delivery_pending); return; }
            Result result=new Result(RimeEngine.Snapshot.EMPTY,text,false,0);
            if(!applyResult(result)) { retainedResults.add(result); retained="pending"; notice(buffer.isEnabled()?R.string.buffer_limit:R.string.delivery_pending); }
            render(); return;
        }
        final boolean chinese=!directOnly && !english && !numeric && !emoji;
        dispatch(() -> {
            if(!chinese || session==0 || text.codePointAt(0)>127 || Character.isUpperCase(text.codePointAt(0))) return literal(text);
            RimeEngine.Snapshot before=state();
            if(before.raw.length()>=128 && !" ".equals(text)) return Result.state(before);
            if(" ".equals(text) && before.composing() && !before.candidates.isEmpty())
                return Result.state(engine.selectCandidate(session,before.pageStart));
            RimeEngine.Snapshot after=engine.processKey(session,text.codePointAt(0));
            if(!after.handled && after.commit.isEmpty()) return new Result(after,text,false,0);
            return Result.state(after);
        });
    }
    private boolean deliver(String text,boolean block) {
        if(!ownsTarget()) return false;
        if(buffer.isEnabled()) return block ? buffer.appendCommittedBlock(text) : buffer.appendLiteral(text);
        int start=hostComposing ? composingStart : Math.min(selectionStart,selection);
        expect(start<0 ? -1 : start+text.length());
        boolean accepted=target.commitText(text,1);
        if(accepted) { hostComposing=false; composingStart=-1; }
        return accepted;
    }
    private void updateComposition() {
        if(!ownsTarget() || buffer.isEnabled() || directOnly) return;
        if(snapshot.composing()) {
            if(hostComposing && hostPreedit.equals(snapshot.preedit)) return;
            if(!hostComposing) composingStart=Math.min(selectionStart,selection);
            expect(composingStart<0 ? -1 : composingStart+snapshot.preedit.length());
            hostComposing=target.setComposingText(snapshot.preedit,1);
            hostPreedit=hostComposing?snapshot.preedit:"";
        } else if(hostComposing && retained.isEmpty()) {
            expect(composingStart); target.setComposingText("",1); target.finishComposingText();
            hostComposing=false; composingStart=-1;
        }
    }
    private void expect(int end) { if(end>=0) { expectedSelections.add(end); selection=end; selectionStart=end; while(expectedSelections.size()>64) expectedSelections.remove(); } }
    @Override public void onUpdateSelection(int oldStart,int oldEnd,int newStart,int newEnd,int candidatesStart,int candidatesEnd) {
        super.onUpdateSelection(oldStart,oldEnd,newStart,newEnd,candidatesStart,candidatesEnd);
        if(target==null) return;
        if(newStart==newEnd && expectedSelections.contains(newEnd)) {
            while(!expectedSelections.isEmpty() && expectedSelections.remove()!=newEnd) { /* retire coalesced updates */ }
            return;
        }
        if(newStart==oldStart && newEnd==oldEnd) return;
        if(hostComposing && newStart==newEnd && newEnd==candidatesEnd) return;
        // A host/user selection change revokes pending work, including keys still in the worker queue.
        cancelPlugin(); pluginSession.clear();
        cancelChord(); epoch.revoke(); pending=0; expectedSelections.clear(); snapshot=RimeEngine.Snapshot.EMPTY; retained=""; retainedResults.clear();
        if(hostComposing) { target.setComposingText("",1); target.finishComposingText(); }
        hostComposing=false; composingStart=-1; selection=newEnd; selectionStart=newStart;
        activePlugin=null; pluginSettingsOpen=false; buffer.beginTarget(buffer.isPermitted()); if(bufferRail!=null) bufferRail.clearProjection(); if(pluginOutput!=null) pluginOutput.clearProjection(); resetEngine(); render();
    }
    private void insert(boolean all) {
        if(chords!=null && chords.isChordActive()) return;
        if(pending!=0 || snapshot.composing()) return;
        insertNow(all);
        retryRetained(); render();
    }
    private void insertNow(boolean all) {
        // Plugin output is one complete block, tied to the exact captured source and target.
        if(activePlugin!=null) { insertPluginResult(); return; }
        BufferSession.Delivery delivery=buffer.prepare(all);
        InputConnection connection=target;
        if(!ownsTarget() || !buffer.isCurrent(delivery)) return;
        int end=selection<0 ? -1 : selection+delivery.text.length();
        if(connection.commitText(delivery.text,1) && connection==target && ownsTarget()) { expect(end); buffer.acknowledge(delivery); }
        render();
    }
    private void retryRetained() {
        while(!retainedResults.isEmpty()) {
            Result result=retainedResults.peek();
            if(!applyResult(result)) break;
            retainedResults.remove();
        }
        retained=retainedResults.isEmpty()?"":"pending";
        if(retained.isEmpty()) { updateComposition(); if(deferredSettingsPair!=null) applySettingsPair(deferredSettingsPair); }
        render();
    }
    private void delete() {
        invalidatePlugin();
        if(!retained.isEmpty()) { if(buffer.isEnabled()) { buffer.deleteLastBlock(); retryRetained(); } return; }
        if(!ready) { deleteHostOrBuffer(); render(); return; }
        final boolean nine=nineKeyVisible();
        dispatch(() -> state().composing() ? (nine?replaceNineKey(NineKeyPinyin.backspace(state().raw)):Result.state(engine.processKey(session,0xff08)))
                : new Result(RimeEngine.Snapshot.EMPTY,"",false,1));
    }
    private void deleteHostOrBuffer() {
        if(!ownsTarget()) return;
        if(buffer.isEnabled()) buffer.deleteLastBlock();
        else {
            CharSequence selected=target.getSelectedText(0);
            if(selected!=null && selected.length()>0) { expect(Math.min(selectionStart,selection)); target.commitText("",1); }
            else {
                CharSequence before=target.getTextBeforeCursor(2,0);
                int units=before!=null && before.length()>0 ? Character.charCount(Character.codePointBefore(before,before.length())) : 1;
                expect(selection>0 ? Math.max(0,selection-units) : 0); target.deleteSurroundingTextInCodePoints(1,0);
            }
        }
    }
    private void enter() {
        if(!ready) { returnHostOrBuffer(); return; }
        dispatch(() -> state().composing() ? literal("") : new Result(RimeEngine.Snapshot.EMPTY,"",false,2));
    }
    private void returnHostOrBuffer() {
        if(!ownsTarget()) return;
        if(buffer.isEnabled()) { if(activePlugin!=null) { if(pluginSession.snapshot(buffer).status==PluginSession.Status.READY) insertPluginResult(); else runPlugin(); } else insertNow(false); }
        else if(!sendDefaultEditorAction(true)) deliver("\n",false);
    }
    private void settleAndSwitch(Runnable change) {
        cancelChord();
        if(!retained.isEmpty()) return;
        if(!ready) { change.run(); render(); return; }
        // Route settlement before applying the new mode; subsequent keys queue after it.
        dispatch(() -> literal(""));
        change.run();
        final String selected=effectiveSchema();
        EngineWorker.QUEUE.execute(() -> { if(session!=0) engine.selectSchema(session,selected); });
        render();
    }
    private void select(int index) {
        if(chords!=null && chords.isChordActive()) return;
        if(pending!=0 || !ready || index>=snapshot.candidates.size()) return;
        final int absolute=snapshot.pageStart+index;
        dispatch(() -> Result.state(engine.selectCandidate(session,absolute)));
    }
    private void page(boolean forward) {
        if(pending==0 && snapshot.composing()) dispatch(() -> Result.state(engine.processKey(session,forward?0xff56:0xff55)));
    }
    private void notice(int message) { Toast.makeText(this,message,Toast.LENGTH_SHORT).show(); }

    private Result replaceNineKey(String raw) {
        engine.clearComposition(session);
        RimeEngine.Snapshot after=RimeEngine.Snapshot.EMPTY;
        for(int key:raw.codePoints().toArray()) after=engine.processKey(session,key);
        return Result.state(after);
    }
    private void chooseSpelling(int index) {
        if(pending!=0 || index>=spellingChoices.size()) return;
        String raw=spellings.select(spellingChoices.get(index),snapshot.raw);
        if(raw==null) return;
        spellingOpen=false;
        dispatch(() -> replaceNineKey(raw));
    }
    private void chooseLayout(String selected) {
        if(selected.equals(layout) && (!selected.equals("nineKey") || schema.equals("rimes_pinyin"))) return;
        settleAndSwitch(() -> {
            changeSettingsPair(() -> settings.setLayout(selected)); numeric=false; symbols=false; emoji=false; uppercase=false; spellingOpen=false;
            if(selected.equals("nineKey")) english=false;
            if(chordLayout()) english=false;
        });
    }
    private void typeChord(String code) {
        if(code.isEmpty() || !ownsTarget() || !ready) return;
        invalidatePlugin();
        final boolean chinese=!english && !directOnly && !uppercase;
        final String literalCode=uppercase?code.toUpperCase(Locale.ROOT):code;
        dispatch(() -> {
            if(!chinese) return literal(literalCode);
            RimeEngine.Snapshot after=state(); StringBuilder committed=new StringBuilder();
            if(after.raw.length()+code.length()>128) return Result.state(after);
            for(int key:code.codePoints().toArray()) {
                after=engine.processKey(session,key); committed.append(after.commit);
                if(!after.handled && after.commit.isEmpty()) committed.appendCodePoint(key);
            }
            return new Result(after,committed.toString(),true,0);
        });
    }
    private void toggleLanguage() {
        settleAndSwitch(() -> { english=!english; uppercase=false; spellingOpen=false; punctuationOpen=false; });
    }
    private void toggleNumbers() {
        settleAndSwitch(() -> { numeric=!numeric; symbols=false; emoji=false; spellingOpen=false; punctuationOpen=false; });
    }
    private KeyboardLayout.Mode visibleMode() {
        return emoji?KeyboardLayout.Mode.EMOJI:numeric?(symbols?KeyboardLayout.Mode.SYMBOLS:KeyboardLayout.Mode.NUMERIC)
                :nineKeyVisible()?KeyboardLayout.Mode.NINE_KEY:KeyboardLayout.Mode.QWERTY;
    }
    private void toggleAppearance() {
        cancelChord();
        pluginSettingsOpen=false; appearanceOpen=!appearanceOpen;
        if(appearanceOpen) appearancePanel.scrollTo(0,0);
        render();
    }
    private final KeyboardSurface.Handler keyHandler=new KeyboardSurface.Handler() {
        @Override public String label(KeyboardLayout.Key key) {
            switch(key.action) {
                case TEXT:
                    if(nineKeyVisible()) return new String[]{"ABC","DEF","GHI","JKL","MNO","PQRS","TUV","WXYZ"}[Integer.parseInt(key.text)-2];
                    return !numeric && !emoji?key.text.toUpperCase(Locale.ROOT):key.text;
                case SHIFT: return uppercase?"⇪":"⇧";
                case DELETE: return "⌫";
                case RETURN: return returnLabel();
                case NUMBERS: return numeric || emoji?(nineKeyEngine() && !english && !directOnly?"拼音":"ABC"):"123";
                case SYMBOLS: return numeric && symbols?"123":"#+=";
                case LANGUAGE: return english || directOnly?"英":"中";
                case EMOJI: return emoji?"ABC":"☺";
                case SPACE: return english || directOnly?"space":"空格";
                case SPELLING: return "选拼音";
                case SEPARATOR: return "分隔";
                case PUNCTUATION: return "，。?!";
                default: throw new IllegalStateException();
            }
        }
        @Override public String description(KeyboardLayout.Key key) {
            switch(key.action) {
                case TEXT: return nineKeyVisible()?"九键 "+key.text+" "+label(key):!uppercase && !numeric && !emoji?key.text:label(key);
                case SHIFT: return "Shift";
                case DELETE: return getString(R.string.backspace);
                case RETURN: return getString(R.string.enter);
                case NUMBERS: return "数字与字母";
                case SYMBOLS: return "符号页";
                case LANGUAGE: return "中英切换";
                case EMOJI: return "表情";
                case SPACE: return getString(R.string.space);
                case SPELLING: return "选拼音";
                case SEPARATOR: return "分隔音节";
                case PUNCTUATION: return "中文标点";
                default: throw new IllegalStateException();
            }
        }
        @Override public boolean enabled(KeyboardLayout.Key key) {
            if(key.action==KeyboardLayout.Action.LANGUAGE) return !directOnly;
            if(key.action==KeyboardLayout.Action.SPELLING) return pending==0 && !spellingChoices.isEmpty();
            if(key.action==KeyboardLayout.Action.SEPARATOR) return pending==0 && snapshot.composing() && !snapshot.raw.endsWith("'");
            return true;
        }
        @Override public boolean selected(KeyboardLayout.Key key) {
            return key.action==KeyboardLayout.Action.SHIFT && uppercase || key.action==KeyboardLayout.Action.SPELLING && spellingOpen
                    || key.action==KeyboardLayout.Action.RETURN && returnSelected();
        }
        @Override public void press(KeyboardLayout.Key key) {
            switch(key.action) {
                case TEXT:
                    String text=uppercase && !numeric && !emoji?key.text.toUpperCase(Locale.ROOT):key.text;
                    if(numeric && !english && !directOnly) for(int i=0;i<MARKS.length;i++) if(text.equals(MARKS[i])) { text=MARK_LABELS[i]; break; }
                    type(text); break;
                case SHIFT: settleAndSwitch(() -> uppercase=!uppercase); break;
                case DELETE: delete(); break;
                case RETURN: enter(); break;
                case NUMBERS:
                    if(emoji) settleAndSwitch(() -> { emoji=false; numeric=false; }); else toggleNumbers(); break;
                case SYMBOLS: settleAndSwitch(() -> { symbols=!symbols || !numeric; numeric=true; emoji=false; }); break;
                case LANGUAGE: toggleLanguage(); break;
                case EMOJI: settleAndSwitch(() -> { emoji=!emoji; numeric=false; }); break;
                case SPACE: type(" "); break;
                case SPELLING: spellingOpen=!spellingOpen; punctuationOpen=false; spellingPage=0; render(); break;
                case SEPARATOR: type("'"); break;
                case PUNCTUATION: punctuationOpen=!punctuationOpen; spellingOpen=false; render(); break;
                default: throw new IllegalStateException();
            }
        }
    };
    private boolean returnSelected() {
        if(snapshot.composing() || pending!=0) return false;
        if(buffer.isEnabled()) return activePlugin==null?buffer.blockCount()>0:pluginSession.snapshot(buffer).status==PluginSession.Status.READY;
        EditorInfo info=getCurrentInputEditorInfo();
        if(info==null || (info.imeOptions&EditorInfo.IME_FLAG_NO_ENTER_ACTION)!=0) return false;
        switch(info.imeOptions&EditorInfo.IME_MASK_ACTION) {
            case EditorInfo.IME_ACTION_SEARCH:
            case EditorInfo.IME_ACTION_GO:
            case EditorInfo.IME_ACTION_SEND:
            case EditorInfo.IME_ACTION_NEXT:
            case EditorInfo.IME_ACTION_DONE: return true;
            default: return false;
        }
    }
    private String returnLabel() {
        if(snapshot.composing()) return "原码";
        if(buffer.isEnabled()) return activePlugin==null?"插入":pluginSession.snapshot(buffer).status==PluginSession.Status.READY?"发送":pluginSession.snapshot(buffer).status==PluginSession.Status.RUNNING?"处理中":"执行";
        EditorInfo info=getCurrentInputEditorInfo();
        if(info==null || (info.imeOptions&EditorInfo.IME_FLAG_NO_ENTER_ACTION)!=0) return "换行";
        switch(info.imeOptions&EditorInfo.IME_MASK_ACTION) {
            case EditorInfo.IME_ACTION_SEARCH: return "搜索";
            case EditorInfo.IME_ACTION_GO: return "前往";
            case EditorInfo.IME_ACTION_SEND: return "发送";
            case EditorInfo.IME_ACTION_NEXT: return "下一项";
            case EditorInfo.IME_ACTION_DONE: return "完成";
            default: return "换行";
        }
    }
    @Override public View onCreateInputView() {
        keyboard=new KeyboardRoot(this); keyboard.setOrientation(LinearLayout.VERTICAL);
        if(Build.VERSION.SDK_INT>=29) keyboard.setForceDarkAllowed(false);
        keyboard.setLayoutDirection(View.LAYOUT_DIRECTION_LTR); chromeButtons.clear(); chordControls.clear();
        keyboard.setPadding(dp(5),dp(5),dp(5),dp(5));
        keyboard.addOnLayoutChangeListener((v,l,t,r,b,ol,ot,or,ob) -> { if(r-l!=or-ol) render(); });
        keyboard.setOnApplyWindowInsetsListener((view,insets) -> {
            int left,right,bottom;
            if(Build.VERSION.SDK_INT>=30) {
                android.graphics.Insets safe=insets.getInsets(WindowInsets.Type.systemBars()|WindowInsets.Type.displayCutout());
                left=safe.left; right=safe.right; bottom=safe.bottom;
            } else { left=insets.getSystemWindowInsetLeft(); right=insets.getSystemWindowInsetRight(); bottom=insets.getSystemWindowInsetBottom(); }
            view.setPadding(dp(5)+left,dp(5),dp(5)+right,dp(5)+bottom); return insets;
        });
        preedit=new TextView(this); preedit.setSingleLine(true); preedit.setTextSize(13); preedit.setGravity(Gravity.CENTER_VERTICAL);
        preedit.setPadding(dp(8),0,dp(8),0); keyboard.addView(preedit,new LinearLayout.LayoutParams(-1,dp(28)));
        bufferRow=new LinearLayout(this); bufferRow.setOrientation(LinearLayout.VERTICAL);
        LinearLayout.LayoutParams bufferParams=new LinearLayout.LayoutParams(-1,dp(landscape()?60:76)); bufferParams.bottomMargin=dp(4); keyboard.addView(bufferRow,bufferParams);
        int railHeight=landscape()?28:36;
        LinearLayout input=row(bufferRow,railHeight); bufferTop=input;
        themeButton=button(input,theme.glyph,this::toggleAppearance,0); fixedWidth(themeButton,32); gapRight(themeButton,4);
        themeButton.setContentDescription("布局与配色"); themeButton.icon(KeyboardIcon.APPEARANCE);
        bufferRail=new BufferRail(this); input.addView(bufferRail,new LinearLayout.LayoutParams(0,-1,1));
        insertNext=button(input,"↑",() -> insert(false),0); fixedWidth(insertNext,32); gapLeft(insertNext,4);
        ((KeyButton)insertNext).icon(KeyboardIcon.PAPER_PLANE); ((KeyButton)insertNext).appearance(false,false,true); insertNext.setContentDescription(getString(R.string.insert_next)); insertNext.setOnLongClickListener(v -> { insert(true); return true; });
        LinearLayout details=new LinearLayout(this); bufferBottom=details; bufferRow.addView(details,new LinearLayout.LayoutParams(-1,dp(railHeight)));
        bufferSettings=button(details,"设置",() -> openPluginSettings(activePlugin),0); fixedWidth(bufferSettings,32); gapRight(bufferSettings,4); bufferSettings.icon(KeyboardIcon.SLIDERS); bufferSettings.setContentDescription("Buffer 设置");
        metrics=new TextView(this); metrics.setGravity(Gravity.CENTER); metrics.setTextSize(landscape()?14:16);
        metrics.setTypeface(android.graphics.Typeface.create("sans-serif-medium",android.graphics.Typeface.NORMAL)); details.addView(metrics,new LinearLayout.LayoutParams(0,-1,1));
        pluginRunButton=button(details,"执行",this::runOrCancelPlugin,0); fixedWidth(pluginRunButton,32); gapLeft(pluginRunButton,4); pluginRunButton.icon(KeyboardIcon.PLAY);
        pluginButton=button(details,"插件",() -> openPluginSettings(activePlugin),0); fixedWidth(pluginButton,32); gapLeft(pluginButton,4); pluginButton.icon(KeyboardIcon.GRID_9); pluginButton.setContentDescription("Buffer 插件设置");
        candidateRow=row(keyboard,32);
        layoutButton=button(candidateRow,"⚙",this::toggleAppearance,0); fixedWidth(layoutButton,32); gapRight(layoutButton,4); layoutButton.setContentDescription("键位布局"); layoutButton.icon(KeyboardIcon.SETTINGS);
        previous=button(candidateRow,"‹",() -> candidatePage(false),0); fixedWidth(previous,32); ((KeyButton)previous).plain(true); previous.setContentDescription("上一页候选"); ((KeyButton)previous).icon(KeyboardIcon.CHEVRON_LEFT,16);
        candidateScroll=new HorizontalScrollView(this); candidateScroll.setFillViewport(false); candidateScroll.setHorizontalScrollBarEnabled(false);
        LinearLayout strip=new LinearLayout(this); candidateScroll.addView(strip,new HorizontalScrollView.LayoutParams(-2,-1));
        FrameLayout center=new FrameLayout(this); candidateRow.addView(center,new LinearLayout.LayoutParams(0,-1,1));
        center.addView(candidateScroll,new FrameLayout.LayoutParams(-1,-1));
        pluginShortcuts=new PluginShortcutBar(this,theme,new PluginShortcutBar.Listener() {
            public void onPluginTap(String id) { selectPlugin(id); }
            public void onPluginLongPress(String id) { openPluginSettings(id); }
        }); center.addView(pluginShortcuts,new FrameLayout.LayoutParams(-1,-1)); chordReadout=new ChordPreview(this); center.addView(chordReadout,new FrameLayout.LayoutParams(-1,-1)); candidates.clear();
        for(int i=0;i<9;i++) {
            final int index=i; KeyButton candidate=button(strip,"",() -> candidateTapped(index),0);
            candidate.setLayoutParams(new LinearLayout.LayoutParams(-2,-1)); candidate.fontStyle(false,20,false); candidate.plain(true);
            candidate.setMinWidth(dp(32)); candidate.setMinimumWidth(dp(32)); candidate.setPadding(dp(6),0,dp(6),0);
            gapRight(candidate,4);
            candidate.setAutoSizeTextTypeWithDefaults(TextView.AUTO_SIZE_TEXT_TYPE_NONE); candidate.setTextSize(20); candidates.add(candidate);
        }
        next=button(candidateRow,"›",() -> candidatePage(true),0); fixedWidth(next,32); ((KeyButton)next).plain(true); next.setContentDescription("下一页候选"); ((KeyButton)next).icon(KeyboardIcon.CHEVRON_RIGHT,16);
        bufferButton=button(candidateRow,"▤",() -> { if(pending==0 && !snapshot.composing() && retained.isEmpty()) { cancelChord(); buffer.setEnabled(!buffer.isEnabled()); if(!buffer.isEnabled()) { cancelPlugin(); pluginSession.clear(); activePlugin=null; pluginSettingsOpen=false; } render(); } },0);
        fixedWidth(bufferButton,32); gapLeft(bufferButton,4); ((KeyButton)bufferButton).appearance(false,false,true); ((KeyButton)bufferButton).icon(KeyboardIcon.STACK_LAYERS);
        spellingRow=row(keyboard,34); spellingButtons.clear();
        for(int i=0;i<9;i++) { final int index=i; KeyButton spelling=button(spellingRow,"",() -> chooseSpelling(spellingPage+index),1); spellingButtons.add(spelling); }
        retryButton=new KeyButton(this); chromeButtons.add((KeyButton)retryButton); retryButton.setText(R.string.retry);
        retryButton.setOnClickListener(v -> { if(failed) initialize(); else retryRetained(); }); keyboard.addView(retryButton,new LinearLayout.LayoutParams(-1,dp(44)));
        surfaceContainer=new FrameLayout(this);
        keys=new KeyboardSurface(this,keyHandler); surfaceContainer.addView(keys,new FrameLayout.LayoutParams(-1,-1));
        chords=new ChordSurface(this,new ChordSurface.Handler() {
            public void onChord(String code) { chordPreview=""; typeChord(code); }
            public void onKey(String text) { type(uppercase?text.toUpperCase(Locale.ROOT):text); }
            public void onPreview(ChordGesture.Preview preview) { if(preview!=null && heldPreview==null) invalidatePlugin(); heldPreview=preview; String value=preview==null?"":preview.combined!=null?preview.combined:(preview.left==null?"":preview.left.keys)+(preview.right==null?"":preview.right.keys);
                chordPreview=value; render(); }
            public void onControl(ChordLayout.Action action) { if(action==ChordLayout.Action.DELETE) delete(); else { settleAndSwitch(() -> { emoji=true; numeric=false; }); } }
            public String label(ChordLayout.Action action) { return action==ChordLayout.Action.DELETE?"⌫":"☺"; }
            public String description(ChordLayout.Action action) { return action==ChordLayout.Action.DELETE?getString(R.string.backspace):"表情"; }
        }); surfaceContainer.addView(chords,new FrameLayout.LayoutParams(-1,-1));
        appearancePanel=new KeyboardAppearancePanel(this,this::chooseLayout,settings::setTheme);
        appearancePanel.schemes(schema,this::chooseSchema);
        appearancePanel.action("全部插入",getString(R.string.insert_all),() -> insert(true));
        appearancePanel.action("清空 Buffer",getString(R.string.clear),() -> { if(pending==0 && !snapshot.composing()) { invalidatePlugin(); buffer.clear(); retryRetained(); render(); } });
        appearancePanel.action("系统键盘",getString(R.string.switch_keyboard),() -> { endTarget(); getSystemService(InputMethodManager.class).showInputMethodPicker(); });
        surfaceContainer.addView(appearancePanel,new FrameLayout.LayoutParams(-1,-1));
        pluginPanel=new BufferPluginPanel(this,new BufferPluginPanel.Listener() {
            public void onPlugin(String id) { openPluginSettings(id); }
            public void onDefaultBuffer() { cancelPlugin(); pluginSession.clear(); activePlugin=null; pluginSettingsOpen=false; render(); }
            public void onClose() { pluginSettingsOpen=false; render(); }
            public void onDirection(String direction) { settings.setTranslationDirection(direction); render(); }
        }); surfaceContainer.addView(pluginPanel,new FrameLayout.LayoutParams(-1,-1));
        pluginOutput=new BufferRail(this);
        renderedPluginMode=false;
        keyboard.addView(surfaceContainer,new LinearLayout.LayoutParams(-1,dp(KeyboardLayout.height(landscape()))));
        chordFooter=row(keyboard,landscape()?34:40); ((LinearLayout.LayoutParams)chordFooter.getLayoutParams()).bottomMargin=0;
        KeyboardLayout.Action[] actions={KeyboardLayout.Action.NUMBERS,KeyboardLayout.Action.SHIFT,KeyboardLayout.Action.SPACE,KeyboardLayout.Action.LANGUAGE,KeyboardLayout.Action.RETURN};
        for(KeyboardLayout.Action action:actions) {
            KeyButton button=button(chordFooter,"",() -> chordControl(action),action==KeyboardLayout.Action.SPACE?3.5f:1);
            button.classic(true); button.fontStyle(false,action==KeyboardLayout.Action.SHIFT?17:14,true); button.appearance(action!=KeyboardLayout.Action.SPACE,true,action==KeyboardLayout.Action.RETURN); if(!chordControls.isEmpty()) gapLeft(button,2); chordControls.add(button);
        }
        rebuildKeys(); render(); return keyboard;
    }
    private static String pluginName(String id) {
        if(id==null) return "";
        switch(id) { case "translate":return "翻译";case "ask":return "快问";case "polish":return "润色";case "poem":return "作诗";case "art":return "画画";default:throw new IllegalArgumentException("Unknown plugin"); }
    }
    private static String pluginPlaceholder(String id) {
        switch(id) { case "translate":return "输入要翻译的文字";case "ask":return "问点什么";case "polish":return "写下要润色的文字";case "poem":return "写下主题或要藏的字";case "art":return "写下要画的东西";default:throw new IllegalArgumentException("Unknown plugin"); }
    }
    private boolean canSelectPlugin() {
        return ownsTarget() && buffer.isPermitted() && pending==0 && !snapshot.composing() && retained.isEmpty() && !chords.isChordActive();
    }
    private void selectPlugin(String id) {
        pluginName(id);
        if(!canSelectPlugin() || !officialPlugins.enabled(id)) return;
        cancelChord(); cancelPlugin(); if(!buffer.isEnabled()) buffer.setEnabled(true); activePlugin=id.equals(activePlugin)?null:id;
        pluginSession.select(activePlugin);
        punctuationOpen=false; appearanceOpen=false; pluginSettingsOpen=false; render();
    }
    private void openPluginSettings(String id) {
        if(!canSelectPlugin()) return;
        cancelChord(); if(!buffer.isEnabled()) buffer.setEnabled(true);
        if(!java.util.Objects.equals(activePlugin,id)) cancelPlugin(); activePlugin=id; pluginSession.select(id);
        appearanceOpen=false; pluginSettingsOpen=true; render();
    }
    private void cancelPlugin() {
        if(pluginJob!=null) { pluginJob.cancel(); pluginJob=null; }
    }
    private void invalidatePlugin() { cancelPlugin(); pluginSession.invalidate(); }
    private String pluginStatus(PluginSession.Snapshot state) {
        if(cometProfile.remote(activePlugin)) {
            if(state.status==PluginSession.Status.ERROR) return state.message;
            return state.status==PluginSession.Status.RUNNING?"AI 生成中… · 点停止可取消":"CometAPI · "+cometProfile.model+" · 点执行";
        }
        if(state.status==PluginSession.Status.RUNNING) return activePlugin.equals("translate")?"本机词典查译中…":"Mock 生成中…";
        if(state.status==PluginSession.Status.ERROR) return state.message;
        if(!"translate".equals(activePlugin) && !aiMockEnabled) return "AI Mock 已关闭 · 在 RIMES 主应用中启用";
        return activePlugin.equals("translate")?"本机中英词典 · 点执行查译":"OpenAI 格式 Mock · 点执行生成";
    }
    private void runOrCancelPlugin() {
        if(pluginSession.snapshot(buffer).status==PluginSession.Status.RUNNING) { invalidatePlugin(); render(); }
        else runPlugin();
    }
    private void runPlugin() {
        if(activePlugin==null || !canSelectPlugin() || !buffer.isEnabled() || !pluginAllowed()) return;
        final String authorization=officialPlugins.grant(activePlugin);
        if(authorization==null) return;
        pluginResultAuthorization=authorization;
        PluginSession.Request request=pluginSession.start(buffer);
        if(request==null) return;
        InputEpoch.Ticket ticket=epoch.issue(); InputConnection connection=target;
        pluginSettingsOpen=false; render();
        pluginJob=pluginExecutor.run(request.plugin,request.source.text,translationDirection,cometProfile,new BufferPluginExecutor.Listener() {
            public void onUpdate(String text,boolean complete) { main.post(() -> {
                if(!epoch.current(ticket) || connection!=target || !ownsTarget() || privateField || !pluginAllowed()
                        || !authorization.equals(officialPlugins.grant(request.plugin))) return;
                if(pluginSession.update(request,buffer,text,complete)) { if(pluginSession.snapshot(buffer).status==PluginSession.Status.ERROR) cancelPlugin(); else if(complete) pluginJob=null; render(); }
            }); }
            public void onFailure(String message) { main.post(() -> {
                if(!epoch.current(ticket) || connection!=target || !ownsTarget() || privateField || !pluginAllowed()
                        || !authorization.equals(officialPlugins.grant(request.plugin))) return;
                if(pluginSession.fail(request,buffer,message)) { pluginJob=null; render(); }
            }); }
        });
    }
    private boolean pluginAllowed() { return officialPlugins.enabled(activePlugin) && ("translate".equals(activePlugin) || cometProfile.enabled || aiMockEnabled); }
    private void insertPluginResult() {
        if(!canSelectPlugin() || !buffer.isEnabled() || !pluginAllowed()
                || pluginResultAuthorization==null || !pluginResultAuthorization.equals(officialPlugins.grant(activePlugin))) return;
        PluginSession.Delivery delivery=pluginSession.prepare(buffer); InputConnection connection=target;
        if(!ownsTarget() || !pluginSession.isCurrent(delivery,buffer)) return;
        int end=selection<0?-1:Math.min(selectionStart,selection)+delivery.text.length();
        if(connection.commitText(delivery.text,1) && connection==target && ownsTarget()) { expect(end); pluginSession.acknowledge(delivery,buffer); }
        render();
    }
    private void chordControl(KeyboardLayout.Action action) {
        cancelChord();
        switch(action) { case NUMBERS:toggleNumbers();break; case SHIFT:settleAndSwitch(() -> uppercase=!uppercase);break;
            case LANGUAGE:toggleLanguage();break; case SPACE:type(" ");break; case RETURN:enter();break; default:break; }
    }
    private void gapLeft(View view,int gap) { ((LinearLayout.LayoutParams)view.getLayoutParams()).leftMargin=dp(gap); }
    private void gapRight(View view,int gap) { ((LinearLayout.LayoutParams)view.getLayoutParams()).rightMargin=dp(gap); }
    private boolean landscape() { return getResources().getConfiguration().orientation==Configuration.ORIENTATION_LANDSCAPE; }
    private void rebuildKeys() { if(keys!=null) keys.render(visibleMode(),theme); }
    private void candidateTapped(int index) {
        if(!chordPreview.isEmpty()) return;
        if(punctuationOpen) {
            if(index<MARKS.length) { punctuationOpen=false; type(MARKS[index]); }
        } else if(snapshot.composing()) select(index);
    }
    private void candidatePage(boolean forward) {
        if(spellingOpen) { spellingPage=Math.max(0,Math.min(((spellingChoices.size()-1)/9)*9,spellingPage+(forward?9:-9))); render(); }
        else page(forward);
    }
    private void render() {
        if(keyboard==null) return;
        KeyboardTheme.Palette palette=theme.palette(this); keyboard.setBackgroundColor(palette.background);
        for(KeyButton button:chromeButtons) button.theme(theme);
        setText(layoutButton,appearanceOpen?"✓":"⚙"); layoutButton.icon(appearanceOpen?KeyboardIcon.CHECK:KeyboardIcon.SETTINGS);
        layoutButton.setSelected(appearanceOpen);

        bufferButton.setContentDescription(getString(buffer.isEnabled()?R.string.buffer_on:R.string.buffer_off)); bufferButton.setSelected(buffer.isEnabled());
        bufferButton.setEnabled(buffer.isPermitted() && pending==0 && !snapshot.composing() && retained.isEmpty() && !chords.isChordActive());
        String status=failed?getString(R.string.engine_failed):!ready?getString(R.string.engine_loading):"";
        if(!retained.isEmpty()) status=getString(R.string.delivery_pending);
        setText(preedit,status); preedit.setTextColor(palette.accentText); preedit.setVisibility(!directOnly && !status.isEmpty()?View.VISIBLE:View.GONE);
        spellingChoices=nineKeyVisible()?spellings.choices(snapshot.raw):java.util.Collections.emptyList();
        if(spellingChoices.isEmpty()) spellingOpen=false;
        if(spellingPage>=spellingChoices.size()) spellingPage=0;
        candidateRow.setVisibility(View.VISIBLE);
        boolean idle=!snapshot.composing() && snapshot.candidates.isEmpty() && heldPreview==null && chordPreview.isEmpty() && !chords.isChordActive() && !punctuationOpen;
        pluginShortcuts.setVisibility(idle && !privateField && !directOnly?View.VISIBLE:View.GONE);
        pluginShortcuts.render(theme,buffer.isEnabled()?activePlugin:null,canSelectPlugin(),officialPlugins::enabled);
        candidateScroll.setVisibility(heldPreview==null && !idle?View.VISIBLE:View.GONE); chordReadout.setVisibility(heldPreview==null?View.GONE:View.VISIBLE);
        chordReadout.render(heldPreview,theme,landscape());
        boolean marks=punctuationOpen;
        int count=directOnly?0:!chordPreview.isEmpty()?1:marks?MARKS.length:snapshot.candidates.size();
        for(int i=0;i<9;i++) {
            Button item=candidates.get(i); boolean exists=i<count;
            item.setVisibility(exists?View.VISIBLE:View.GONE);
            if(exists) {
                String value=!chordPreview.isEmpty()?chordPreview:marks?(english || numeric || emoji?MARKS[i]:MARK_LABELS[i]):snapshot.candidates.get(i);
                setText(item,value);
                item.setContentDescription(marks?MARKS[i]:"候选"+(i+1)+" "+value);
            }
            item.setEnabled(exists && pending==0 && chordPreview.isEmpty());
        }
        if(renderedPage!=snapshot.pageStart || !renderedRaw.equals(snapshot.raw)) {
            candidateScroll.scrollTo(0,0); renderedPage=snapshot.pageStart; renderedRaw=snapshot.raw;
        }
        previous.setVisibility(idle || marks && !spellingOpen || directOnly || heldPreview!=null || !spellingOpen && snapshot.pageStart==0?View.GONE:View.VISIBLE); next.setVisibility(idle || marks && !spellingOpen || directOnly || heldPreview!=null?View.GONE:View.VISIBLE);
        previous.setEnabled(pending==0 && (spellingOpen?spellingPage>0:snapshot.pageStart>0));
        next.setEnabled(pending==0 && (spellingOpen?spellingPage+9<spellingChoices.size():!snapshot.lastPage));
        bufferRow.setVisibility(buffer.isEnabled()?View.VISIBLE:View.GONE);
        boolean plugin=buffer.isEnabled() && activePlugin!=null;
        if(plugin!=renderedPluginMode) {
            bufferTop.removeView(plugin?bufferRail:pluginOutput); bufferBottom.removeView(plugin?metrics:bufferRail);
            bufferTop.addView(plugin?pluginOutput:bufferRail,1,new LinearLayout.LayoutParams(0,-1,1));
            bufferBottom.addView(plugin?bufferRail:metrics,1,new LinearLayout.LayoutParams(0,-1,1));
            renderedPluginMode=plugin;
        }
        if(buffer.isEnabled()) {
            bufferRail.placeholder(plugin?pluginPlaceholder(activePlugin):"输入内容暂存于此");
            bufferRail.render(buffer.blocks(),snapshot.preedit,theme,landscape());
            String text=buffer.text(); setText(metrics,text.codePointCount(0,text.length())+" 字 · "+buffer.blockCount()+" 块");
            metrics.setContentDescription(null);
            if(plugin) {
                PluginSession.Snapshot state=pluginSession.snapshot(buffer);
                pluginOutput.placeholder(pluginStatus(state));
                pluginOutput.render(state.output.isEmpty()?java.util.Collections.emptyList():java.util.Collections.singletonList(state.output),"",theme,landscape());
                pluginOutput.setContentDescription("插件输出："+pluginName(activePlugin)+" · "+state.status+" · "+(state.output.isEmpty()?pluginStatus(state):state.output));
            }
        }
        metrics.setTextColor(palette.ink);
        if(metrics.getTag()==null || !metrics.getTag().equals(palette.ink)) { android.graphics.drawable.GradientDrawable output=new android.graphics.drawable.GradientDrawable(); output.setColor((palette.ink&0xffffff)|0x10000000); output.setCornerRadius(dp(7)); metrics.setBackground(output); metrics.setTag(palette.ink); }
        spellingRow.setVisibility(spellingOpen?View.VISIBLE:View.GONE);
        for(int i=0;i<9;i++) { KeyButton key=spellingButtons.get(i); boolean exists=spellingPage+i<spellingChoices.size(); key.setVisibility(exists?View.VISIBLE:View.GONE);
            if(exists) { String value=spellingChoices.get(spellingPage+i); setText(key,value); key.setContentDescription("拼音 "+value); } key.setEnabled(exists && pending==0); }
        PluginSession.Status pluginState=pluginSession.snapshot(buffer).status;
        pluginRunButton.setVisibility(plugin?View.VISIBLE:View.GONE); pluginRunButton.setContentDescription(pluginState==PluginSession.Status.RUNNING?"取消执行":"执行"+pluginName(activePlugin));
        pluginRunButton.icon(pluginState==PluginSession.Status.RUNNING?KeyboardIcon.STOP:KeyboardIcon.PLAY);
        pluginRunButton.setEnabled(plugin && pluginAllowed() && pending==0 && !snapshot.composing() && !chords.isChordActive() && buffer.blockCount()>0);
        pluginButton.setSelected(plugin);
        insertNext.setEnabled(pending==0 && !snapshot.composing() && buffer.blockCount()>0 && !chords.isChordActive() && (!plugin || pluginState==PluginSession.Status.READY));
        retryButton.setVisibility(failed || !retained.isEmpty()?View.VISIBLE:View.GONE);
        boolean chord=chordVisible();
        float width=(keyboard.getWidth()>0?keyboard.getWidth():getResources().getDisplayMetrics().widthPixels)-keyboard.getPaddingLeft()-keyboard.getPaddingRight();
        float surfaceHeight=chord?ChordLayout.height(Math.max(1,width/getResources().getDisplayMetrics().density),"splitOrthogonal".equals(layout)):KeyboardLayout.height(landscape());
        boolean panelOpen=appearanceOpen || pluginSettingsOpen;
        if(chord && panelOpen) surfaceHeight+=landscape()?35:41;
        int desiredHeight=Math.round(surfaceHeight*getResources().getDisplayMetrics().density);
        if(surfaceContainer.getLayoutParams().height!=desiredHeight) { surfaceContainer.getLayoutParams().height=desiredHeight; surfaceContainer.requestLayout(); }
        keys.render(visibleMode(),theme); keys.setVisibility(panelOpen || chord?View.GONE:View.VISIBLE);
        chords.render("splitOrthogonal".equals(layout),!english && !uppercase,uppercase,theme); chords.setVisibility(panelOpen || !chord?View.GONE:View.VISIBLE);
        chordFooter.setVisibility(!panelOpen && chord?View.VISIBLE:View.GONE);
        ((LinearLayout.LayoutParams)surfaceContainer.getLayoutParams()).bottomMargin=chord && !panelOpen?dp(1):0;
        String[] footerLabels={"123",uppercase?"⇪":"⇧","空格",english?"EN":"中",returnLabel()};
        String[] footerDescriptions={"数字与字母","Shift",getString(R.string.space),"中英切换",getString(R.string.enter)};
        for(int i=0;i<chordControls.size();i++) {
            KeyButton button=chordControls.get(i); setText(button,footerLabels[i]); button.setContentDescription(footerDescriptions[i]);
            LinearLayout.LayoutParams params=(LinearLayout.LayoutParams)button.getLayoutParams(); int keyWidth=i==2?0:Math.round((width/getResources().getDisplayMetrics().density-10)/7.5f*getResources().getDisplayMetrics().density);
            float weight=i==2?1:0; if(params.width!=keyWidth || params.weight!=weight) { params.width=keyWidth; params.weight=weight; button.requestLayout(); }
            button.setEnabled(!chords.isChordActive());
            button.icon(i==1?(uppercase?KeyboardIcon.SHIFT_FILL:KeyboardIcon.SHIFT):null);
            button.setSelected(i==1 && uppercase || i==3 && english || i==4 && returnSelected());
        }
        insertNext.setSelected(insertNext.isEnabled());
        if(appearanceOpen) appearancePanel.schemes(schema,this::chooseSchema);
        appearancePanel.setVisibility(appearanceOpen?View.VISIBLE:View.GONE);
        if(appearanceOpen) appearancePanel.render(layout,theme);
        pluginPanel.setVisibility(pluginSettingsOpen?View.VISIBLE:View.GONE);
        if(pluginSettingsOpen) pluginPanel.render(theme,activePlugin,translationDirection);
    }
    private static void setText(TextView view,String value) {
        if(!android.text.TextUtils.equals(view.getText(),value)) view.setText(value);
    }
    private LinearLayout row(LinearLayout parent,int height) {
        LinearLayout row=new LinearLayout(this); row.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(-1,dp(height)); params.bottomMargin=dp(4); parent.addView(row,params); return row;
    }
    private KeyButton button(LinearLayout row,String text,Runnable action,float weight) {
        KeyButton button=new KeyButton(this); button.setText(text); button.font(15); button.appearance(false,false,false);
        button.setOnClickListener(v -> action.run()); row.addView(button,new LinearLayout.LayoutParams(0,-1,weight)); chromeButtons.add(button); return button;
    }
    private void fixedWidth(View view,int width) { view.setLayoutParams(new LinearLayout.LayoutParams(dp(width),-1)); }
    private int dp(int value) { return Math.round(value*getResources().getDisplayMetrics().density); }
}
