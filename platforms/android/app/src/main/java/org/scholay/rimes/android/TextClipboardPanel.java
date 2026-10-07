package org.scholay.rimes.android;

import android.content.Context;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.List;
import java.util.function.Consumer;
import org.scholay.rimes.core.TextClipboardHistory;

/** Explicit collection and local management, drawn inside the existing key surface. */
final class TextClipboardPanel extends LinearLayout {
    private final LinearLayout entries;
    private final TextView heading,note;
    private final KeyButton collect,clear,close;
    private List<TextClipboardHistory.Entry> shown=java.util.Collections.emptyList();
    private KeyboardTheme shownTheme;
    private boolean wasEnabled;
    private long presentation;
    private final Consumer<String> select,remove;
    TextClipboardPanel(Context context,Runnable capture,Consumer<String> select,Consumer<String> remove,Runnable clearAction,Runnable closeAction) {
        super(context); setOrientation(VERTICAL); this.select=select; this.remove=remove;
        heading=new TextView(context); heading.setText(R.string.clipboard_history); heading.setTextSize(16); heading.setPadding(dp(8),dp(6),dp(8),dp(2)); addView(heading);
        LinearLayout actions=new LinearLayout(context); addView(actions,new LayoutParams(-1,dp(40)));
        collect=button(actions,getResources().getString(R.string.clipboard_collect),capture,2);
        clear=button(actions,getResources().getString(R.string.clipboard_clear),clearAction,1);
        close=button(actions,getResources().getString(R.string.clipboard_close),closeAction,1);
        note=new TextView(context); note.setTextSize(12); note.setPadding(dp(8),dp(4),dp(8),dp(4)); addView(note);
        ScrollView scroll=new ScrollView(context); scroll.setFillViewport(true); addView(scroll,new LayoutParams(-1,0,1));
        entries=new LinearLayout(context); entries.setOrientation(VERTICAL); scroll.addView(entries);
    }
    void render(List<TextClipboardHistory.Entry> values,KeyboardTheme theme,boolean enabled) {
        setBackgroundColor(theme.palette(getContext()).background); heading.setTextColor(theme.palette(getContext()).ink); note.setTextColor(theme.palette(getContext()).ink);
        note.setText(values.isEmpty()?getResources().getString(R.string.clipboard_history_empty):getResources().getString(R.string.clipboard_history_hint));
        collect.theme(theme); clear.theme(theme); close.theme(theme); collect.setEnabled(enabled); clear.setEnabled(enabled && !values.isEmpty());
        boolean unchanged=theme==shownTheme && enabled==wasEnabled && values.size()==shown.size();
        for(int i=0;unchanged && i<values.size();i++) unchanged=values.get(i).id.equals(shown.get(i).id) && values.get(i).text.equals(shown.get(i).text);
        if(unchanged) return;
        shown=values; shownTheme=theme; wasEnabled=enabled; entries.removeAllViews();
        final long token=++presentation;
        for(TextClipboardHistory.Entry entry:values) {
            LinearLayout row=new LinearLayout(getContext()); entries.addView(row,new LayoutParams(-1,dp(58)));
            String preview=entry.text.length()>120?entry.text.substring(0,120)+"…":entry.text;
            KeyButton item=button(row,preview,() -> { if(token==presentation && wasEnabled) select.accept(entry.id); },1); item.setMaxLines(2); item.setSingleLine(false);
            item.setContentDescription(getResources().getString(R.string.clipboard_insert)+": "+preview); item.theme(theme); item.setEnabled(enabled);
            KeyButton delete=button(row,"×",() -> { if(token==presentation && wasEnabled) remove.accept(entry.id); },0); delete.getLayoutParams().width=dp(44);
            delete.setContentDescription(getResources().getString(R.string.clipboard_delete)); delete.theme(theme); delete.setEnabled(enabled);
        }
    }
    void redact() { presentation++; wasEnabled=false; entries.removeAllViews(); shown=java.util.Collections.emptyList(); note.setText(""); }
    private KeyButton button(LinearLayout row,String text,Runnable action,float weight) {
        KeyButton button=new KeyButton(getContext()); button.setText(text); button.font(13); button.setContentDescription(text);
        button.setOnClickListener(v -> action.run()); row.addView(button,new LayoutParams(weight==0?dp(44):0,-1,weight)); return button;
    }
    private int dp(int value) { return Math.round(value*getResources().getDisplayMetrics().density); }
}
