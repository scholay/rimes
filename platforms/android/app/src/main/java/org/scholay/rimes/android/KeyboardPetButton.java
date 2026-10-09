package org.scholay.rimes.android;

import android.view.View;
import android.view.accessibility.AccessibilityNodeInfo;

/** A visible static pet, with native tap and long-press actions. */
final class KeyboardPetButton {
    private KeyboardPetButton() {}
    static void configure(KeyButton button,Runnable cycle,Runnable choose) {
        button.icon(null); button.fontStyle(false,24,false);
        button.setOnClickListener(view -> cycle.run());
        button.setOnLongClickListener(view -> { choose.run(); return true; });
        button.setTooltipText("轻点切换宠物与皮肤；长按选择");
        button.setAccessibilityDelegate(new View.AccessibilityDelegate() {
            @Override public void onInitializeAccessibilityNodeInfo(View host,AccessibilityNodeInfo info) {
                super.onInitializeAccessibilityNodeInfo(host,info);
                info.setHintText("轻点切换宠物与皮肤；长按选择");
            }
        });
    }
    static void render(KeyButton button,KeyboardTheme theme,boolean choosing) {
        if(!android.text.TextUtils.equals(button.getText(),theme.glyph)) button.setText(theme.glyph);
        button.icon(null); button.theme(theme); button.setSelected(choosing);
        String description="宠物与皮肤："+theme.title;
        if(!android.text.TextUtils.equals(button.getContentDescription(),description)) button.setContentDescription(description);
    }
}
