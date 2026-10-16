package org.scholay.rimes.core;

import java.util.List;

/** Platform-local engine contract. All calls belong to the same serial worker. */
public interface RimeEngine {
    void initialize(String systemDirectory, String userDirectory);
    long createSession();
    void destroySession(long session);
    boolean selectSchema(long session, String schema);
    Snapshot processKey(long session, int key);
    Snapshot selectCandidate(long session, int index);
    Snapshot snapshot(long session);
    /** Read candidates without sending schema-dependent paging keys or learning. */
    default Snapshot candidateRange(long session,int start,int count) { throw new UnsupportedOperationException("Candidate enumeration unavailable"); }
    void clearComposition(long session);

    final class Snapshot {
        public static final Snapshot EMPTY = new Snapshot(false,"","",0,"",new String[0],new String[0],0,0,true);
        public final boolean handled;
        public final String raw, preedit, commit;
        public final int caret, pageStart, highlighted;
        public final List<String> candidates, comments;
        public final boolean lastPage;
        public Snapshot(boolean handled, String raw, String preedit, int caret, String commit,
                String[] candidates, String[] comments, int pageStart, int highlighted, boolean lastPage) {
            this.handled=handled; this.raw=raw; this.preedit=preedit; this.caret=caret; this.commit=commit;
            this.candidates=java.util.Collections.unmodifiableList(java.util.Arrays.asList(candidates.clone()));
            this.comments=java.util.Collections.unmodifiableList(java.util.Arrays.asList(comments.clone()));
            this.pageStart=pageStart; this.highlighted=highlighted; this.lastPage=lastPage;
        }
        public boolean composing() { return !raw.isEmpty() || !preedit.isEmpty(); }
    }
}
