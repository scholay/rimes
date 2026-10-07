package org.scholay.rimes.core;

import java.util.function.BooleanSupplier;
import java.util.function.Supplier;

/** One explicit text read, never a listener or an automatic host insertion. */
public final class ExplicitClipboardImport {
    public enum Outcome { UNAVAILABLE, CHANGED, EMPTY, TOO_LARGE, IMPORTED }
    private ExplicitClipboardImport() {}

    public static Outcome read(BufferSession buffer, BooleanSupplier allowed, Supplier<CharSequence> reader) {
        BufferSession.Import request = buffer.prepareImport();
        if (request == null || !allowed.getAsBoolean()) return Outcome.UNAVAILABLE;
        CharSequence source = reader.get();
        if (!allowed.getAsBoolean() || !buffer.isCurrent(request)) return Outcome.CHANGED;
        if (source == null || source.length() == 0) return Outcome.EMPTY;
        if (source.length() > BufferSession.MAX_CHARACTERS - buffer.text().length()) return Outcome.TOO_LARGE;
        // Take a bounded, immutable copy only after revalidating the editor and draft.
        String text = source.toString();
        return buffer.appendImported(request, text) ? Outcome.IMPORTED : Outcome.CHANGED;
    }
}
