package org.scholay.rimes.android;

import android.content.Context;
import android.graphics.Rect;
import android.view.View;
import android.view.ViewGroup;
import org.scholay.rimes.core.CandidateMatrix;
import java.util.ArrayList;
import java.util.List;

final class CandidateMatrixContract {
    static int run(Context context) {
        int checks=0;
        float density=context.getResources().getDisplayMetrics().density;
        for(int widthDp:new int[]{240,320,393,780}) {
            List<Integer> selected=new ArrayList<>();
            CandidateMatrixView view=new CandidateMatrixView(context,new CandidateMatrixView.Listener() {
                public void select(CandidateMatrix.Item item) { selected.add(item.index); }
                public void more() {}
            });
            List<CandidateMatrix.Item> items=new ArrayList<>();
            for(int i=0;i<60;i++) items.add(new CandidateMatrix.Item(9+i,i%7==0?"这是很长的候选词":"词"+i,i%3==0?"hint":""));
            view.update(items.subList(0,40),KeyboardTheme.ALL[0],true);
            int width=Math.round(widthDp*density),height=Math.round(104*density);
            layout(view,width,height);
            List<Rect> original=frames(view.candidateContent());
            for(int offset:new int[]{0,10,34,100,300,68,0}) {
                view.scrollTo(0,Math.round(offset*density)); layout(view,width,height);
                if(!original.equals(frames(view.candidateContent()))) throw new AssertionError("Scrolling repacked candidates");
                checks++;
            }
            view.scrollTo(0,Math.round(34*density)); int offset=view.getScrollY();
            view.update(items,KeyboardTheme.ALL[0],true); layout(view,width,height);
            if(!original.equals(frames(view.candidateContent()).subList(0,40)) || view.getScrollY()!=offset) throw new AssertionError("Appending moved existing candidates");
            view.candidateContent().getChildAt(17).performClick();
            if(!selected.equals(java.util.Collections.singletonList(26))) throw new AssertionError("Wrong absolute candidate selected");
            checks+=2;
        }
        return checks;
    }
    private static void layout(View view,int width,int height) {
        view.measure(View.MeasureSpec.makeMeasureSpec(width,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(height,View.MeasureSpec.EXACTLY));
        view.layout(0,0,width,height);
    }
    private static List<Rect> frames(ViewGroup group) {
        List<Rect> result=new ArrayList<>();
        for(int i=0;i<group.getChildCount();i++) { View child=group.getChildAt(i); result.add(new Rect(child.getLeft(),child.getTop(),child.getRight(),child.getBottom())); }
        return result;
    }
}
