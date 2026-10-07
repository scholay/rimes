package org.scholay.rimes.android;

import android.app.Instrumentation;
import android.content.ContextWrapper;
import android.system.Os;
import java.io.File;
import java.nio.charset.StandardCharsets;
import org.scholay.rimes.core.TextClipboardHistory;

/** Synthetic filesystem coverage; does not read a real clipboard or touch saved history. */
final class TextClipboardStoreContract {
    static int run(Instrumentation test) throws Exception {
        File base=new File(test.getTargetContext().getNoBackupFilesDir(),"clipboard-test-"+java.util.UUID.randomUUID());
        ContextWrapper context=new ContextWrapper(test.getTargetContext()) { @Override public File getNoBackupFilesDir() { return base; } };
        try {
            TextClipboardStore store=new TextClipboardStore(context); TextClipboardHistory history=new TextClipboardHistory();
            history.collect(" \n中😀\n "); history.collect("second"); store.save(history.entries());
            check(store.load().size()==2 && store.load().get(1).text.equals(" \n中😀\n "),"verbatim reopen");
            File file=new File(base,"text-clipboard/history-v1.json");
            check((Os.stat(file.getAbsolutePath()).st_mode & 0777)==0600,"private file mode");
            check((Os.stat(file.getParent()).st_mode & 0777)==0700,"private directory mode");
            File backup=new File(file.getPath()+".bak");
            java.nio.file.Files.move(file.toPath(),backup.toPath());
            check(store.load().size()==2 && file.isFile() && !backup.exists(),"backup restored without base");
            java.nio.file.Files.copy(file.toPath(),backup.toPath());
            java.nio.file.Files.write(file.toPath(),"incomplete write".getBytes(StandardCharsets.UTF_8));
            check(store.load().size()==2 && !backup.exists(),"backup replaces incomplete base");
            history.remove(history.entries().get(0).id); store.save(history.entries()); check(store.load().size()==1,"delete entry");
            history.clear(); store.save(history.entries()); check(store.load().isEmpty(),"clear history");
            java.nio.file.Files.write(file.toPath(),"not json".getBytes(StandardCharsets.UTF_8)); check(store.load().isEmpty(),"corruption rejected");
            File outside=new File(base,"outside"); java.nio.file.Files.write(outside.toPath(),"untouched".getBytes(StandardCharsets.UTF_8));
            check(file.delete(),"remove fixture"); Os.symlink(outside.getAbsolutePath(),file.getAbsolutePath());
            check(store.load().isEmpty(),"symbolic read rejected");
            boolean denied=false; try { store.save(history.entries()); } catch(java.io.IOException expected) { denied=true; }
            check(denied,"symbolic write rejected");
            check(new String(java.nio.file.Files.readAllBytes(outside.toPath()),StandardCharsets.UTF_8).equals("untouched"),"outside file preserved");
            return 12;
        } finally { remove(base); }
    }
    private static void check(boolean value,String message) { if(!value) throw new AssertionError(message); }
    private static void remove(File file) {
        if(file.isDirectory() && !java.nio.file.Files.isSymbolicLink(file.toPath())) { File[] values=file.listFiles(); if(values!=null) for(File value:values) remove(value); }
        file.delete();
    }
}
