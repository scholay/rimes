package org.scholay.rimes.android;

import android.content.Context;
import android.content.ContextWrapper;
import android.content.SharedPreferences;
import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.util.*;

/** Real assets and Keystore with isolated files/preferences; never mutates an installed profile. */
final class PluginTestContext extends ContextWrapper implements AutoCloseable {
    private final String prefix="plugin-contract-"+UUID.randomUUID()+"-";
    private final File files;
    private final Set<String> preferences=new HashSet<>();
    PluginTestContext(Context base,boolean legacy) throws IOException {
        super(base); files=Files.createTempDirectory(base.getCacheDir().toPath(),prefix).toFile();
        if(legacy) getSharedPreferences(KeyboardSettings.PREFERENCES_NAME,MODE_PRIVATE).edit().putString("schema","rimes_pinyin").commit();
    }
    @Override public Context getApplicationContext() { return this; }
    @Override public File getFilesDir() { return files; }
    @Override public SharedPreferences getSharedPreferences(String name,int mode) {
        preferences.add(prefix+name); return getBaseContext().getSharedPreferences(prefix+name,mode);
    }
    @Override public void close() throws IOException {
        for(String name:preferences) getBaseContext().deleteSharedPreferences(name);
        try(java.util.stream.Stream<java.nio.file.Path> paths=Files.walk(files.toPath())) {
            for(java.nio.file.Path path:paths.sorted(Comparator.reverseOrder()).toArray(java.nio.file.Path[]::new)) Files.deleteIfExists(path);
        }
    }
}
