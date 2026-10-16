package org.scholay.rimes.android;

import org.scholay.rimes.core.RimeEngine;

final class NativeRimeEngine implements RimeEngine {
    static { System.loadLibrary("rimes_jni"); }
    public void initialize(String system, String user) { initializeNative(system,user); }
    public long createSession() { return createNative(); }
    public void destroySession(long session) { if(session!=0) destroyNative(session); }
    public boolean selectSchema(long session,String schema) { return schemaNative(session,schema); }
    public Snapshot processKey(long session,int key) { return snapshotNative(session,keyNative(session,key)); }
    public Snapshot selectCandidate(long session,int index) { return snapshotNative(session,selectNative(session,index)); }
    public Snapshot candidateRange(long session,int start,int count) { return candidatesNative(session,start,count); }
    private static native Snapshot candidatesNative(long session,int start,int count);
    public Snapshot snapshot(long session) { return snapshotNative(session,false); }
    public void clearComposition(long session) { clearNative(session); }
    private static native void initializeNative(String system,String user);
    private static native long createNative();
    private static native void destroyNative(long session);
    private static native boolean schemaNative(long session,String schema);
    private static native boolean keyNative(long session,int key);
    private static native boolean selectNative(long session,int index);
    private static native void clearNative(long session);
    private static native Snapshot snapshotNative(long session,boolean handled);
    static native String roundTripNative(String text);
    /** Import process only; null means every requested schema deployed and loaded. */
    static native String deployNative(String root,String[] schemas);
}
