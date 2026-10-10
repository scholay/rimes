package org.scholay.rimes.android;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.os.Looper;
import android.view.View;
import android.view.ViewGroup;
import android.view.accessibility.AccessibilityNodeInfo;
import android.widget.FrameLayout;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

/** Main-thread view contract; screen placement and real IME input are checked by testhost. */
final class KeyboardAppearanceContract {
    private int checks;
    private void check(boolean value,String message) { checks++; if(!value) throw new AssertionError(message); }
    static int run(Context context) {
        if(Looper.myLooper()!=Looper.getMainLooper()) throw new IllegalStateException("Appearance views require main");
        KeyboardAppearanceContract test=new KeyboardAppearanceContract();
        test.pet(context); test.chooser(context); return test.checks;
    }
    private void pet(Context context) {
        KeyButton pet=new KeyButton(context),blank=new KeyButton(context);
        int side=Math.round(36*context.getResources().getDisplayMetrics().density);
        FrameLayout petParent=fixture(context,pet,side,side),blankParent=fixture(context,blank,side,side);
        AtomicInteger cycles=new AtomicInteger(),choices=new AtomicInteger();
        KeyboardPetButton.configure(pet,cycles::incrementAndGet,choices::incrementAndGet);
        String id=KeyboardTheme.ALL[0].id;
        for(KeyboardTheme expected:KeyboardTheme.ALL) {
            check(KeyboardTheme.named(id)==expected,"cycle follows the same ordered pets as the chooser");
            KeyboardPetButton.render(pet,expected,false); blank.theme(expected);
            check(expected.glyph.contentEquals(pet.getText()),"actual pet text is the chosen glyph");
            check(("宠物与皮肤："+expected.title).contentEquals(pet.getContentDescription()),"pet has a matching native label");
            check(paintedContent(petParent,blankParent,side)>0,"the chosen pet is actually painted, not only an AX label");
            id=KeyboardTheme.next(id).id;
        }
        check(id.equals(KeyboardTheme.ALL[0].id),"the last pet wraps to the first skin");
        AccessibilityNodeInfo node=pet.createAccessibilityNodeInfo();
        try {
            // An unattached View skips the framework's native node flags/actions.
            // This node checks only our delegate's metadata; testhost checks the
            // actual IME-window accessibility actions before using its pet button.
            check("轻点切换宠物与皮肤；长按选择".contentEquals(node.getHintText()),"pet delegate supplies the exact gesture hint");
            check(pet.isClickable() && pet.isLongClickable(),"pet listeners retain native click and long-click capabilities");
        } finally { node.recycle(); }
        check(pet.performClick() && cycles.get()==1 && choices.get()==0,"tap cycles only once without opening settings");
        check(pet.performLongClick() && cycles.get()==1 && choices.get()==1,"long press chooses without cycling");
    }
    private static FrameLayout fixture(Context context,View child,int width,int height) {
        FrameLayout parent=new FrameLayout(context);
        parent.setLayoutParams(new ViewGroup.LayoutParams(width,height));
        parent.addView(child,new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,ViewGroup.LayoutParams.MATCH_PARENT));
        return parent;
    }
    private static void layout(FrameLayout parent,int width,int height) {
        parent.measure(View.MeasureSpec.makeMeasureSpec(width,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(height,View.MeasureSpec.EXACTLY));
        parent.layout(0,0,width,height);
    }
    private int paintedContent(FrameLayout pet,FrameLayout blank,int side) {
        Bitmap a=Bitmap.createBitmap(side,side,Bitmap.Config.ARGB_8888),b=Bitmap.createBitmap(side,side,Bitmap.Config.ARGB_8888);
        try {
            layout(pet,side,side); layout(blank,side,side);
            pet.draw(new Canvas(a)); blank.draw(new Canvas(b));
            int pixels=0; for(int y=0;y<side;y++) for(int x=0;x<side;x++) if(a.getPixel(x,y)!=b.getPixel(x,y)) pixels++;
            return pixels;
        } finally { a.recycle(); b.recycle(); }
    }
    private void chooser(Context context) {
        List<String> themes=new ArrayList<>(),layouts=new ArrayList<>(),schemas=new ArrayList<>();
        AtomicInteger dismiss=new AtomicInteger(),clear=new AtomicInteger(),paste=new AtomicInteger();
        KeyboardAppearancePanel panel=new KeyboardAppearancePanel(context,layouts::add,themes::add,dismiss::incrementAndGet);
        float density=context.getResources().getDisplayMetrics().density;
        int width=Math.round(360*density),height=Math.round(206*density);
        FrameLayout panelParent=fixture(context,panel,width,height);
        panel.schemes("rimes_pinyin",schemas::add);
        panel.action("清空 Buffer",context.getString(R.string.clear),clear::incrementAndGet);
        panel.action("粘贴剪贴板文字",context.getString(R.string.clipboard_paste),paste::incrementAndGet);
        panel.render("qwerty",KeyboardTheme.ALL[0]);
        layout(panelParent,width,height);
        check(visible(find(panel,"配色 原生")),"long-press chooser starts with actual pet choices");
        check(!visible(find(panel,"布局 26 键")),"layout is a distinct chooser page");
        for(KeyboardTheme theme:KeyboardTheme.ALL) {
            KeyButton tile=find(panel,"配色 "+theme.title);
            check((theme.glyph+" "+theme.title).contentEquals(tile.getText()),"every skin option includes its actual pet");
            tile.performClick(); check(themes.get(themes.size()-1).equals(theme.id),"pet choice reports the exact palette ID");
            panel.render("qwerty",theme); layout(panelParent,width,height); check(tile.isSelected(),"the selected pet is highlighted");
        }
        find(panel,"键位与方案").performClick();
        layout(panelParent,width,height);
        check(visible(find(panel,"布局 26 键")) && !visible(find(panel,"配色 原生")),"layout tab switches pages");
        find(panel,"布局 9 键").performClick(); check(layouts.equals(List.of("nineKey")),"nine-key choice remains reachable");
        find(panel,"中文方案 五笔").performClick(); check(schemas.equals(List.of("rimes_wubi")),"schema choice remains reachable");
        findText(panel,"清空 Buffer").performClick(); findText(panel,"粘贴剪贴板文字").performClick();
        check(clear.get()==1 && paste.get()==1,"removed rail buttons remain explicit panel actions");
        panel.showPets(); layout(panelParent,width,height); check(visible(find(panel,"配色 原生")),"a fresh open returns to pets");
        find(panel,"返回键盘").performClick(); check(dismiss.get()==1,"return closes the panel without changing skin");
    }
    private static boolean visible(View view) {
        for(View current=view;current!=null;current=current.getParent() instanceof View?(View)current.getParent():null)
            if(current.getVisibility()!=View.VISIBLE) return false;
        return true;
    }
    private static KeyButton find(View view,String description) { return find(view,description,true); }
    private static KeyButton findText(View view,String text) { return find(view,text,false); }
    private static KeyButton find(View view,String value,boolean description) {
        if(view instanceof KeyButton) {
            CharSequence label=description?view.getContentDescription():((KeyButton)view).getText();
            if(label!=null && value.contentEquals(label)) return (KeyButton)view;
        }
        if(view instanceof ViewGroup) for(int i=0;i<((ViewGroup)view).getChildCount();i++) {
            KeyButton found=find(((ViewGroup)view).getChildAt(i),value,description); if(found!=null) return found;
        }
        return null;
    }
}
