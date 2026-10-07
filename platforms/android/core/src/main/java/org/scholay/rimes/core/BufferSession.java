package org.scholay.rimes.core;

import java.util.ArrayList;
import java.util.List;

/** An ephemeral, target-bound queue. No text is persisted or sent automatically. */
public final class BufferSession {
    public static final int MAX_CHARACTERS = 16 * 1024;
    private final List<String> blocks = new ArrayList<>();
    private final List<Boolean> committed = new ArrayList<>();
    private long target;
    private long revision;
    private boolean permitted;
    private boolean enabled;
    private long projectionRevision=-1;
    private String projectedText="";
    private List<String> projectedBlocks=java.util.Collections.emptyList();

    public void beginTarget(boolean allowBuffer) {
        target++;
        permitted = allowBuffer;
        enabled = false;
        clear();
    }

    public void finishTarget() { beginTarget(false); }
    public boolean isPermitted() { return permitted; }
    public boolean isEnabled() { return enabled; }
    public int blockCount() { return blocks.size(); }
    public List<String> blocks() { updateProjection(); return projectedBlocks; }
    public String text() { updateProjection(); return projectedText; }
    private void updateProjection() {
        if(projectionRevision==revision) return;
        projectedText=String.join("",blocks);
        projectedBlocks=java.util.Collections.unmodifiableList(new ArrayList<>(blocks));
        projectionRevision=revision;
    }

    public boolean setEnabled(boolean value) {
        if (value && !permitted) return false;
        enabled = value;
        revision++;
        return true;
    }

    public void clear() {
        blocks.clear(); committed.clear(); revision++;
        projectedText=""; projectedBlocks=java.util.Collections.emptyList(); projectionRevision=revision;
    }

    /** One Rime confirmation is an immutable block boundary, including non-BMP text. */
    public boolean appendCommittedBlock(String text) {
        if (!enabled || !permitted || text == null || text.isEmpty()
                || text().length() + text.length() > MAX_CHARACTERS) return false;
        blocks.add(text); committed.add(true); revision++; return true;
    }

    /** Literal English forms words; separators remain verbatim attached to the previous word. */
    public boolean appendLiteral(String text) {
        if (!enabled || !permitted || text == null || text.isEmpty()) return false;
        if (text().length() + text.length() > MAX_CHARACTERS) return false;
        for (int offset = 0; offset < text.length();) {
            int codePoint = text.codePointAt(offset);
            String part = new String(Character.toChars(codePoint));
            offset += Character.charCount(codePoint);
            int last = blocks.size() - 1;
            if (last < 0 || committed.get(last)) {
                blocks.add(part); committed.add(false);
            } else {
                String previous = blocks.get(last);
                int tail = previous.codePointBefore(previous.length());
                if (Character.isLetterOrDigit(codePoint) && !Character.isLetterOrDigit(tail)) {
                    blocks.add(part); committed.add(false);
                } else {
                    blocks.set(last, previous + part);
                }
            }
        }
        revision++;
        return true;
    }

    public void deleteLastBlock() {
        if (!enabled || blocks.isEmpty()) return;
        committed.remove(blocks.size() - 1);
        blocks.remove(blocks.size() - 1);
        revision++;
    }

    public Delivery prepare(boolean all) {
        if (!enabled || !permitted || blocks.isEmpty()) return null;
        int count = all ? blocks.size() : 1;
        return new Delivery(this, target, revision, String.join("", blocks.subList(0, count)), count);
    }

    public boolean isCurrent(Delivery delivery) {
        return delivery != null && delivery.owner == this && enabled && permitted
                && delivery.target == target && delivery.revision == revision;
    }

    /** Call only after commitText accepted this exact, still-current delivery. */
    public boolean acknowledge(Delivery delivery) {
        if (!isCurrent(delivery)) return false;
        blocks.subList(0, delivery.count).clear();
        committed.subList(0, delivery.count).clear();
        revision++;
        return true;
    }

    /** Freeze the complete source for one plugin request; it never changes with later edits. */
    public Capture capture() {
        if (!enabled || !permitted || blocks.isEmpty()) return null;
        return new Capture(this, target, revision, text());
    }

    /** A paste lease can start from an empty Buffer; edits, hides and targets retire it. */
    public Import prepareImport() {
        return enabled && permitted ? new Import(this, target, revision) : null;
    }

    public boolean isCurrent(Import request) {
        return request != null && request.owner == this && enabled && permitted
                && request.target == target && request.revision == revision;
    }

    public boolean appendImported(Import request, String text) {
        return isCurrent(request) && appendCommittedBlock(text);
    }

    public static final class Import {
        private final BufferSession owner;
        private final long target, revision;
        private Import(BufferSession owner, long target, long revision) {
            this.owner = owner; this.target = target; this.revision = revision;
        }
    }

    public boolean isCurrent(Capture capture) {
        return capture != null && capture.owner == this && enabled && permitted
                && capture.target == target && capture.revision == revision;
    }

    /** Consume the source only after the complete generated output was accepted by the host. */
    public boolean acknowledge(Capture capture) {
        if (!isCurrent(capture)) return false;
        clear();
        return true;
    }

    public static final class Capture {
        private final BufferSession owner;
        public final long target;
        public final long revision;
        public final String text;
        private Capture(BufferSession owner, long target, long revision, String text) {
            this.owner = owner;
            this.target = target;
            this.revision = revision;
            this.text = text;
        }
    }

    public static final class Delivery {
        private final BufferSession owner;
        private final long target;
        private final long revision;
        private final int count;
        public final String text;
        private Delivery(BufferSession owner, long target, long revision, String text, int count) {
            this.owner = owner;
            this.target = target;
            this.revision = revision;
            this.text = text;
            this.count = count;
        }
    }
}
