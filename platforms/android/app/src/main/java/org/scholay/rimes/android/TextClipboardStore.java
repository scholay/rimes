package org.scholay.rimes.android;

import android.content.Context;
import android.system.Os;
import android.util.AtomicFile;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;
import org.scholay.rimes.core.TextClipboardHistory;

/** Keyboard-private, device-only records in Android's excluded-from-backup directory. */
final class TextClipboardStore {
    private final File directory,file;
    TextClipboardStore(Context context) {
        File base=context.getNoBackupFilesDir();
        try { base=base.getCanonicalFile(); } catch(IOException unavailable) { /* save fails closed below */ }
        directory=new File(base,"text-clipboard"); file=new File(directory,"history-v1.json");
    }
    List<TextClipboardHistory.Entry> load() {
        try {
            // openRead restores AtomicFile's backup before inspecting the bounded payload.
            if(!safe()) return java.util.Collections.emptyList();
            JSONObject archive=new JSONObject(new String(readLimited(),StandardCharsets.UTF_8));
            if(archive.getInt("version")!=1) return java.util.Collections.emptyList();
            JSONArray values=archive.getJSONArray("entries");
            if(values.length()>TextClipboardHistory.MAX_ENTRIES) return java.util.Collections.emptyList();
            List<TextClipboardHistory.Entry> entries=new ArrayList<>();
            for(int i=0;i<values.length();i++) { JSONObject entry=values.getJSONObject(i); entries.add(new TextClipboardHistory.Entry(entry.getString("id"),entry.getString("text"))); }
            TextClipboardHistory history=new TextClipboardHistory();
            return history.restore(entries)?history.entries():java.util.Collections.emptyList();
        } catch(Exception invalid) { return java.util.Collections.emptyList(); }
    }
    void save(List<TextClipboardHistory.Entry> entries) throws IOException {
        TextClipboardHistory bounded=new TextClipboardHistory();
        if(!bounded.restore(entries) || !safe()) throw new IOException("Clipboard storage unavailable");
        if(!directory.isDirectory() && !directory.mkdirs()) throw new IOException("Clipboard storage unavailable");
        AtomicFile atomic=new AtomicFile(file); FileOutputStream output=null;
        try {
            Os.chmod(directory.getAbsolutePath(),0700);
            JSONArray values=new JSONArray();
            for(TextClipboardHistory.Entry entry:entries) values.put(new JSONObject().put("id",entry.id).put("text",entry.text));
            byte[] data=new JSONObject().put("version",1).put("entries",values).toString().getBytes(StandardCharsets.UTF_8);
            output=atomic.startWrite(); Os.fchmod(output.getFD(),0600); output.write(data); atomic.finishWrite(output); output=null;
        } catch(Exception failure) { if(output!=null) atomic.failWrite(output); throw new IOException("Clipboard storage unavailable",failure); }
    }
    private boolean safe() throws IOException {
        if(!directory.getCanonicalFile().equals(directory.getAbsoluteFile())) return false;
        for(String suffix:new String[]{"", ".bak", ".new"}) {
            File path=new File(file.getPath()+suffix);
            if(!path.getCanonicalFile().equals(path.getAbsoluteFile())) return false;
        }
        return true;
    }
    private byte[] readLimited() throws IOException {
        try(java.io.FileInputStream input=new AtomicFile(file).openRead(); java.io.ByteArrayOutputStream output=new java.io.ByteArrayOutputStream()) {
            byte[] chunk=new byte[8192]; int count;
            while((count=input.read(chunk))!=-1) {
                if(output.size()+count>1024*1024) throw new IOException("Clipboard storage is too large");
                output.write(chunk,0,count);
            }
            return output.toByteArray();
        }
    }
}
