package org.scholay.rimes.core;

import org.junit.Test;
import static org.junit.Assert.*;

public class ExplicitClipboardImportTest {
    private BufferSession editing() {
        BufferSession buffer = new BufferSession();
        buffer.beginTarget(true); buffer.setEnabled(true); return buffer;
    }
    @Test public void explicitPastePreservesWhitespaceAndDoesNotConsumeExistingBlocks() {
        BufferSession buffer = editing(); buffer.appendCommittedBlock("保留");
        assertEquals(ExplicitClipboardImport.Outcome.IMPORTED,
                ExplicitClipboardImport.read(buffer, () -> true, () -> " \n字😀\n "));
        assertEquals("保留 \n字😀\n ", buffer.text()); assertEquals(2, buffer.blockCount());
    }
    @Test public void disabledAndPrivateBuffersNeverReadClipboard() {
        BufferSession buffer = editing();
        buffer.setEnabled(false);
        assertEquals(ExplicitClipboardImport.Outcome.UNAVAILABLE,
                ExplicitClipboardImport.read(buffer, () -> true, () -> { fail("must not read"); return ""; }));
        buffer.beginTarget(false);
        assertEquals(ExplicitClipboardImport.Outcome.UNAVAILABLE,
                ExplicitClipboardImport.read(buffer, () -> true, () -> { fail("must not read"); return ""; }));
        assertEquals(ExplicitClipboardImport.Outcome.UNAVAILABLE,
                ExplicitClipboardImport.read(editing(), () -> false, () -> { fail("must not read"); return ""; }));
    }
    @Test public void switchingTargetDuringReadCannotPasteIntoNewField() {
        BufferSession buffer = editing(); buffer.appendLiteral("旧");
        assertEquals(ExplicitClipboardImport.Outcome.CHANGED, ExplicitClipboardImport.read(buffer, () -> true, () -> {
            buffer.beginTarget(true); buffer.setEnabled(true); buffer.appendLiteral("新"); return "迟到";
        }));
        assertEquals("新", buffer.text());
    }
    @Test public void editsAndHideDuringReadRetireThePaste() {
        for (boolean hide : new boolean[]{false,true}) {
            BufferSession buffer = editing(); buffer.appendLiteral("保留");
            assertEquals(ExplicitClipboardImport.Outcome.CHANGED, ExplicitClipboardImport.read(buffer, () -> true, () -> {
                if (hide) buffer.finishTarget(); else buffer.appendLiteral("编辑"); return "迟到";
            }));
            assertEquals(hide ? "" : "保留编辑", buffer.text());
        }
    }
    @Test public void emptyAndOverCapacityReadsAreAtomic() {
        BufferSession buffer = editing(); buffer.appendLiteral("保留");
        assertEquals(ExplicitClipboardImport.Outcome.EMPTY, ExplicitClipboardImport.read(buffer, () -> true, () -> null));
        assertEquals(ExplicitClipboardImport.Outcome.TOO_LARGE, ExplicitClipboardImport.read(buffer, () -> true,
                () -> "x".repeat(BufferSession.MAX_CHARACTERS)));
        assertEquals("保留", buffer.text());
    }
}
