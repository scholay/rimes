package org.scholay.rimes.android;

import android.content.Context;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Consumer;

/** Pet selection is the primary page; key layout, schemas and Buffer actions remain explicit. */
final class KeyboardAppearancePanel extends ScrollView {
    private final List<KeyButton> themes=new ArrayList<>(),actions=new ArrayList<>(),schemas=new ArrayList<>();
    private final KeyButton qwerty,nine,chord,split,petsTab,keysTab,close;
    private final LinearLayout pets,keys,schemaRow;
    private String schema="rimes_pinyin";
    private boolean petsPage=true;
    private final TextView note;
    KeyboardAppearancePanel(Context context,Consumer<String> layout,Consumer<String> theme,Runnable dismiss) {
        super(context); setFillViewport(true);
        LinearLayout column=column(); addView(column);
        LinearLayout tabs=row(column,36);
        petsTab=button(tabs,"宠物与皮肤",() -> page(true)); petsTab.setContentDescription("宠物与皮肤选项");
        keysTab=button(tabs,"键位与方案",() -> page(false)); keysTab.setContentDescription("键位与方案");
        close=button(tabs,"返回",dismiss); close.icon(KeyboardIcon.KEYBOARD,18); close.setContentDescription("返回键盘");
        close.setLayoutParams(new LinearLayout.LayoutParams(dp(36),-1));
        pets=column(); column.addView(pets);
        note=new TextView(context); note.setTextSize(13); note.setPadding(dp(8),dp(8),dp(8),dp(4)); pets.addView(note);
        LinearLayout current=null;
        for(int i=0;i<KeyboardTheme.ALL.length;i++) {
            if(i%3==0) current=row(pets,48);
            KeyboardTheme option=KeyboardTheme.ALL[i];
            KeyButton item=button(current,option.glyph+" "+option.title,() -> theme.accept(option.id));
            item.setContentDescription("配色 "+option.title); themes.add(item);
        }
        keys=column(); column.addView(keys);
        LinearLayout layouts=row(keys,48);
        qwerty=button(layouts,"26 键 · QWERTY",() -> layout.accept("qwerty")); qwerty.setContentDescription("布局 26 键");
        nine=button(layouts,"9 键 · 拼音",() -> layout.accept("nineKey")); nine.setContentDescription("布局 9 键");
        schemaRow=row(keys,40);
        LinearLayout chords=row(keys,48);
        chord=button(chords,"并击 · 正交",() -> layout.accept("orthogonal")); chord.setContentDescription("布局 正交并击");
        split=button(chords,"并击 · 分体正交",() -> layout.accept("splitOrthogonal")); split.setContentDescription("布局 分体并击");
        page(true);
    }
    /** Each open starts with the pet chooser, rather than an unrelated settings page. */
    void showPets() { page(true); }
    private void page(boolean petsPage) {
        this.petsPage=petsPage;
        pets.setVisibility(petsPage?View.VISIBLE:View.GONE); keys.setVisibility(petsPage?View.GONE:View.VISIBLE);
        petsTab.setSelected(petsPage); keysTab.setSelected(!petsPage); scrollTo(0,0);
    }
    void render(String layout,KeyboardTheme theme) {
        qwerty.setSelected(layout.equals("qwerty")); nine.setSelected(layout.equals("nineKey"));
        chord.setSelected(layout.equals("orthogonal")); split.setSelected(layout.equals("splitOrthogonal"));
        for(KeyButton button:new KeyButton[]{petsTab,keysTab,close,qwerty,nine,chord,split}) button.theme(theme);
        for(int i=0;i<schemas.size();i++) { schemas.get(i).theme(theme); schemas.get(i).setSelected(schema.equals(new String[]{"rimes_pinyin","rimes_ziranma","rimes_wubi"}[i])); }
        for(KeyButton key:actions) key.theme(theme);
        note.setTextColor(theme.palette(getContext()).ink);
        note.setText("轻点宠物轮换皮肤与键盘配色；长按选择。当前："+theme.title+"。宠物图示为静态。");
        for(int i=0;i<themes.size();i++) { KeyButton button=themes.get(i); button.theme(KeyboardTheme.ALL[i]); button.setSelected(KeyboardTheme.ALL[i]==theme); }
        petsTab.setSelected(petsPage); keysTab.setSelected(!petsPage);
        setBackgroundColor(theme.palette(getContext()).background);
    }
    void schemes(String selected,Consumer<String> choose) {
        schema=selected;
        if(!schemas.isEmpty()) return;
        String[] ids={"rimes_pinyin","rimes_ziranma","rimes_wubi"},names={"拼音","自然码","五笔"};
        for(int i=0;i<ids.length;i++) { final String id=ids[i]; KeyButton key=button(schemaRow,names[i],() -> choose.accept(id)); key.setContentDescription("中文方案 "+names[i]); schemas.add(key); }
    }
    void action(String title,String description,Runnable perform) {
        LinearLayout column=(LinearLayout)getChildAt(0); KeyButton button=button(row(column,48),title,perform); button.setContentDescription(description);
        button.icon(description.equals(getResources().getString(R.string.switch_keyboard))?KeyboardIcon.GLOBE
                :description.equals(getResources().getString(R.string.insert_all))?KeyboardIcon.SEND_ALL
                :description.equals(getResources().getString(R.string.clipboard_paste))?KeyboardIcon.WRITE
                :description.equals(getResources().getString(R.string.clipboard_history))?KeyboardIcon.STACK_LAYERS:KeyboardIcon.CLEAR,18,true);
        actions.add(button);
    }
    private LinearLayout column() { LinearLayout column=new LinearLayout(getContext()); column.setOrientation(LinearLayout.VERTICAL); return column; }
    private LinearLayout row(LinearLayout column,int height) {
        LinearLayout row=new LinearLayout(getContext()); column.addView(row,new LinearLayout.LayoutParams(-1,dp(height))); return row;
    }
    private KeyButton button(LinearLayout row,String text,Runnable action) {
        KeyButton button=new KeyButton(getContext()); button.setText(text); button.font(14);
        button.setOnClickListener(v -> action.run()); row.addView(button,new LinearLayout.LayoutParams(0,-1,1)); return button;
    }
    private int dp(int value) { return Math.round(value*getResources().getDisplayMetrics().density); }
}
