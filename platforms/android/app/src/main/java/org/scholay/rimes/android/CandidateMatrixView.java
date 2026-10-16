package org.scholay.rimes.android;

import android.content.Context;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ScrollView;
import org.scholay.rimes.core.CandidateMatrix;
import java.util.ArrayList;
import java.util.List;

/** Stable content coordinates: scrolling never measures or repacks candidates. */
final class CandidateMatrixView extends ScrollView {
    interface Listener { void select(CandidateMatrix.Item item); void more(); }
    private final Flow content;
    private final Listener listener;
    private List<CandidateMatrix.Item> items=java.util.Collections.emptyList();
    private KeyboardTheme theme=KeyboardTheme.ALL[0];
    CandidateMatrixView(Context context,Listener listener) {
        super(context); this.listener=listener;
        setFillViewport(false); setVerticalScrollBarEnabled(false);
        content=new Flow(context); addView(content,new ScrollView.LayoutParams(-1,-2));
        setContentDescription("矩阵候选"); setTag("keyboard.candidates.matrix");
    }
    void update(List<CandidateMatrix.Item> next,KeyboardTheme theme,boolean enabled) {
        this.theme=theme;
        if(!items.equals(next)) {
            boolean appending=next.size()>=items.size() && next.subList(0,items.size()).equals(items);
            if(!appending) content.removeAllViews();
            items=new ArrayList<>(next);
            while(content.getChildCount()>items.size()) content.removeViewAt(content.getChildCount()-1);
            for(int i=0;i<items.size();i++) {
                final CandidateMatrix.Item item=items.get(i);
                KeyButton button;
                if(i<content.getChildCount()) button=(KeyButton)content.getChildAt(i);
                else {
                    button=new KeyButton(getContext()); button.plain(true); button.setTextSize(20);
                    button.setAutoSizeTextTypeWithDefaults(android.widget.TextView.AUTO_SIZE_TEXT_TYPE_NONE);
                    button.setPadding(dp(6),0,dp(6),0); button.setMinWidth(dp(32));
                    button.setEllipsize(android.text.TextUtils.TruncateAt.END);
                    content.addView(button,new ViewGroup.LayoutParams(-2,dp(32)));
                }
                button.candidate(item.text,item.comment);
                button.setContentDescription("候选"+(item.index+1)+" "+item.text);
                button.setOnClickListener(v -> { if(v.getParent()==content && items.contains(item)) listener.select(item); });
            }
            if(!appending) scrollTo(0,0);
            content.requestLayout();
        }
        for(int i=0;i<content.getChildCount();i++) {
            KeyButton button=(KeyButton)content.getChildAt(i); button.theme(theme); button.setEnabled(enabled);
        }
    }
    @Override protected void onScrollChanged(int x,int y,int oldX,int oldY) {
        super.onScrollChanged(x,y,oldX,oldY);
        if(y+getHeight()>=content.getHeight()-dp(64)) listener.more();
    }
    ViewGroup candidateContent() { return content; }
    private int dp(int value) { return Math.round(value*getResources().getDisplayMetrics().density); }
    private final class Flow extends ViewGroup {
        Flow(Context context) { super(context); }
        @Override protected void onMeasure(int widthSpec,int heightSpec) {
            int width=Math.max(1,MeasureSpec.getSize(widthSpec)),x=0,y=0,gap=dp(4),height=dp(32);
            for(int i=0;i<getChildCount();i++) {
                View child=getChildAt(i);
                child.measure(MeasureSpec.makeMeasureSpec(width,MeasureSpec.AT_MOST),MeasureSpec.makeMeasureSpec(height,MeasureSpec.EXACTLY));
                int w=child.getMeasuredWidth();
                if(x>0 && x+w>width) { x=0; y+=height+gap; }
                x+=w+gap;
            }
            setMeasuredDimension(width,getChildCount()==0?0:y+height);
        }
        @Override protected void onLayout(boolean changed,int left,int top,int right,int bottom) {
            int width=right-left,x=0,y=0,gap=dp(4),height=dp(32);
            for(int i=0;i<getChildCount();i++) {
                View child=getChildAt(i); int w=child.getMeasuredWidth();
                if(x>0 && x+w>width) { x=0; y+=height+gap; }
                child.layout(x,y,x+w,y+height); x+=w+gap;
            }
        }
    }
}
