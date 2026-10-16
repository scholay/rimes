package org.scholay.rimes.core;

import org.junit.Test;
import static org.junit.Assert.*;

public class CandidateMatrixTest {
    private static final class Engine implements RimeEngine {
        int page,failAt=-1;
        public void initialize(String a,String b) {} public long createSession() { return 1; }
        public void destroySession(long id) {} public boolean selectSchema(long id,String s) { return true; }
        public void clearComposition(long id) {} public Snapshot selectCandidate(long id,int index) { throw new AssertionError("Preview must not select or learn"); }
        public Snapshot snapshot(long id) {
            return new Snapshot(true,"shi","shi",3,"",new String[]{"候选"+(page*2),"候选"+(page*2+1)},new String[]{"注释",""},page*2,0,page==5);
        }
        public Snapshot processKey(long id,int key) { throw new AssertionError("Preview must not send schema paging keys"); }
        public Snapshot candidateRange(long id,int start,int count) {
            if(failAt>=0) throw new IllegalStateException("transport");
            int end=Math.min(12,start+count);
            String[] words=new String[end-start],comments=new String[end-start];
            for(int i=start;i<end;i++) { words[i-start]="候选"+i; comments[i-start]=i%2==0?"注释":""; }
            return new Snapshot(true,"shi","shi",3,"",words,comments,start,0,end==12);
        }
    }
    @Test public void previewRestoresAnchorAndAppendKeepsIndicesAndPrefix() {
        Engine engine=new Engine(); engine.page=1;
        RimeEngine.Snapshot anchor=engine.snapshot(1);
        CandidateMatrix.Preview first=CandidateMatrix.preview(engine,1,anchor,6);
        assertEquals(1,engine.page); assertFalse(first.lastPage);
        assertEquals(2,first.items.get(0).index); assertEquals(7,first.items.get(5).index);
        CandidateMatrix.Preview more=CandidateMatrix.preview(engine,1,anchor,20);
        assertTrue(more.lastPage); assertEquals(1,engine.page);
        assertEquals(first.items,more.items.subList(0,first.items.size()));
        assertEquals(11,more.items.get(more.items.size()-1).index);
    }
    @Test public void failedPreviewRestoresEngineBeforeAnotherKeyCanRun() {
        Engine engine=new Engine(); engine.failAt=3;
        try { CandidateMatrix.preview(engine,1,engine.snapshot(1),20); fail(); }
        catch(IllegalStateException expected) { assertEquals(0,engine.page); }
    }
    @Test public void staleAnchorCannotReadAnotherComposition() {
        Engine engine=new Engine(); RimeEngine.Snapshot anchor=engine.snapshot(1); engine.page=1;
        try { CandidateMatrix.preview(engine,1,anchor,6); fail(); }
        catch(IllegalStateException expected) { assertEquals(1,engine.page); }
    }
}
