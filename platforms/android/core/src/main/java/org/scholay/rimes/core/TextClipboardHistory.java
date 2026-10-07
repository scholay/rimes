package org.scholay.rimes.core;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.UUID;

/** A bounded history of explicit text collections, never automatic observations. */
public final class TextClipboardHistory {
    public static final int MAX_ENTRIES=40, MAX_ENTRY_BYTES=16*1024, MAX_BYTES=128*1024;
    public static final class Entry {
        public final String id,text;
        public Entry(String id,String text) { this.id=id; this.text=text; }
    }
    private List<Entry> entries=new ArrayList<>();
    public List<Entry> entries() { return Collections.unmodifiableList(new ArrayList<>(entries)); }
    public boolean restore(List<Entry> saved) {
        if(saved==null || saved.size()>MAX_ENTRIES) return false;
        HashSet<String> ids=new HashSet<>(),texts=new HashSet<>(); int total=0;
        for(Entry entry:saved) {
            if(entry==null || !valid(entry.text) || !uuid(entry.id) || !ids.add(entry.id) || !texts.add(entry.text)) return false;
            total+=bytes(entry.text); if(total>MAX_BYTES) return false;
        }
        entries=new ArrayList<>(saved); return true;
    }
    public boolean collect(String text) {
        if(!valid(text)) return false;
        Entry selected=null;
        for(Entry entry:entries) if(entry.text.equals(text)) selected=entry;
        final String collected=text;
        entries.removeIf(entry -> entry.text.equals(collected));
        entries.add(0,selected==null?new Entry(UUID.randomUUID().toString(),text):selected);
        int total=0; for(Entry entry:entries) total+=bytes(entry.text);
        while(entries.size()>MAX_ENTRIES || total>MAX_BYTES) total-=bytes(entries.remove(entries.size()-1).text);
        return true;
    }
    public void remove(String id) { entries.removeIf(entry -> entry.id.equals(id)); }
    public void clear() { entries.clear(); }
    public static boolean valid(String text) { return text!=null && !text.isEmpty() && text.length()<=MAX_ENTRY_BYTES && bytes(text)<=MAX_ENTRY_BYTES; }
    private static int bytes(String text) { return text.getBytes(StandardCharsets.UTF_8).length; }
    private static boolean uuid(String id) { try { return UUID.fromString(id).toString().equals(id); } catch(RuntimeException invalid) { return false; } }
}
