package org.scholay.rimes.android;

import android.content.Context;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Consumer;

/** The same layout/theme chooser is available in the keyboard and in Setup. */
final class KeyboardAppearancePanel extends ScrollView {
    private final List<KeyButton> themes=new ArrayList<>(),actions=new ArrayList<>();
    private final KeyButton qwerty,nine,chord,split;
    private final List<KeyButton> schemas=new ArrayList<>();
    private String schema="rimes_pinyin";
    private final TextView title,note;
    KeyboardAppearancePanel(Context context,Consumer<String> layout,Consumer<String> theme) {
        super(context); setFillViewport(true);
        LinearLayout column=new LinearLayout(context); column.setOrientation(LinearLayout.VERTICAL); addView(column);
        title=new TextView(context); title.setText("键位布局"); title.setTextSize(13); title.setPadding(dp(8),dp(8),0,dp(4)); column.addView(title);
        LinearLayout layouts=row(column);
        qwerty=button(layouts,"26 键 · QWERTY",() -> layout.accept("qwerty")); qwerty.setContentDescription("布局 26 键");
        nine=button(layouts,"9 键 · 拼音",() -> layout.accept("nineKey")); nine.setContentDescription("布局 9 键");
        LinearLayout chords=row(column);
        chord=button(chords,"并击 · 正交",() -> layout.accept("orthogonal")); chord.setContentDescription("布局 正交并击");
        split=button(chords,"并击 · 分体正交",() -> layout.accept("splitOrthogonal")); split.setContentDescription("布局 分体并击");
        note=new TextView(context); note.setText("配色 · 跟随系统浅色 / 深色"); note.setTextSize(13); note.setPadding(dp(8),dp(8),0,dp(4)); column.addView(note);
        LinearLayout current=null;
        for(int i=0;i<KeyboardTheme.ALL.length;i++) {
            if(i%3==0) current=row(column);
            KeyboardTheme option=KeyboardTheme.ALL[i];
            KeyButton item=button(current,option.title,() -> theme.accept(option.id));
            item.icon(KeyboardIcon.APPEARANCE,16,true); item.setContentDescription("配色 "+option.title); themes.add(item);
        }
    }
    void render(String layout,KeyboardTheme theme) {
        qwerty.setSelected(layout.equals("qwerty")); nine.setSelected(layout.equals("nineKey"));
        chord.setSelected(layout.equals("orthogonal")); split.setSelected(layout.equals("splitOrthogonal"));
        chord.theme(theme); split.theme(theme);
        for(int i=0;i<schemas.size();i++) { schemas.get(i).theme(theme); schemas.get(i).setSelected(schema.equals(new String[]{"rimes_pinyin","rimes_ziranma","rimes_wubi"}[i])); }
        qwerty.theme(theme); nine.theme(theme);
        for(KeyButton key:actions) key.theme(theme);
        title.setTextColor(theme.palette(getContext()).ink); note.setTextColor(theme.palette(getContext()).ink);
        for(int i=0;i<themes.size();i++) { KeyButton button=themes.get(i); button.theme(KeyboardTheme.ALL[i]); button.setSelected(KeyboardTheme.ALL[i]==theme); }
        setBackgroundColor(theme.palette(getContext()).background);
    }
    void schemes(String selected,Consumer<String> choose) {
        schema=selected;
        if(!schemas.isEmpty()) return;
        LinearLayout column=(LinearLayout)getChildAt(0);
        LinearLayout row=new LinearLayout(getContext()); column.addView(row,2,new LinearLayout.LayoutParams(-1,dp(40)));
        String[] ids={"rimes_pinyin","rimes_ziranma","rimes_wubi"},names={"拼音","自然码","五笔"};
        for(int i=0;i<ids.length;i++) { final String id=ids[i]; KeyButton key=button(row,names[i],() -> choose.accept(id)); key.setContentDescription("中文方案 "+names[i]); schemas.add(key); }
    }
    void action(String title,String description,Runnable perform) {
        LinearLayout column=(LinearLayout)getChildAt(0); KeyButton button=button(row(column),title,perform); button.setContentDescription(description); button.icon(description.equals(getResources().getString(R.string.switch_keyboard))?KeyboardIcon.GLOBE
                :description.equals(getResources().getString(R.string.insert_all))?KeyboardIcon.SEND_ALL
                :description.equals(getResources().getString(R.string.clipboard_paste))?KeyboardIcon.WRITE
                :description.equals(getResources().getString(R.string.clipboard_history))?KeyboardIcon.STACK_LAYERS:KeyboardIcon.CLEAR,18,true); actions.add(button);
    }
    private LinearLayout row(LinearLayout column) {
        LinearLayout row=new LinearLayout(getContext()); column.addView(row,new LinearLayout.LayoutParams(-1,dp(48))); return row;
    }
    private KeyButton button(LinearLayout row,String text,Runnable action) {
        KeyButton button=new KeyButton(getContext()); button.setText(text); button.font(14);
        button.setOnClickListener(v -> action.run()); row.addView(button,new LinearLayout.LayoutParams(0,-1,1)); return button;
    }
    private int dp(int value) { return Math.round(value*getResources().getDisplayMetrics().density); }
}
