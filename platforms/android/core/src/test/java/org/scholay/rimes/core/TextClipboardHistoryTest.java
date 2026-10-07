package org.scholay.rimes.core;

import java.util.List;
import java.nio.charset.StandardCharsets;
import org.junit.Test;
import static org.junit.Assert.*;

public class TextClipboardHistoryTest {
    @Test public void textIsVerbatimDeduplicatedAndIndividuallyRemovable() {
        TextClipboardHistory history=new TextClipboardHistory();
        String text=" \n中😀e\u0301\n "; assertTrue(history.collect(text));
        String id=history.entries().get(0).id; history.collect("other"); history.collect(text);
        assertEquals(2,history.entries().size()); assertEquals(text,history.entries().get(0).text);
        assertEquals(id,history.entries().get(0).id);
        TextClipboardHistory restored=new TextClipboardHistory(); assertTrue(restored.restore(history.entries()));
        history.remove(id); assertEquals("other",history.entries().get(0).text);
        history.clear(); assertTrue(history.entries().isEmpty()); assertEquals(2,restored.entries().size());
    }
    @Test public void rejectsEmptyAndLargeUtf8Atomically() {
        TextClipboardHistory history=new TextClipboardHistory(); history.collect("keep");
        assertFalse(history.collect(null)); assertFalse(history.collect("")); assertFalse(history.collect("字".repeat(6000)));
        assertEquals("keep",history.entries().get(0).text);
    }
    @Test public void countAndByteLimitsEvictTheOldest() {
        TextClipboardHistory history=new TextClipboardHistory();
        for(int i=0;i<60;i++) history.collect("item "+i);
        assertEquals(40,history.entries().size()); assertEquals("item 59",history.entries().get(0).text);
        for(int i=0;i<12;i++) history.collect(i+"x".repeat(16380));
        int bytes=history.entries().stream().mapToInt(e -> e.text.getBytes(StandardCharsets.UTF_8).length).sum();
        assertTrue(bytes<=TextClipboardHistory.MAX_BYTES); assertTrue(history.entries().get(0).text.startsWith("11"));
    }
    @Test public void malformedOrDuplicateRestoreCannotReplaceValidState() {
        TextClipboardHistory history=new TextClipboardHistory(); history.collect("keep");
        TextClipboardHistory.Entry entry=history.entries().get(0);
        assertFalse(history.restore(List.of(entry,entry))); assertFalse(history.restore(List.of(new TextClipboardHistory.Entry("bad","text"))));
        assertFalse(history.restore(List.of(new TextClipboardHistory.Entry(entry.id,""))));
        assertEquals("keep",history.entries().get(0).text);
        assertThrows(UnsupportedOperationException.class, () -> history.entries().clear());
    }
}
