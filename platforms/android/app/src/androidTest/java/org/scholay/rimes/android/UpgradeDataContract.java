package org.scholay.rimes.android;

import android.app.Instrumentation;
import android.content.Context;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.Map;
import java.util.TreeMap;
import org.json.JSONObject;

/** Quiescent production upgrade evidence. Hashes stay private and no dictionary text is logged. */
final class UpgradeDataContract {
    private static final String BASELINE="upgrade-user-dictionary-baseline.json";
    static String run(Instrumentation instrumentation,boolean verify) throws Exception {
        Context context=instrumentation.getTargetContext();
        File baseline=new File(context.getNoBackupFilesDir(),BASELINE);
        Map<String,String> actual=new TreeMap<>();
        File root=new File(context.getNoBackupFilesDir(),"rime-user");
        collect(root,root,actual);
        if(!verify) {
            if(baseline.exists()) throw new IllegalStateException("Restore or verify the previous baseline first");
            JSONObject saved=new JSONObject().put("package",context.getPackageName()).put("files",new JSONObject(actual));
            Files.write(baseline.toPath(),saved.toString().getBytes(StandardCharsets.UTF_8));
            return "PASS private upgrade dictionary baseline files="+actual.size()+"\n";
        }
        JSONObject saved=new JSONObject(new String(Files.readAllBytes(baseline.toPath()),StandardCharsets.UTF_8));
        if(!context.getPackageName().equals(saved.getString("package"))) throw new AssertionError("Upgrade baseline package mismatch");
        JSONObject expected=saved.getJSONObject("files");
        if(actual.size()!=expected.length()) throw new AssertionError("Upgrade dictionary file count changed");
        for(Map.Entry<String,String> item:actual.entrySet())
            if(!item.getValue().equals(expected.optString(item.getKey()))) throw new AssertionError("Upgrade dictionary bytes changed");
        if(!baseline.delete()) throw new AssertionError("Cannot remove verified private baseline");
        return "PASS upgrade user dictionary bytes preserved files="+actual.size()+"\n";
    }
    private static void collect(File root,File file,Map<String,String> files) throws Exception {
        if(!file.exists()) return;
        if(Files.isSymbolicLink(file.toPath())) throw new IllegalStateException("Upgrade evidence refuses symbolic links");
        if(file.isDirectory()) {
            File[] children=file.listFiles();
            if(children==null) throw new IllegalStateException("Cannot enumerate upgrade dictionary");
            for(File child:children) collect(root,child,files);
        } else {
            byte[] hash=MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(file.toPath()));
            StringBuilder text=new StringBuilder();
            for(byte value:hash) text.append(String.format(java.util.Locale.ROOT,"%02x",value&255));
            files.put(root.toPath().relativize(file.toPath()).toString(),text.toString());
        }
    }
}
