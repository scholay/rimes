package org.scholay.rimes.android;

import android.content.Context;
import android.view.Gravity;
import android.view.View;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;

/** iOS-sized plugin entries occupying the idle candidate slot; actions belong to the service. */
final class PluginShortcutBar extends HorizontalScrollView {
    interface Listener {
        void onPluginTap(String id);
        void onPluginLongPress(String id);
    }

    private static final String[] IDS={"translate","ask","polish","poem","art"};
    private static final String[] LABELS={"翻译","快问","润色","作诗","画画"};
    private static final KeyboardIcon[] ICONS={KeyboardIcon.TRANSLATE,KeyboardIcon.CHAT_QUESTION,
            KeyboardIcon.MAGIC_WAND,KeyboardIcon.BOOK,KeyboardIcon.GRID_9};
    private final KeyButton[] buttons=new KeyButton[IDS.length];

    PluginShortcutBar(Context context,KeyboardTheme theme,Listener listener) {
        super(context);
        if(listener==null) throw new IllegalArgumentException("Plugin listener is required");
        setFillViewport(true); setHorizontalScrollBarEnabled(false); setOverScrollMode(View.OVER_SCROLL_NEVER);
        setPadding(0,0,0,0); setMinimumHeight(dp(32));
        LinearLayout row=new LinearLayout(context);
        row.setOrientation(LinearLayout.HORIZONTAL); row.setGravity(Gravity.CENTER);
        addView(row,new HorizontalScrollView.LayoutParams(LayoutParams.WRAP_CONTENT,dp(32)));
        for(int i=0;i<buttons.length;i++) {
            final String id=IDS[i];
            KeyButton button=new KeyButton(context);
            button.setText(LABELS[i]); button.setContentDescription("Buffer 插件："+LABELS[i]);
            button.fontStyle(false,13,true); button.appearance(true,true,true); button.shortcut(true);
            button.icon(ICONS[i],12,true); button.theme(theme);
            button.setOnClickListener(view -> { if(button.isEnabled()) listener.onPluginTap(id); });
            button.setOnLongClickListener(view -> {
                if(button.isEnabled()) listener.onPluginLongPress(id);
                return true;
            });
            LinearLayout.LayoutParams cell=new LinearLayout.LayoutParams(dp(68),dp(30));
            if(i<buttons.length-1) cell.rightMargin=dp(6);
            row.addView(button,cell); buttons[i]=button;
        }
    }

    /** Keeps entries and scroll position stable while updating selection, availability and colors. */
    void render(KeyboardTheme theme,String selectedID,boolean enabled) {
        render(theme,selectedID,enabled,id -> true);
    }
    void render(KeyboardTheme theme,String selectedID,boolean available,java.util.function.Predicate<String> installed) {
        for(int i=0;i<buttons.length;i++) {
            KeyButton button=buttons[i];
            boolean enabled=available && installed.test(IDS[i]);
            button.theme(theme);
            boolean selected=IDS[i].equals(selectedID);
            if(button.isSelected()!=selected) button.setSelected(selected);
            if(button.isEnabled()!=enabled) {
                if(!enabled) { button.cancelLongPress(); button.setPressed(false); }
                button.setEnabled(enabled);
            }
        }
    }

    private int dp(float value) { return Math.round(value*getResources().getDisplayMetrics().density); }
}
