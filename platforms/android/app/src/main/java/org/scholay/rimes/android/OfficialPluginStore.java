package org.scholay.rimes.android;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.AtomicFile;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;

/** Host-owned package verification, authorization and private storage. */
final class OfficialPluginStore {
    static final String PREFERENCES="official-plugins-v1";
    static final int LIMIT=256*1024;
    static final class Entry {
        final String id,legacyID,name,version,hash,asset,url,type;
        final boolean bundled;
        final JSONObject catalog;
        Entry(JSONObject value) throws Exception {
            catalog=value; id=value.getString("id"); name=value.getString("nameZH"); version=value.getString("version");
            hash=value.getString("sha256"); asset=value.getString("downloadAssetName"); url=value.getString("downloadURL");
            JSONObject adapter=value.getJSONObject("platforms").getJSONObject("android");
            legacyID=adapter.getString("legacyID"); bundled="bundled".equals(adapter.getString("distribution"));
            type=value.getJSONObject("contribution").getString("type");
            if(!id.matches("[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+") || !hash.matches("[0-9a-f]{64}")
                    || !asset.equals("preset-plugin-"+id+"-"+version+".json")) throw new IOException("Invalid catalog");
        }
    }
    static final class State {
        final String grant; final boolean installed,enabled,bundled;
        State(String grant,boolean installed,boolean enabled,boolean bundled) {
            this.grant=grant; this.installed=installed; this.enabled=enabled; this.bundled=bundled;
        }
    }
    private final Context context;
    private final File root;
    private final SharedPreferences preferences;
    private final List<Entry> entries=new ArrayList<>();
    OfficialPluginStore(Context context) {
        this.context=context.getApplicationContext();
        File base=this.context.getFilesDir();
        try { base=base.getCanonicalFile(); } catch(IOException ignored) { /* Path checks below fail closed. */ }
        root=new File(base,"official-plugins-v1");
        preferences=this.context.getSharedPreferences(PREFERENCES,Context.MODE_PRIVATE);
        synchronized(OfficialPluginStore.class) {
            if(!preferences.contains("migration")) {
                boolean legacy=!this.context.getSharedPreferences(KeyboardSettings.PREFERENCES_NAME,Context.MODE_PRIVATE).getAll().isEmpty();
                preferences.edit().putBoolean("legacy",legacy).putBoolean("migration",true).commit();
            }
        }
        try(InputStream input=this.context.getAssets().open("official-plugins/catalog.json")) {
            JSONObject catalog=new JSONObject(new String(read(input,1024*1024),StandardCharsets.UTF_8));
            if(catalog.getInt("schemaVersion")!=1) throw new IOException("Invalid catalog");
            JSONArray values=catalog.getJSONArray("plugins"); Set<String> ids=new HashSet<>();
            for(int i=0;i<values.length();i++) { Entry e=new Entry(values.getJSONObject(i)); if(!ids.add(e.id)) throw new IOException("Duplicate plugin"); entries.add(e); }
        } catch(Exception error) { entries.clear(); }
    }
    List<Entry> entries() { return Collections.unmodifiableList(entries); }
    Entry entry(String legacy) { for(Entry e:entries) if(e.legacyID.equals(legacy)) return e; return null; }
    State state(Entry entry) {
        if(entry==null) return new State("unavailable",false,false,false);
        String raw=preferences.getString("state."+entry.id,null);
        if(raw==null) { boolean available=entry.bundled || preferences.getBoolean("legacy",false); return new State("bundled-"+entry.hash,available,available,true); }
        try {
            JSONObject value=new JSONObject(raw);
            if(!entry.hash.equals(value.getString("sha256"))) throw new IOException("Changed package");
            return new State(value.getString("grant"),value.getBoolean("installed"),value.getBoolean("enabled"),value.getBoolean("bundled"));
        } catch(Exception error) { return new State("invalid",false,false,false); }
    }
    boolean enabled(String legacy) {
        Entry entry=entry(legacy); State state=state(entry);
        if(!state.installed || !state.enabled) return false;
        try { packageData(entry); return true; } catch(Exception error) { return false; }
    }
    String grant(String legacy) { return enabled(legacy)?state(entry(legacy)).grant:null; }
    JSONObject packageData(Entry entry) throws Exception {
        State state=state(entry);
        if(!state.installed) throw new IOException("请先安装插件");
        byte[] data;
        if(state.bundled) try(InputStream input=context.getAssets().open("official-plugins/"+entry.asset)) { data=read(input,LIMIT); }
        else try(InputStream input=new FileInputStream(file(entry))) { data=read(input,LIMIT); }
        return verify(entry,data);
    }
    String instruction(String legacy) throws Exception {
        Entry entry=entry(legacy);
        if(!enabled(legacy)) throw new IOException("请在官方插件中安装并启用");
        return packageData(entry).getJSONObject("contribution").getJSONObject("instructions").getString("default");
    }
    void setEnabled(Entry entry,boolean enabled) throws Exception {
        synchronized(OfficialPluginStore.class) {
            packageData(entry); State old=state(entry); write(entry,true,enabled,old.bundled);
        }
    }
    void uninstall(Entry entry) throws Exception {
        synchronized(OfficialPluginStore.class) {
            write(entry,false,false,false);
            File file=file(entry); if(file.exists() && !file.delete()) throw new IOException("无法移除插件内容");
        }
    }
    void install(Entry entry) throws Exception {
        String before=state(entry).grant; byte[] data;
        if(entry.bundled) try(InputStream input=context.getAssets().open("official-plugins/"+entry.asset)) { data=read(input,LIMIT); }
        else data=download(entry);
        installData(entry,data,before);
    }
    void installData(Entry entry,byte[] data,String expectedGrant) throws Exception {
        if(Thread.currentThread().isInterrupted()) throw new IOException("下载已取消");
        verify(entry,data);
        synchronized(OfficialPluginStore.class) {
            if(!state(entry).grant.equals(expectedGrant)) throw new IOException("插件状态已变化，请重试");
            File target=file(entry); if(!root.isDirectory() && !root.mkdirs()) throw new IOException("插件目录不可用");
            AtomicFile atomic=new AtomicFile(target); FileOutputStream output=null;
            try { output=atomic.startWrite(); output.write(data); atomic.finishWrite(output); }
            catch(Exception error) { if(output!=null) atomic.failWrite(output); throw error; }
            write(entry,true,false,false);
        }
    }
    private void write(Entry e,boolean installed,boolean enabled,boolean bundled) throws Exception {
        JSONObject state=new JSONObject().put("grant",UUID.randomUUID().toString()).put("installed",installed)
                .put("enabled",enabled).put("bundled",bundled).put("sha256",e.hash);
        if(!preferences.edit().putString("state."+e.id,state.toString()).commit()) throw new IOException("无法保存插件状态");
    }
    private File file(Entry entry) throws IOException {
        File target=new File(root,entry.id+".json");
        if(!root.getCanonicalFile().equals(root.getAbsoluteFile()) || !target.getCanonicalFile().equals(target.getAbsoluteFile())) throw new IOException("插件目录不可用");
        return target;
    }
    private JSONObject verify(Entry e,byte[] data) throws Exception {
        if(data.length>LIMIT) throw new IOException("插件内容过大");
        StringBuilder digest=new StringBuilder(); for(byte b:MessageDigest.getInstance("SHA-256").digest(data)) digest.append(String.format(Locale.ROOT,"%02x",b&255));
        if(!e.hash.equals(digest.toString())) throw new IOException("插件包校验失败");
        JSONObject value=new JSONObject(new String(data,StandardCharsets.UTF_8));
        String host=context.getPackageManager().getPackageInfo(context.getPackageName(),0).versionName;
        if(value.getInt("schemaVersion")!=2 || value.getInt("sdkVersion")!=1 || !"host-interpreted".equals(value.getString("runtime"))
                || !e.id.equals(value.getString("id")) || !e.version.equals(value.getString("version"))
                || !Arrays.asList("ai.prompt.v1","translation.v1","input.chord.v1").contains(e.type)
                || !e.type.equals(value.getJSONObject("contribution").getString("type"))
                || !e.catalog.getJSONArray("capabilities").toString().equals(value.getJSONArray("capabilities").toString())
                || compareVersion(host,value.getString("minimumHostVersion"))<0) throw new IOException("插件版本不兼容");
        return value;
    }
    static int compareVersion(String a,String b) throws IOException {
        if(a==null || b==null || !a.matches("(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)") || !b.matches("(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)")) throw new IOException("Invalid version");
        String[] left=a.split("\\."),right=b.split("\\.");
        try { for(int i=0;i<3;i++) { int result=Integer.compare(Integer.parseInt(left[i]),Integer.parseInt(right[i])); if(result!=0)return result; } }
        catch(NumberFormatException error) { throw new IOException("Invalid version",error); }
        return 0;
    }
    private byte[] download(Entry e) throws Exception {
        URL url=new URL(e.url);
        if(!"https".equals(url.getProtocol()) || !"github.com".equals(url.getHost()) || url.getUserInfo()!=null
                || !url.getPath().startsWith("/scholay/rimes-plugins/releases/download/v") || !url.getPath().endsWith("/"+e.asset)) throw new IOException("插件地址无效");
        for(int attempt=0;attempt<4;attempt++) {
            if(Thread.currentThread().isInterrupted()) throw new IOException("下载已取消");
            HttpURLConnection connection=(HttpURLConnection)url.openConnection();
            connection.setConnectTimeout(10000);connection.setReadTimeout(20000);connection.setInstanceFollowRedirects(false);
            try {
                int status=connection.getResponseCode();
                if(status>=300 && status<400) {
                    url=new URL(url,connection.getHeaderField("Location"));
                    if(!"https".equals(url.getProtocol()) || url.getUserInfo()!=null || !Arrays.asList("github.com","objects.githubusercontent.com","release-assets.githubusercontent.com").contains(url.getHost())) throw new IOException("下载重定向无效");
                    continue;
                }
                if(status!=200 || connection.getContentLengthLong()>LIMIT) throw new IOException("插件下载失败，请稍后重试");
                try(InputStream input=connection.getInputStream()) { return read(input,LIMIT); }
            } finally { connection.disconnect(); }
        }
        throw new IOException("下载重定向过多");
    }
    private static byte[] read(InputStream input,int limit) throws IOException {
        ByteArrayOutputStream output=new ByteArrayOutputStream(); byte[] buffer=new byte[8192];int count;
        while((count=input.read(buffer))!=-1) {
            if(Thread.currentThread().isInterrupted()) throw new IOException("下载已取消");
            if(output.size()+count>limit) throw new IOException("插件内容过大");output.write(buffer,0,count);
        }
        return output.toByteArray();
    }
}
