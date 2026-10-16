package org.scholay.rimes.core;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** Worker-only page preview. Absolute engine indices survive every visual row wrap. */
public final class CandidateMatrix {
    private CandidateMatrix() {}
    public static final class Item {
        public final int index;
        public final String text, comment;
        public Item(int index,String text,String comment) { this.index=index; this.text=text; this.comment=comment; }
        @Override public boolean equals(Object value) {
            if(!(value instanceof Item)) return false;
            Item other=(Item)value;
            return index==other.index && text.equals(other.text) && comment.equals(other.comment);
        }
        @Override public int hashCode() { return java.util.Objects.hash(index,text,comment); }
    }
    public static final class Preview {
        public final List<Item> items;
        public final boolean lastPage;
        Preview(List<Item> items,boolean lastPage) { this.items=Collections.unmodifiableList(items); this.lastPage=lastPage; }
    }
    public static List<Item> items(RimeEngine.Snapshot page) {
        List<Item> result=new ArrayList<>();
        for(int i=0;i<page.candidates.size();i++) result.add(new Item(page.pageStart+i,page.candidates.get(i),
                i<page.comments.size()?page.comments.get(i):""));
        return result;
    }
    public static Preview preview(RimeEngine engine,long session,RimeEngine.Snapshot anchor,int minimumCount) {
        RimeEngine.Snapshot page=engine.snapshot(session);
        if(!sameComposition(page,anchor) || page.pageStart!=anchor.pageStart) throw new IllegalStateException("Stale candidate preview");
        RimeEngine.Snapshot range=engine.candidateRange(session,anchor.pageStart,minimumCount);
        if(!sameComposition(range,anchor) || range.pageStart!=anchor.pageStart) throw new IllegalStateException("Stale candidate enumeration");
        return new Preview(items(range),range.lastPage);
    }
    private static boolean sameComposition(RimeEngine.Snapshot a,RimeEngine.Snapshot b) {
        return a.raw.equals(b.raw) && a.caret==b.caret && a.commit.isEmpty();
    }
}
