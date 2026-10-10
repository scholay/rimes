package org.scholay.rimes.android;

import android.app.Activity;
import android.content.Intent;
import android.content.res.Configuration;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.content.res.ColorStateList;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.scholay.rimes.core.ChordProfile;

/** The launcher and Android's IME settings entry share the same native settings home. */
public final class SetupActivity extends Activity {
    private KeyboardSettings settings;
    private OfficialPluginStore officialPlugins;
    private String installingPlugin;
    private LinearLayout content;
    private String page="home", license;
    private String renderedPage;
    private ScrollView currentScroll;
    private final java.util.ArrayList<String> navigation=new java.util.ArrayList<>();
    private final java.util.HashMap<String,Integer> scrollPositions=new java.util.HashMap<>();
    private int background,card,ink,secondary,accent,separator;
    private final ExecutorService documents=Executors.newSingleThreadExecutor();
    private long documentGeneration;
    private boolean destroyed,resumed;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        officialPlugins=new OfficialPluginStore(this);
        settings=new KeyboardSettings(this);
        if(state!=null) { page=state.getString("settings.page","home"); license=state.getString("settings.license");
            java.util.ArrayList<String> saved=state.getStringArrayList("settings.navigation"); if(saved!=null) navigation.addAll(saved); }
        getWindow().setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        if(Build.VERSION.SDK_INT>=33) getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT,this::goBack);
        render();
    }
    @Override protected void onResume() {
        super.onResume();
        // Returning from the system IME picker must not discard a playground draft.
        if(resumed && content!=null && !page.equals("playground")) render();
        resumed=true;
    }
    @Override protected void onSaveInstanceState(Bundle state) {
        super.onSaveInstanceState(state);
        state.putString("settings.page",page); state.putString("settings.license",license);
        state.putStringArrayList("settings.navigation",new java.util.ArrayList<>(navigation));
        // Typing fields deliberately have no saved state or preference entry.
    }
    // API 33+ uses the native dispatcher registered above; retain this hook for API 26–32.
    @android.annotation.SuppressLint("GestureBackNavigation")
    @Override public void onBackPressed() { goBack(); }
    @Override protected void onDestroy() {
        destroyed=true; documentGeneration++; documents.shutdownNow(); super.onDestroy();
    }
    private void goBack() {
        if(page.equals("home")) { finish(); return; }
        String destination=navigation.isEmpty()?"home":navigation.remove(navigation.size()-1);
        show(destination);
    }
    private void navigate(String destination) {
        navigation.add(page); show(destination);
    }
    private void show(String destination) {
        getSystemService(InputMethodManager.class).hideSoftInputFromWindow(getWindow().getDecorView().getWindowToken(),0);
        if(currentScroll!=null) scrollPositions.put(page,currentScroll.getScrollY());
        page=destination; render();
    }
    private String t(String chinese,String english) {
        return getResources().getConfiguration().getLocales().get(0).getLanguage().equals("zh")?chinese:english;
    }
    private int dp(float value) { return Math.round(value*getResources().getDisplayMetrics().density); }
    private LinearLayout column() {
        LinearLayout view=new LinearLayout(this); view.setOrientation(LinearLayout.VERTICAL); return view;
    }
    private GradientDrawable shape(int color,float radius) {
        GradientDrawable value=new GradientDrawable(); value.setColor(color); value.setCornerRadius(dp(radius)); return value;
    }
    private TextView text(String value,float size,int color,boolean bold) {
        TextView view=new TextView(this); view.setText(value); view.setTextSize(size); view.setTextColor(color);
        if(bold) view.setTypeface(Typeface.create("sans-serif",Typeface.BOLD)); return view;
    }
    private void render() {
        documentGeneration++;
        int previousScroll=page.equals(renderedPage) && currentScroll!=null?currentScroll.getScrollY():scrollPositions.getOrDefault(page,0);
        renderedPage=page;
        boolean dark=(getResources().getConfiguration().uiMode&Configuration.UI_MODE_NIGHT_MASK)==Configuration.UI_MODE_NIGHT_YES;
        background=dark?0xFF000000:0xFFF2F2F7; card=dark?0xFF1C1C1E:0xFFFFFFFF;
        ink=dark?0xFFF5F5F7:0xFF111113; secondary=dark?0xFF9C9CA3:0xFF76767D;
        accent=dark?0xFF5AD3CE:0xFF008D89; separator=dark?0xFF38383A:0xFFE5E5EA;
        int systemStyle=dark?0:View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR;
        if(!dark && Build.VERSION.SDK_INT>=27) systemStyle|=View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR;
        getWindow().getDecorView().setSystemUiVisibility(systemStyle);
        content=column(); content.setTag("settings.page."+page);
        content.setPadding(dp(16),dp(8),dp(16),dp(24)); content.setFocusableInTouchMode(true);
        if(!page.equals("home")) {
            LinearLayout back=new LinearLayout(this); back.setOrientation(LinearLayout.HORIZONTAL); back.setGravity(Gravity.CENTER_VERTICAL);
            back.addView(icon(KeyboardIcon.CHEVRON_LEFT,accent,20));
            TextView name=text(titleFor(navigation.isEmpty()?"home":navigation.get(navigation.size()-1)),17,accent,false); name.setPadding(dp(4),0,0,0); back.addView(name);
            back.setContentDescription(t("返回：","Back: ")+name.getText()); back.setTag("settings.back"); back.setMinimumHeight(dp(44));
            clickable(back,this::goBack); content.addView(back);
        }
        TextView title=text(title(),page.equals("home")?34:22,ink,true); title.setPadding(0,dp(12),0,dp(16)); content.addView(title);
        switch(page) {
            case "home":home();break;case "setup":setup();break;case "playground":playground();break;
            case "schema":schemas();break;case "chords":chords();break;case "appearance":appearance();break;
            case "resources":resources();break;case "translation":translation();break;case "ai":ai();break;
            case "mappings":mappings();break;case "plugins":plugins();break;
            case "data":data();break;case "privacy":privacy();break;case "licenses":licenses();break;
            case "license":document();break;case "differences":differences();break;
            default:page="home";render();return;
        }
        ScrollView scroll=new ScrollView(this); currentScroll=scroll; scroll.setFillViewport(true); scroll.setVerticalScrollBarEnabled(false);
        scroll.addView(content,new ScrollView.LayoutParams(-1,-2));
        FrameLayout frame=new FrameLayout(this); frame.setBackgroundColor(background); frame.addView(scroll,new FrameLayout.LayoutParams(-1,-1));
        frame.setOnApplyWindowInsetsListener((view,insets) -> {
            if(Build.VERSION.SDK_INT>=30) {
                android.graphics.Insets safe=insets.getInsets(WindowInsets.Type.systemBars()|WindowInsets.Type.displayCutout()|WindowInsets.Type.ime());
                view.setPadding(safe.left,safe.top,safe.right,safe.bottom);
            } else view.setPadding(insets.getSystemWindowInsetLeft(),insets.getSystemWindowInsetTop(),insets.getSystemWindowInsetRight(),insets.getSystemWindowInsetBottom());
            return insets;
        });
        setContentView(frame); content.requestFocus();
        if(previousScroll>0) scroll.post(() -> scroll.scrollTo(0,previousScroll));
    }
    private String title() {
        return titleFor(page);
    }
    private String titleFor(String destination) {
        switch(destination) {
            case "setup":return t("启用 RIMES 键盘","Enable RIMES");case "playground":return t("输入体验","Try typing");
            case "schema":return t("默认方案","Default scheme");case "chords":return t("滑动并击与键位","Slide chords & mappings");
            case "plugins":return t("官方插件","Official plugins");
            case "mappings":return t("内置并击映射","Built-in chord mappings");
            case "appearance":return t("键盘布局与换肤","Keyboard layout & skins");case "resources":return t("Rime 方案与词典","Rime schemes & dictionaries");
            case "translation":return t("本机翻译词典","Local translation dictionary");case "ai":return t("AI 服务","AI services");
            case "data":return t("数据管理","Data management");case "privacy":return t("隐私与第三方许可","Privacy & licenses");
            case "licenses":return t("第三方许可","Third-party licenses");case "license":return license==null?t("许可","License"):license;
            case "differences":return t("Android 功能进度","Android feature status");default:return t("欢迎","Welcome");
        }
    }
    private LinearLayout group(String heading) {
        TextView label=text(heading,13,secondary,false); label.setPadding(dp(16),dp(24),dp(16),dp(8)); content.addView(label);
        LinearLayout group=column(); group.setBackground(shape(card,24)); group.setClipToOutline(true);
        content.addView(group,new LinearLayout.LayoutParams(-1,-2)); return group;
    }
    private void divider(LinearLayout group) {
        if(group.getChildCount()==0) return;
        View line=new View(this); line.setBackgroundColor(separator);
        LinearLayout.LayoutParams frame=new LinearLayout.LayoutParams(-1,Math.max(1,dp(0.5f)));
        frame.setMarginStart(dp(56)); frame.setMarginEnd(dp(16)); group.addView(line,frame);
    }
    private void clickable(View view,Runnable action) {
        view.setFocusable(true); view.setClickable(true);
        view.setForeground(new RippleDrawable(ColorStateList.valueOf(0x22888888),null,shape(0xFFFFFFFF,0)));
        view.setOnClickListener(v -> action.run());
        view.setAccessibilityDelegate(new View.AccessibilityDelegate() {
            @Override public void onInitializeAccessibilityNodeInfo(View host,android.view.accessibility.AccessibilityNodeInfo info) {
                super.onInitializeAccessibilityNodeInfo(host,info); info.setClassName(android.widget.Button.class.getName());
            }
        });
    }
    private ImageView icon(KeyboardIcon value,int tint,int size) {
        ImageView view=new ImageView(this); view.setImageDrawable(value.drawable(this)); view.setImageTintList(ColorStateList.valueOf(tint));
        if((value==KeyboardIcon.CHEVRON_LEFT || value==KeyboardIcon.CHEVRON_RIGHT) && getResources().getConfiguration().getLayoutDirection()==View.LAYOUT_DIRECTION_RTL) view.setScaleX(-1);
        view.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO); view.setLayoutParams(new LinearLayout.LayoutParams(dp(size),dp(size))); return view;
    }
    private LinearLayout row(LinearLayout group,KeyboardIcon image,String label,String detail,String value,String tag,Runnable action) {
        divider(group); LinearLayout row=new LinearLayout(this); row.setOrientation(LinearLayout.HORIZONTAL); row.setGravity(Gravity.CENTER_VERTICAL);
        row.setMinimumHeight(dp(52)); row.setPadding(dp(16),dp(12),dp(16),dp(12)); row.setTag(tag);
        if(image!=null) { ImageView symbol=icon(image,accent,24); ((LinearLayout.LayoutParams)symbol.getLayoutParams()).setMarginEnd(dp(16)); row.addView(symbol); }
        LinearLayout labels=column(); labels.addView(text(label,17,ink,false));
        if(detail!=null) { TextView caption=text(detail,13,secondary,false); caption.setPadding(0,dp(4),0,0); labels.addView(caption); }
        row.addView(labels,new LinearLayout.LayoutParams(0,-2,1));
        if(value!=null) { TextView trailing=text(value,15,accent,false); trailing.setPadding(dp(8),0,dp(6),0); trailing.setMaxWidth(dp(130)); row.addView(trailing); }
        if(action!=null) { row.addView(icon(KeyboardIcon.CHEVRON_RIGHT,secondary,16)); clickable(row,action); }
        row.setContentDescription(label+(detail==null?"":", "+detail)+(value==null?"":", "+value));
        group.addView(row,new LinearLayout.LayoutParams(-1,-2)); return row;
    }
    private void note(String value) {
        TextView view=text(value,13,secondary,false); view.setLineSpacing(dp(3),1); view.setPadding(dp(16),dp(8),dp(16),0); content.addView(view);
    }
    private void paragraph(LinearLayout group,String value) {
        TextView view=text(value,16,ink,false); view.setLineSpacing(dp(4),1); view.setPadding(dp(16),dp(16),dp(16),dp(16)); group.addView(view);
    }
    private String schemeName(String id) {
        if(id.equals("rimes_ziranma")) return t("自然码双拼","Natural Code");
        if(id.equals("rimes_wubi")) return t("五笔 86","Wubi 86"); return t("全拼 · Pinyin","Pinyin");
    }
    private String layoutName(String id) {
        switch(id) { case "nineKey":return t("九键全拼","9-key Pinyin");case "orthogonal":return t("并击矩阵","Chord grid");case "splitOrthogonal":return t("分离并击","Split chords");default:return "QWERTY"; }
    }
    private String directionName(String id) { return id.equals("zh-en")?t("中 → 英","Chinese → English"):id.equals("en-zh")?t("英 → 中","English → Chinese"):t("自动中英","Automatic"); }
    private void home() {
        LinearLayout hero=new LinearLayout(this); hero.setOrientation(LinearLayout.HORIZONTAL); hero.setGravity(Gravity.CENTER_VERTICAL);
        hero.setTag("settings.home.hero"); hero.setPadding(dp(16),dp(16),dp(16),dp(16)); hero.setBackground(shape((accent&0x00FFFFFF)|0x14000000,24));
        ImageView logo=new ImageView(this); logo.setImageResource(R.drawable.rimes_brand_logo); logo.setScaleType(ImageView.ScaleType.FIT_CENTER);
        logo.setBackground(shape(0xFFFFFFFF,16)); logo.setClipToOutline(true); logo.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        LinearLayout.LayoutParams logoParams=new LinearLayout.LayoutParams(dp(72),dp(72)); logoParams.setMarginEnd(dp(16)); hero.addView(logo,logoParams);
        LinearLayout identity=column();
        TextView brand=text("RIMES",32,ink,true); brand.setTypeface(Typeface.create("sans-serif-rounded",Typeface.BOLD)); identity.addView(brand);
        String[] lines={t("世界对智者太过挑剔","The world is too hard on the wise."),t("好奇的人需要朋友","Curious minds need friends.")};
        for(int i=0;i<lines.length;i++) {
            TextView line=text(lines[i],13,secondary,false); line.setSingleLine(true);
            line.setAutoSizeTextTypeUniformWithConfiguration(10,13,1,android.util.TypedValue.COMPLEX_UNIT_SP);
            line.setPadding(0,dp(i==0?6:4),0,0); identity.addView(line,new LinearLayout.LayoutParams(-1,-2));
        }
        hero.addView(identity,new LinearLayout.LayoutParams(0,-2,1)); content.addView(hero);
        LinearLayout start=group(t("开始使用","Get started"));
        row(start,KeyboardIcon.KEYBOARD,t("启用 RIMES 键盘","Enable RIMES keyboard"),null,null,"settings.home.enable",() -> navigate("setup"));
        row(start,KeyboardIcon.WRITE,t("输入体验","Try typing"),null,null,"settings.home.playground",() -> navigate("playground"));
        LinearLayout typing=group(t("你的输入方式","Your typing"));
        row(typing,null,t("默认方案","Default scheme"),null,schemeName(settings.getSchema()),"settings.home.schema",() -> navigate("schema"));
        row(typing,KeyboardIcon.SLIDERS,t("滑动并击与键位","Slide chords & mappings"),null,null,"settings.home.chords",() -> navigate("chords"));
        row(typing,KeyboardIcon.KEYBOARD,t("键盘布局与换肤","Keyboard layout & skins"),null,null,"settings.home.appearance",() -> navigate("appearance"));
        row(typing,KeyboardIcon.STACK_LAYERS,t("Rime 方案与词典","Rime schemes & dictionaries"),null,null,"settings.home.resources",() -> navigate("resources"));
        row(typing,KeyboardIcon.TRANSLATE,t("本机翻译词典","Local translation dictionary"),null,null,"settings.home.translation",() -> navigate("translation"));
        row(typing,KeyboardIcon.MAGIC_WAND,t("AI 服务","AI services"),null,new OpenAiSettings(this).snapshot().enabled?t("联网 AI","Online AI"):"Mock","settings.home.ai",() -> navigate("ai"));
        row(typing,KeyboardIcon.GRID_9,t("官方插件","Official plugins"),null,null,"settings.home.plugins",() -> navigate("plugins"));
        LinearLayout more=group(t("数据与隐私","Data & privacy"));
        row(more,KeyboardIcon.STACK_LAYERS,t("数据管理","Data management"),null,null,"settings.home.data",() -> navigate("data"));
        row(more,KeyboardIcon.BOOK,t("隐私与第三方许可","Privacy & third-party licenses"),null,null,"settings.home.privacy",() -> navigate("privacy"));
        row(more,KeyboardIcon.SETTINGS,t("Android 功能进度","Android feature status"),null,null,"settings.home.differences",() -> navigate("differences"));
        String version;
        try { version=getPackageManager().getPackageInfo(getPackageName(),0).versionName; }
        catch(android.content.pm.PackageManager.NameNotFoundException error) { version=t("开发版","Development"); }
        note("RIMES  "+version);
        contactLink("pm.scholay.com","https://pm.scholay.com",false);
        contactLink("pm@scholay.com","mailto:pm@scholay.com",true);
    }
    private void contactLink(String label,String destination,boolean email) {
        TextView link=text(label,13,accent,false); link.setGravity(Gravity.CENTER); link.setMinHeight(dp(44));
        link.setTag(email?"settings.home.email":"settings.home.website");
        link.setContentDescription((email?t("联系邮箱，","Email, "):t("官网，","Website, "))+label);
        clickable(link,() -> {
            try { startActivity(new Intent(email?Intent.ACTION_SENDTO:Intent.ACTION_VIEW,android.net.Uri.parse(destination))); }
            catch(android.content.ActivityNotFoundException error) {
                String message=email?t("没有可用的邮件应用","No email app is available."):t("没有可用的浏览器","No browser is available.");
                android.widget.Toast.makeText(this,message,android.widget.Toast.LENGTH_SHORT).show();
            }
        });
        content.addView(link,new LinearLayout.LayoutParams(-1,-2));
    }
    private void setup() {
        LinearLayout status=group(t("键盘状态","Keyboard status")); InputMethodManager manager=getSystemService(InputMethodManager.class);
        boolean enabled=manager.getEnabledInputMethodList().stream().anyMatch(method -> method.getPackageName().equals(getPackageName()));
        String chosen=Settings.Secure.getString(getContentResolver(),Settings.Secure.DEFAULT_INPUT_METHOD);
        row(status,KeyboardIcon.KEYBOARD,t("RIMES 键盘","RIMES keyboard"),null,enabled?t("已启用","Enabled"):t("待启用","Not enabled"),"settings.setup.status",null);
        row(status,KeyboardIcon.CHECK,t("当前输入法","Current input method"),null,chosen!=null && chosen.startsWith(getPackageName()+"/")?"RIMES":t("其他键盘","Another keyboard"),"settings.setup.selected",null);
        LinearLayout steps=group(t("开始使用","Get started"));
        row(steps,KeyboardIcon.SETTINGS,t("1. 启用键盘","1. Enable keyboard"),t("打开系统输入法设置，启用 RIMES。","Open system input settings and enable RIMES."),null,"settings.setup.enable",() -> startActivity(new Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)));
        row(steps,KeyboardIcon.GLOBE,t("2. 选择键盘","2. Choose keyboard"),t("在输入法列表中选择 RIMES。","Choose RIMES in the keyboard picker."),null,"settings.setup.choose",manager::showInputMethodPicker);
        row(steps,KeyboardIcon.KEYBOARD,t("3. 试打","3. Try typing"),null,null,"settings.setup.try",() -> navigate("playground"));
        note(t("中文词典已随应用安装。首次使用无需联网下载，英文在中文引擎准备时也可输入。","Chinese dictionaries are bundled. No download is needed; English remains available while Chinese prepares."));
    }
    private void playground() {
        note(t("试打、切换输入框，或打开 Buffer 体验确认后发送。这里的内容不会保存。","Try typing, switch fields, or open Buffer to send confirmed blocks. Text on this page is not saved."));
        int[] hints={R.string.try_typing,R.string.second_field,R.string.password_field,R.string.private_field}; String[] ids={"primary","secondary","password","private"};
        String[] headings={t("试打","Typing"),t("第二个输入框","Another field"),t("密码输入","Password"),t("私密输入","Private input")};
        for(int i=0;i<hints.length;i++) {
            LinearLayout group=group(headings[i]); EditText input=new EditText(this); input.setTag("settings.playground."+ids[i]); input.setHint(hints[i]);
            input.setInputType(InputType.TYPE_CLASS_TEXT|(i==2?InputType.TYPE_TEXT_VARIATION_PASSWORD:InputType.TYPE_TEXT_FLAG_MULTI_LINE));
            if(i==3) input.setImeOptions(EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING);
            input.setSaveEnabled(false); input.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);
            input.setTextColor(ink); input.setHintTextColor(secondary); input.setTextSize(17); input.setGravity(Gravity.TOP|Gravity.START);
            input.setPadding(dp(16),dp(16),dp(16),dp(16)); input.setMinHeight(dp(i==0?170:64)); input.setBackgroundColor(android.graphics.Color.TRANSPARENT);
            group.addView(input,new LinearLayout.LayoutParams(-1,-2));
        }
        note(getString(R.string.privacy));
    }
    private void choice(LinearLayout group,String label,String detail,String tag,boolean selected,Runnable action) {
        LinearLayout row=row(group,null,label,detail,null,tag,null); clickable(row,action); row.setSelected(selected);
        row.setContentDescription(label+(selected?t("，已选择",", selected"):"")+(detail==null?"":", "+detail));
        if(selected) row.addView(icon(KeyboardIcon.CHECK,accent,20));
    }
    private void schemas() {
        LinearLayout choices=group(t("中文输入方案","Chinese input scheme")); String[] ids={"rimes_pinyin","rimes_ziranma","rimes_wubi"}; String[] samples={"nihao → 你好","nihk → 你好","wq → 你"};
        for(int i=0;i<ids.length;i++) { String id=ids[i]; choice(choices,schemeName(id),samples[i],"settings.schema."+id,settings.getSchema().equals(id),() -> { settings.setSchema(id); render(); }); }
        note(t("九键使用全拼；选择其他方案会切换到 QWERTY。并击使用自然码编码，选择普通中文方案会退出并击布局。","9-key uses Pinyin; another scheme switches to QWERTY. Chords use Natural Code; selecting a regular scheme leaves the chord layout."));
    }
    private void segments(LinearLayout parent,String[] ids,String[] labels,String selected,String prefix,java.util.function.Consumer<String> action) {
        LinearLayout bar=new LinearLayout(this); bar.setOrientation(LinearLayout.HORIZONTAL); bar.setPadding(dp(3),dp(3),dp(3),dp(3)); bar.setBackground(shape(separator,9));
        for(int i=0;i<ids.length;i++) {
            String id=ids[i]; boolean active=id.equals(selected); TextView button=text(labels[i],14,active?ink:secondary,active);
            button.setTag(prefix+id); button.setGravity(Gravity.CENTER); button.setMinHeight(dp(44)); button.setPadding(dp(4),dp(4),dp(4),dp(4));
            button.setBackground(shape(active?card:android.graphics.Color.TRANSPARENT,7)); button.setSelected(active);
            button.setContentDescription(labels[i]+(active?t("，已选择",", selected"):"")); clickable(button,() -> action.accept(id));
            bar.addView(button,new LinearLayout.LayoutParams(0,-2,1));
        }
        LinearLayout.LayoutParams frame=new LinearLayout.LayoutParams(-1,-2); frame.setMargins(dp(16),dp(12),dp(16),dp(12)); parent.addView(bar,frame);
    }
    private void preview(LinearLayout group) {
        SettingsKeyboardPreview preview=new SettingsKeyboardPreview(this,settings.getLayout(),KeyboardTheme.named(settings.getTheme())); preview.setTag("settings.preview");
        LinearLayout.LayoutParams frame=new LinearLayout.LayoutParams(-1,-2); frame.setMargins(dp(12),dp(4),dp(12),dp(12)); group.addView(preview,frame);
    }
    private void appearance() {
        content.addView(text(t("熟悉的键位，喜欢的外观","Familiar keys. Your favorite look."),20,ink,true));
        note(t("标准键盘和并击共用配色，按下反馈也跟随主题。","Standard keys and chords share a palette, including press feedback."));
        LinearLayout standard=group(t("标准键盘","Standard keyboard"));
        segments(standard,new String[]{"qwerty","nineKey"},new String[]{t("QWERTY · 26 键","QWERTY · 26 keys"),t("九键全拼","9-key Pinyin")},settings.getLayout(),"settings.layout.",id -> { settings.setLayout(id); render(); }); preview(standard);
        note(settings.getLayout().equals("nineKey")?t("九键仅用于全拼；英文和数字沿用标准键位。","9-key is for Pinyin; English and numbers use the standard keys."):t("当前布局：","Current layout: ")+layoutName(settings.getLayout()));
        LinearLayout themes=group(t("宠物与键盘配色","Pets & keyboard colors")); paragraph(themes,t("当前配色：","Current color: ")+KeyboardTheme.named(settings.getTheme()).title);
        for(int start=0;start<KeyboardTheme.ALL.length;start+=3) {
            LinearLayout line=new LinearLayout(this); line.setOrientation(LinearLayout.HORIZONTAL);
            for(int i=start;i<Math.min(start+3,KeyboardTheme.ALL.length);i++) {
                KeyboardTheme theme=KeyboardTheme.ALL[i]; KeyboardTheme.Palette palette=theme.palette(this); boolean selected=theme.id.equals(settings.getTheme());
                LinearLayout tile=column(); tile.setTag("settings.theme."+theme.id); tile.setPadding(dp(9),dp(9),dp(9),dp(9)); tile.setGravity(Gravity.CENTER);
                GradientDrawable tileShape=shape(palette.background,11); if(selected) tileShape.setStroke(dp(2),palette.accent); tile.setBackground(tileShape);
                TextView glyph=text(theme.id.equals("apple")?"●":theme.glyph,28,palette.ink,false); glyph.setGravity(Gravity.CENTER); tile.addView(glyph);
                TextView name=text(theme.id.equals("apple")?t("原生","Native"):theme.title,12,palette.ink,true); name.setGravity(Gravity.CENTER); tile.addView(name);
                LinearLayout swatches=new LinearLayout(this); int[] colors={palette.key,palette.functional,palette.accent};
                for(int c:colors) { View swatch=new View(this); swatch.setBackground(shape(c,3)); LinearLayout.LayoutParams frame=new LinearLayout.LayoutParams(0,dp(10),1); frame.setMargins(dp(2),0,dp(2),0); swatches.addView(swatch,frame); }
                LinearLayout.LayoutParams strip=new LinearLayout.LayoutParams(-1,dp(10)); strip.topMargin=dp(7); tile.addView(swatches,strip);
                tile.setSelected(selected); tile.setContentDescription(t("配色：","Color: ")+name.getText()+(selected?t("，已选择",", selected"):"")); clickable(tile,() -> { settings.setTheme(theme.id); render(); });
                LinearLayout.LayoutParams frame=new LinearLayout.LayoutParams(0,-2,1); frame.setMargins(i==start?0:dp(8),0,0,0); line.addView(tile,frame);
            }
            LinearLayout.LayoutParams frame=new LinearLayout.LayoutParams(-1,-2); frame.setMargins(dp(12),0,dp(12),dp(10)); themes.addView(line,frame);
        }
        note(t("轻点键盘左上角的宠物轮换 18 套皮肤与配色，长按选择宠物或键位方案。Android 当前使用静态宠物图示。","Tap the top-left pet to cycle through 18 skins and keyboard colors. Hold to choose a pet or keyboard layout. Android currently uses static pet symbols."));
    }
    private void plugins() {
        if(officialPlugins.entries().isEmpty()) { note(t("插件目录不可用，请重新安装应用。","Plugin catalog unavailable. Please reinstall the app.")); return; }
        for(OfficialPluginStore.Entry entry:officialPlugins.entries()) {
            LinearLayout group=group(entry.name+" · "+entry.version);
            OfficialPluginStore.State state=officialPlugins.state(entry);
            if(state.installed) {
                toggle(group,t("启用","Enabled"),"settings.plugin."+entry.legacyID+".enabled",state.enabled,enabled -> {
                    try { officialPlugins.setEnabled(entry,enabled); } catch(Exception error) { pluginError(error); }
                    render();
                });
                row(group,null,t("卸载","Uninstall"),null,null,"settings.plugin."+entry.legacyID+".uninstall",() -> {
                    try { officialPlugins.uninstall(entry); } catch(Exception error) { pluginError(error); }
                    render();
                });
            } else {
                row(group,KeyboardIcon.STACK_LAYERS,entry.id.equals(installingPlugin)?t("正在安装…","Installing…"):
                    entry.bundled?t("恢复安装","Restore"):t("下载安装","Download"),null,null,"settings.plugin."+entry.legacyID+".install",() -> {
                    if(installingPlugin!=null) return;
                    installingPlugin=entry.id; render();
                    documents.execute(() -> {
                        Exception failure=null;
                        try { officialPlugins.install(entry); } catch(Exception error) { failure=error; }
                        final Exception result=failure;
                        runOnUiThread(() -> { if(destroyed) return; installingPlugin=null; if(result!=null) pluginError(result); render(); });
                    });
                });
            }
        }
        note(t("下载后默认停用。启用不会自动选择插件或发送原文；卸载保留配置、词库和用户文档。","Downloads start disabled. Enabling does not select a plugin or send text. Uninstalling keeps settings, dictionaries and user documents."));
    }
    private void pluginError(Exception error) {
        android.widget.Toast.makeText(this,error.getMessage()==null?t("插件操作未完成","Plugin operation failed"):error.getMessage(),android.widget.Toast.LENGTH_LONG).show();
    }
    private void chords() {
        LinearLayout instructions=group(t("双手滑动并击","Two-thumb slide chords"));
        paragraph(instructions,t("每手：起点＋终点。途中经过键不计入；双手全部松开时提交。划回起点恢复单键。","Each hand uses its start and end key. Keys crossed along the way do not count. Release both hands to commit; slide back to the start to restore a single key."));
        LinearLayout layouts=group(t("键位布局","Keyboard layout"));
        segments(layouts,new String[]{"orthogonal","splitOrthogonal"},new String[]{t("并击矩阵","Chord grid"),t("分离并击","Split chords")},settings.getLayout(),"settings.layout.",id -> { settings.setLayout(id); render(); }); preview(layouts);
        row(layouts,KeyboardIcon.KEYBOARD,t("返回标准键盘","Use standard keyboard"),null,null,"settings.chords.standard",() -> { settings.setLayout("qwerty"); render(); });
        LinearLayout profile=group(t("当前映射","Current mappings")); paragraph(profile,t("内置方案 · 自然码编码\n427 项映射，与 iOS 内置方案一致。","Built-in profile · Natural Code\n427 mappings shared with the iOS built-in profile."));
        row(profile,KeyboardIcon.BOOK,t("查看全部映射","View all mappings"),null,null,"settings.chords.mappings",() -> navigate("mappings"));
        for(String keys:new String[]{"wz","lu","mt","kp"}) {
            ChordProfile.Resolution value=ChordProfile.builtIn().resolve(ChordProfile.builtIn().mask(keys));
            if(value!=null) row(profile,null,keys.toUpperCase(java.util.Locale.ROOT),value.preview+" → "+value.input,null,"settings.chords.example."+keys,null);
        }
        note(t("Android 暂不支持导入或编辑并击映射。","Importing and editing chord profiles is not available on Android yet."));
    }
    private void mappings() {
        note(t("键组合 → 拼音／声韵母 · 自然码输入。内置映射仅供查阅。","Key combination → Pinyin / fragment · Natural Code. Built-in mappings are read-only."));
        LinearLayout group=group(t("427 项内置映射","427 built-in mappings")); StringBuilder table=new StringBuilder();
        for(ChordProfile.Entry entry:ChordProfile.builtIn().entries) table.append(entry.keys).append("  →  ").append(entry.output).append("  ·  ").append(entry.input).append('\n');
        TextView view=text(table.toString(),16,ink,false); view.setTypeface(Typeface.MONOSPACE); view.setTextIsSelectable(true); view.setPadding(dp(16),dp(16),dp(16),dp(16)); group.addView(view);
    }
    private void resources() {
        LinearLayout bundled=group(t("随应用安装","Bundled with the app")); row(bundled,KeyboardIcon.STACK_LAYERS,"librime",t("离线引擎","Offline engine"),"1.17.0","settings.resources.engine",null);
        for(String id:new String[]{"rimes_pinyin","rimes_ziranma","rimes_wubi"}) row(bundled,KeyboardIcon.BOOK,schemeName(id),t("已预编译，无需下载","Precompiled; no download needed"),null,"settings.resources."+id,null);
        note(t("系统词典与用户词库分别保存，更新应用保留用户词库。Android 暂不支持外部方案包导入。","System dictionaries and learned words are stored separately. App updates preserve learned words. External scheme import is not available on Android yet."));
        LinearLayout actions=group(t("管理","Manage")); row(actions,KeyboardIcon.STACK_LAYERS,t("本机词库学习","Local word learning"),null,null,"settings.resources.data",() -> navigate("data"));
        row(actions,KeyboardIcon.BOOK,t("第三方许可","Third-party licenses"),null,null,"settings.resources.licenses",() -> navigate("licenses"));
    }
    private void translation() {
        LinearLayout directions=group(t("翻译方向","Translation direction"));
        for(String id:new String[]{"auto","zh-en","en-zh"}) choice(directions,directionName(id),null,"settings.translation."+id,settings.getTranslationDirection().equals(id),() -> { settings.setTranslationDirection(id); render(); });
        LinearLayout dictionary=group(t("本机词典","On-device dictionary")); row(dictionary,KeyboardIcon.BOOK,"CC-CEDICT",t("随应用安装 · 125,166 条原始词条","Bundled · 125,166 source entries"),t("已准备好","Ready"),"settings.translation.dictionary",null);
        paragraph(dictionary,t("在键盘的 Buffer 快捷入口选择“翻译”，输入并确认文字后自动查译。结果可检查后再发送。","Choose Translate from the keyboard’s Buffer shortcuts. Confirmed input is translated automatically. Review the result before inserting it."));
        note(t("支持中英词与词组查译。未覆盖的词保留原文；逐词查译不保证句子语法。","Looks up Chinese–English words and phrases. Unknown words remain unchanged; word lookup does not ensure sentence grammar."));
        LinearLayout legal=group(t("词典许可","Dictionary license")); row(legal,KeyboardIcon.BOOK,"CC BY-SA 4.0",null,null,"settings.translation.license",() -> openLicense("CC-CEDICT-CC-BY-SA-4.0.txt"));
    }
    private void toggle(LinearLayout group,String label,String tag,boolean checked,java.util.function.Consumer<Boolean> save) {
        divider(group); Switch toggle=new Switch(this); toggle.setText(label); toggle.setTextSize(17); toggle.setTextColor(ink); toggle.setPadding(dp(16),dp(12),dp(16),dp(12));
        toggle.setMinHeight(dp(52)); toggle.setTag(tag); toggle.setChecked(checked);
        toggle.setThumbTintList(new ColorStateList(new int[][]{{android.R.attr.state_checked},{}},new int[]{accent,secondary}));
        toggle.setOnCheckedChangeListener((button,value) -> save.accept(value)); group.addView(toggle,new LinearLayout.LayoutParams(-1,-2));
    }
    private void ai() {
        OpenAiSettings comet=new OpenAiSettings(this); OpenAiSettings.Snapshot profile=comet.snapshot();
        LinearLayout remote=group(t("联网 AI","Online AI"));
        row(remote,KeyboardIcon.MAGIC_WAND,t("联网 AI","Online AI"),profile.baseURL,profile.enabled?t("已启用","Enabled"):t("未启用","Off"),"settings.ai.comet",null);
        note(t("启用并点执行后，仅将本次 Buffer 原文发送给你配置的 AI 服务。普通打字不联网；密码和隐私输入框禁用 AI。结果须手动发送。","After enabling, Run sends only the current Buffer source to your configured AI service. Ordinary typing stays offline; AI is disabled in password and private fields. Insert results manually."));
        LinearLayout configuration=group(t("连接设置","Connection settings"));
        EditText address=aiField(configuration,t("API 地址","API URL"),profile.baseURL,"settings.ai.base_url",false);
        EditText model=aiField(configuration,t("模型","Model"),profile.model,"settings.ai.comet.model",false);
        note(t("可填写服务根地址或完整的 /chat/completions 地址。例如 DeepSeek：https://api.deepseek.com。更换服务时请同时填写对应密钥。","Use a base URL or a full /chat/completions URL. For DeepSeek: https://api.deepseek.com. Enter that provider’s key when switching services."));
        EditText key=aiField(configuration,"API Key","","settings.ai.comet.key",true);
        key.setHint(profile.hasKey()?t("已安全保存；留空保留现有密钥","Saved securely; leave blank to keep"):t("输入 API Key","Enter API key"));
        boolean[] enabled={profile.enabled},translation={profile.translation};
        toggle(configuration,t("启用联网 AI","Enable online AI"),"settings.ai.comet.enabled",enabled[0],value -> enabled[0]=value);
        toggle(configuration,t("实时翻译也使用 AI","Use AI for live translation"),"settings.ai.comet.translation",translation[0],value -> translation[0]=value);
        TextView status=text("",14,secondary,false); status.setPadding(dp(16),dp(8),dp(16),dp(8)); status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE); configuration.addView(status);
        row(configuration,KeyboardIcon.CHECK,t("保存设置","Save settings"),null,null,"settings.ai.comet.save",() -> {
            try {
                comet.save(address.getText().toString(),model.getText().toString(),key.getText().toString(),enabled[0],translation[0]);
                key.setText(""); show("ai");
                android.widget.Toast.makeText(this,t("AI 设置已保存","AI settings saved"),android.widget.Toast.LENGTH_SHORT).show();
            } catch(OpenAiChatCodec.Failure error) { status.setText(error.getMessage()); }
        });
        row(configuration,null,t("移除密钥并关闭联网 AI","Remove key and disable online AI"),null,null,"settings.ai.comet.clear",() -> {
            try { comet.clear(); key.setText(""); show("ai"); }
            catch(OpenAiChatCodec.Failure error) { status.setText(error.getMessage()); }
        });
        note(t("密钥由 Android Keystore 加密，不参与备份。不保存请求或回复正文。未启用 AI 翻译时，翻译仍使用本机词典。","Keys are encrypted with Android Keystore and excluded from backup. Request and reply text is not saved. Translation uses the local dictionary unless AI translation is enabled."));
        LinearLayout service=group(t("本机演示","Local demo")); row(service,KeyboardIcon.MAGIC_WAND,t("本机演示服务","On-device demo service"),"OpenAI Chat Completions · Mock",null,"settings.ai.service",null);
        toggle(service,t("启用 AI Mock","Enable AI Mock"),"settings.ai_mock_enabled",settings.isAiMockEnabled(),settings::setAiMockEnabled);
        row(service,null,t("模型","Model"),OpenAiChatCodec.MOCK_MODEL,null,"settings.ai.model",null);
        row(service,null,t("接口格式","Interface format"),"/v1/chat/completions",null,"settings.ai.format",null);
        row(service,null,t("回复方式","Reply format"),null,t("流式 SSE","Streaming SSE"),"settings.ai.stream",null);
        note(t("快问、润色、作诗和画画提示词使用本机模拟回复。无需 API Key，也不会向外发送输入。","Quick questions, polish, poems and art prompts use simulated local replies. No API key is needed and input is not sent off-device."));
        LinearLayout flow=group(t("在键盘中使用","Use from the keyboard")); paragraph(flow,t("候选栏没有候选字时显示 Buffer 插件快捷入口。选择插件，在 Buffer 确认原文后点执行；检查结果，再点发送。","When there are no candidates, the candidate bar shows Buffer plugin shortcuts. Choose a plugin, confirm text in Buffer, then run; review the result and insert it."));
        note(t("启用时优先使用联网 AI。联网失败会保留原文，不切换到模拟回复。画画目前只生成文字提示词。","Online AI takes priority when enabled. Network failures preserve the source without falling back to mock replies. Art currently produces text prompts only."));
    }
    private EditText aiField(LinearLayout group,String label,String value,String tag,boolean secret) {
        TextView title=text(label,14,secondary,false); title.setPadding(dp(16),dp(12),dp(16),0); group.addView(title);
        EditText field=new EditText(this); field.setTag(tag); field.setContentDescription(label); field.setTextSize(16); field.setTextColor(ink); field.setHintTextColor(secondary);
        field.setSingleLine(true); field.setSaveEnabled(false); field.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);
        field.setInputType(InputType.TYPE_CLASS_TEXT|(secret?InputType.TYPE_TEXT_VARIATION_PASSWORD:InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS));
        field.setImeOptions(EditorInfo.IME_ACTION_DONE|EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING);
        if(secret) field.setTransformationMethod(android.text.method.PasswordTransformationMethod.getInstance());
        field.setText(value); LinearLayout.LayoutParams frame=new LinearLayout.LayoutParams(-1,dp(52)); frame.setMargins(dp(16),0,dp(16),dp(4)); group.addView(field,frame); return field;
    }
    private void data() {
        LinearLayout learning=group(t("用户词库","Learned words")); toggle(learning,getString(R.string.learning),"settings.learning",settings.isLearningEnabled(),settings::setLearningEnabled); note(getString(R.string.learning_detail));
        LinearLayout local=group(t("本机数据","Local data")); paragraph(local,t("用户词库位于应用私有目录，排除系统备份。覆盖升级会保留词库、方案偏好和设置。\n\nBuffer 只保留本次草稿，换框或关闭键盘后清空。这里不保存完整输入历史，也不保存 AI 请求或试打文字。","Learned words stay in the app’s private directory, excluded from system backup. Updating preserves words, scheme preferences and settings.\n\nBuffer holds the current draft and clears when the field changes or the keyboard closes. Full typing history, AI requests and playground text are not saved."));
    }
    private void privacy() {
        LinearLayout input=group(t("输入与学习","Typing & learning")); paragraph(input,getString(R.string.privacy)+"\n\n"+getString(R.string.learning_detail));
        LinearLayout clipboard=group(t("本地剪贴板","Local clipboard")); paragraph(clipboard,t("键盘设置里的“本地剪贴板”只在主动点“收录当前文字”后保存文字，不自动监听。最多 40 条、总共 128 KiB、单条 16 KiB，保存在本机私有且不参与备份的目录。可逐条删除或清空；点条目加入 Buffer，结果确认后再插入；当前若启用实时 AI 翻译，会自动翻译已确认的原文。密码和私密输入框禁用。长按左上宠物，在面板中打开“本地剪贴板”。","Hold the top-left pet and open Local clipboard in its panel. Only Collect current text saves a record; there is no monitoring. Up to 40 entries, 128 KiB total and 16 KiB each stay in private device-only storage, excluded from backup. Delete entries or clear history. Tapping an entry adds it to Buffer; enabled live AI translation automatically translates confirmed source. Insert the result explicitly when ready. Password and private fields disable this feature."));
        LinearLayout plugins=group(t("翻译与 AI","Translation & AI")); paragraph(plugins,t("翻译默认查阅本机 CC-CEDICT 词典。联网 AI 需在 AI 服务中配置并启用。实时翻译自动处理已确认的 Buffer 原文；若开启 AI 翻译，会自动发送本次原文给已配置的服务，其他 AI 插件需点执行。未启用时可用本机 Mock。只有主动点“粘贴剪贴板文字”才读取当前文字到 Buffer，不监听剪贴板，不读取联系人或完整输入历史。结果只有点发送后进入当前输入框。","Translation defaults to bundled CC-CEDICT lookup. Online AI requires explicit configuration and enabling. Live translation runs on confirmed Buffer input; enabling AI translation sends that source automatically to the configured provider. Other AI plugins require Run. A local mock is available when online AI is off. An explicit Paste clipboard text tap reads the current text into Buffer; there is no clipboard monitoring, contacts or full typing-history access. Results enter the current field only after you insert them."));
        LinearLayout legal=group(t("开源软件与资源","Open-source software & resources")); row(legal,KeyboardIcon.BOOK,t("第三方许可","Third-party licenses"),null,null,"settings.privacy.licenses",() -> navigate("licenses"));
    }
    private void differences() {
        LinearLayout available=group(t("已可配置","Available settings")); paragraph(available,t("全拼、自然码、五笔；26 键、九键、两种并击布局；18 套配色；本机中英查译方向；AI 地址、密钥、模型、AI 翻译与 Mock 开关；本机词库学习。","Pinyin, Natural Code and Wubi; QWERTY, 9-key and two chord layouts; 18 colors; local Chinese–English lookup direction; AI URL, key, model, AI translation and mock toggles; local word learning."));
        LinearLayout later=group(t("与 iOS 的功能差异","Features still different from iOS"));
        String[][] entries={
            {t("更多 AI 服务","More AI providers"),t("支持 DeepSeek 与兼容 OpenAI 的文字服务，可自行填写地址、模型和密钥；图像生成尚未接通。","DeepSeek and OpenAI-compatible text services accept a custom URL, model and key. Image generation is not connected yet.")},
            {t("翻译语言包","Translation language packs"),t("Android 使用本机中英词典，不使用苹果翻译语言包。","Android uses a local Chinese–English dictionary rather than Apple Translation packs.")},
            {t("并击与 Rime 方案导入","Chord & Rime profile import"),t("当前仅内置方案，尚未接通自定义导入与编辑。","Built-in profiles only; custom import and editing are not connected.")},
            {t("宠物轮换与动画","Pet rotation & animation"),t("轻点可轮换 18 套宠物与皮肤，当前是静态图示，无自选轮换池。","Tap to cycle through 18 pets and skins; symbols are static, with no custom rotation pool.")},
            {t("作诗句式与词卡","Poem forms & word cards"),t("作诗支持联网 AI；尚无句式与词卡库配置。","Poems support online AI; forms and word-card configuration are not available.")},
            {t("打字统计卡片","Typing stats cards"),t("尚未实现。","Not implemented yet.")}
        };
        for(String[] entry:entries) row(later,null,entry[0],entry[1],null,null,null);
    }
    private void licenses() {
        LinearLayout list=group(t("随应用提供的许可证","Licenses bundled with the app"));
        try { String[] files=getAssets().list("licenses"); if(files!=null) { java.util.Arrays.sort(files); for(String file:files) row(list,KeyboardIcon.BOOK,file,null,null,"settings.license."+file,() -> openLicense(file)); } }
        catch(java.io.IOException error) { paragraph(list,t("许可列表暂不可用，请返回重试。","The license list is unavailable. Return and try again.")); }
    }
    private void openLicense(String name) { license=name; navigate("license"); }
    private void document() {
        LinearLayout group=group(t("许可文本","License text")); TextView body=text(t("正在读取…","Loading…"),14,ink,false); body.setTextIsSelectable(true); body.setPadding(dp(16),dp(16),dp(16),dp(16)); group.addView(body);
        long generation=documentGeneration; String filename=license;
        if(filename==null || filename.contains("/") || filename.contains("..")) { body.setText(t("许可不可用","License unavailable")); return; }
        documents.execute(() -> {
            String value;
            try(InputStream input=getAssets().open("licenses/"+filename);java.io.ByteArrayOutputStream bytes=new java.io.ByteArrayOutputStream()) {
                byte[] block=new byte[8192]; int count; while((count=input.read(block))!=-1) { if(bytes.size()+count>262144) throw new java.io.IOException("License too large"); bytes.write(block,0,count); }
                value=new String(bytes.toByteArray(),StandardCharsets.UTF_8);
            } catch(java.io.IOException error) { value=t("许可暂不可用，请返回重试。","License unavailable. Return and try again."); }
            String result=value; runOnUiThread(() -> { if(!destroyed && generation==documentGeneration && page.equals("license")) body.setText(result); });
        });
    }
}
