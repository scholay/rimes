package org.scholay.rimes.android;

import android.app.Instrumentation;
import android.content.Context;
import android.content.SharedPreferences;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.cert.Certificate;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import javax.net.ssl.HttpsURLConnection;
import org.json.JSONObject;

/** Fake connections for failure policy; real provider traffic is a separate, explicit live mode. */
final class NetworkAiContract {
    private static final String ENDPOINT=OpenAiSettings.DEFAULT_BASE_URL+"/chat/completions";
    private static final String TEST_KEY="synthetic-test-credential";
    private static final String WIRE="data: {\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"你好 😀\"},\"finish_reason\":null}]}\n\n"
            +"data: {\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
            +"data: [DONE]\n\n";
    private int checks;
    private void check(boolean value,String label) { checks++; if(!value) throw new AssertionError(label); }
    static int run(Instrumentation instrumentation) throws Exception {
        NetworkAiContract test=new NetworkAiContract();
        test.requests(); test.transport(); test.cancellation(); try(PluginTestContext context=new PluginTestContext(instrumentation.getTargetContext(),true)) { test.storage(context); }
        return test.checks;
    }
    private void requests() throws Exception {
        JSONObject ask=request("ask","你好😀","auto");
        check(ask.getBoolean("stream") && ask.getInt("max_tokens")==2048,"bounded streaming request");
        check("disabled".equals(ask.getJSONObject("thinking").getString("type")),"DeepSeek thinking disabled");
        check("你好😀".equals(ask.getJSONArray("messages").getJSONObject(1).getString("content")),"source Unicode preserved");
        check(!ask.toString().contains(TEST_KEY),"request JSON never holds credential");
        check(request("translate","你好","auto").toString().contains("into English"),"auto Chinese to English");
        check(request("translate","hello","auto").toString().contains("into Simplified Chinese"),"auto English to Chinese");
        check(request("translate","hello","zh-en").toString().contains("into English"),"explicit direction");
        try { request("translate","text","invalid"); throw new AssertionError("direction accepted"); }
        catch(OpenAiChatCodec.Failure e) { check(e.code==OpenAiChatCodec.Code.INVALID_DIRECTION,"bad direction rejected"); }
    }
    private JSONObject request(String plugin,String text,String direction) throws Exception {
        return new JSONObject(new String(OpenAiChatCodec.makeRemoteRequest(plugin,text,OpenAiSettings.DEFAULT_MODEL,direction),StandardCharsets.UTF_8));
    }
    private void transport() throws Exception {
        FakeConnection connection=new FakeConnection(200,"text/event-stream; charset=utf-8");
        AtomicInteger calls=new AtomicInteger();
        PluginCancellation token=new PluginCancellation();
        OpenAiChatCodec.Decoder decoder=new OpenAiChatCodec.Decoder(token,(text,complete) -> {});
        byte[] body=OpenAiChatCodec.makeRemoteRequest("ask","hello",OpenAiSettings.DEFAULT_MODEL,"auto");
        new HttpOpenAiTransport(url -> { calls.incrementAndGet(); check(ENDPOINT.equals(url.toString()),"configured HTTPS recipient"); return connection; })
                .stream(ENDPOINT,body,TEST_KEY,token,decoder::append);
        check("你好 😀".equals(decoder.finish()),"real transport boundary decodes complete SSE");
        check(calls.get()==1 && connection.disconnected,"one connection closed");
        check(!connection.getInstanceFollowRedirects() && !connection.getUseCaches(),"redirect and disk cache disabled");
        check(("Bearer "+TEST_KEY).equals(connection.getRequestProperty("Authorization")),"Bearer header");
        check(java.util.Arrays.equals(body,connection.output.toByteArray()),"exact UTF8 request bytes");
        String custom="https://compatible.example.test/custom/v1/chat/completions";
        new HttpOpenAiTransport(url -> { check(custom.equals(url.toString()),"custom path reaches the transport unchanged"); return new FakeConnection(200,"text/event-stream"); })
                .stream(custom,body,TEST_KEY,new PluginCancellation(),(b,o,n) -> {});
        for(String invalid:new String[]{"http://example.com/v1","https://user:pass@example.com","https://example.com?q=key","https://example.com/#part","file:///tmp/key","https://example.com/a/../b"}) {
            try { new HttpOpenAiTransport(url -> { throw new AssertionError("invalid address connected"); }).stream(invalid,body,TEST_KEY,new PluginCancellation(),(b,o,n) -> {}); throw new AssertionError("invalid address accepted"); }
            catch(OpenAiChatCodec.Failure expected) { check(expected.code==OpenAiChatCodec.Code.NOT_CONFIGURED,"invalid URL blocked before credential transmission"); }
        }
        for(int status:new int[]{301,302,307,401,403,429,500}) {
            FakeConnection failed=new FakeConnection(status,"application/json");
            try { new HttpOpenAiTransport(url -> failed).stream(ENDPOINT,body,TEST_KEY,new PluginCancellation(),(b,o,n) -> { throw new AssertionError("error body delivered"); }); throw new AssertionError("HTTP error accepted"); }
            catch(OpenAiChatCodec.Failure e) {
                check(e.code==OpenAiChatCodec.Code.HTTP_ERROR,"HTTP error typed "+status);
                check(!e.getMessage().contains(TEST_KEY) && failed.reads==0 && failed.disconnected,"HTTP body stays private "+status);
            }
        }
        try { new HttpOpenAiTransport(url -> new FakeConnection(200,"application/json")).stream(ENDPOINT,body,TEST_KEY,new PluginCancellation(),(b,o,n) -> {}); throw new AssertionError("JSON accepted as SSE"); }
        catch(OpenAiChatCodec.Failure e) { check(e.code==OpenAiChatCodec.Code.INVALID_FRAME,"wrong content type rejected"); }
        try { new HttpOpenAiTransport(url -> { throw new java.io.IOException(TEST_KEY); }).stream(ENDPOINT,body,TEST_KEY,new PluginCancellation(),(b,o,n) -> {}); throw new AssertionError("IO error accepted"); }
        catch(OpenAiChatCodec.Failure e) { check(e.code==OpenAiChatCodec.Code.NETWORK_ERROR && !e.getMessage().contains(TEST_KEY),"network exception redacted"); }
        FakeConnection region=new FakeConnection(403,"application/json") {
            @Override public InputStream getErrorStream() {
                return new ByteArrayInputStream(("{\"error\":{\"code\":\"region_restricted\",\"message\":\""+TEST_KEY+"\"}}").getBytes(StandardCharsets.UTF_8));
            }
        };
        try { new HttpOpenAiTransport(url -> region).stream(ENDPOINT,body,TEST_KEY,new PluginCancellation(),(b,o,n) -> {}); throw new AssertionError("region accepted"); }
        catch(OpenAiChatCodec.Failure e) { check(e.getMessage().contains("当前地区") && !e.getMessage().contains(TEST_KEY),"region error actionable without provider-message disclosure"); }
    }
    private void cancellation() throws Exception {
        PluginCancellation early=new PluginCancellation(); early.cancel();
        try { new HttpOpenAiTransport(url -> { throw new AssertionError("cancelled request connected"); }).stream(ENDPOINT,new byte[0],TEST_KEY,early,(b,o,n) -> {}); throw new AssertionError("cancellation ignored"); }
        catch(PluginCancellation.Cancelled expected) { check(true,"cancel before connection"); }
        CountDownLatch reading=new CountDownLatch(1),disconnectSignal=new CountDownLatch(1),finished=new CountDownLatch(1);
        FakeConnection connection=new FakeConnection(200,"text/event-stream") {
            @Override public InputStream getInputStream() {
                return new InputStream() { @Override public int read() throws java.io.IOException {
                    reading.countDown(); try { disconnectSignal.await(3,TimeUnit.SECONDS); }
                    catch(InterruptedException e) { Thread.currentThread().interrupt(); }
                    throw new java.io.IOException("cancelled");
                }};
            }
            @Override public void disconnect() { super.disconnect(); disconnectSignal.countDown(); }
        };
        PluginCancellation token=new PluginCancellation(); AtomicReference<Throwable> unexpected=new AtomicReference<>();
        Thread worker=new Thread(() -> {
            try { new HttpOpenAiTransport(url -> connection).stream(ENDPOINT,new byte[0],TEST_KEY,token,(b,o,n) -> {}); unexpected.set(new AssertionError("cancel completed")); }
            catch(PluginCancellation.Cancelled expected) { /* No completion or failure callback. */ }
            catch(Throwable e) { unexpected.set(e); }
            finally { finished.countDown(); }
        }); worker.start();
        check(reading.await(2,TimeUnit.SECONDS),"read in flight"); token.cancel();
        check(finished.await(2,TimeUnit.SECONDS) && unexpected.get()==null,"cancel disconnects blocked reader");
        check(connection.disconnected,"cancel closes connection");
    }
    private void storage(Context context) throws Exception {
        SharedPreferences prefs=context.getSharedPreferences(KeyboardSettings.PREFERENCES_NAME,Context.MODE_PRIVATE);
        String old=prefs.getString(OpenAiSettings.KEY,null);
        OpenAiSettings settings=new OpenAiSettings(context);
        try {
            settings.clear();
            try { settings.save(OpenAiSettings.DEFAULT_BASE_URL,OpenAiSettings.DEFAULT_MODEL,"",true,false); throw new AssertionError("missing key accepted"); }
            catch(OpenAiChatCodec.Failure e) { check(e.code==OpenAiChatCodec.Code.NOT_CONFIGURED,"missing key fails closed"); }
            settings.save(OpenAiSettings.DEFAULT_BASE_URL,OpenAiSettings.DEFAULT_MODEL,TEST_KEY,true,true);
            OpenAiSettings.Snapshot profile=settings.snapshot();
            check(profile.remote("ask") && profile.remote("translate"),"saved online route");
            check(TEST_KEY.equals(settings.credential(profile)),"Keystore roundtrip");
            check(!prefs.getString(OpenAiSettings.KEY,"").contains(TEST_KEY),"no plaintext key in preferences");
            settings.save(OpenAiSettings.DEFAULT_BASE_URL,OpenAiSettings.DEFAULT_MODEL,"",true,false);
            check(!settings.snapshot().remote("translate") && TEST_KEY.equals(settings.credential(settings.snapshot())),"blank keeps key and offline translation");
            settings.save(OpenAiSettings.DEFAULT_BASE_URL,OpenAiSettings.DEFAULT_MODEL,"",false,false);
            check(!settings.snapshot().remote("ask") && settings.snapshot().hasKey(),"disable preserves key but not authority");
            check(profile.remote("translate"),"captured profile immutable");
            check(ENDPOINT.equals(OpenAiSettings.normalizeBaseURL(ENDPOINT+"/")+"/chat/completions"),"full endpoint does not duplicate path");
            try { settings.save("https://other.example.test/v1",OpenAiSettings.DEFAULT_MODEL,"",true,false); throw new AssertionError("old key reused on another host"); }
            catch(OpenAiChatCodec.Failure expected) { check(TEST_KEY.equals(settings.credential(profile)),"switching host needs that provider key and preserves old profile"); }
            JSONObject legacy=new JSONObject(prefs.getString(OpenAiSettings.KEY,"{}")); legacy.remove("baseURL");
            prefs.edit().putString(OpenAiSettings.KEY,legacy.toString()).commit();
            check(OpenAiSettings.LEGACY_BASE_URL.equals(settings.snapshot().baseURL) && TEST_KEY.equals(settings.credential(profile)),"old Comet profile keeps its original recipient and ciphertext");
            settings.save("https://other.example.test/v1",OpenAiSettings.DEFAULT_MODEL,TEST_KEY,true,false);
            check("https://other.example.test/v1/chat/completions".equals(settings.snapshot().endpoint()),"new recipient and key persist together");
            settings.clear(); check(!settings.snapshot().enabled && !settings.snapshot().hasKey(),"remove disables and removes wrapped key");
        } finally {
            SharedPreferences.Editor edit=prefs.edit(); if(old==null) edit.remove(OpenAiSettings.KEY); else edit.putString(OpenAiSettings.KEY,old); edit.commit();
        }
    }
    /** Opt-in only: caller provides a private cache file over stdin, never instrumentation args. */
    static String prepareLive(Instrumentation instrumentation) throws Exception {
        configureLive(instrumentation);
        Context context=instrumentation.getTargetContext();
        OpenAiSettings settings=new OpenAiSettings(context);
        long start=android.os.SystemClock.elapsedRealtime();
        AtomicReference<String> result=new AtomicReference<>(),failure=new AtomicReference<>();
        AtomicInteger updates=new AtomicInteger(); CountDownLatch done=new CountDownLatch(1);
        try(BufferPluginExecutor executor=new BufferPluginExecutor(context)) {
            executor.run("ask","只回复：Android 连接成功", "auto",settings.snapshot(),new BufferPluginExecutor.Listener() {
                public void onUpdate(String text,boolean complete) { updates.incrementAndGet(); if(complete) { result.set(text); done.countDown(); } }
                public void onFailure(String message) { failure.set(message); done.countDown(); }
            });
            if(!done.await(65,TimeUnit.SECONDS) || failure.get()!=null || result.get()==null
                    || !result.get().contains("Android") || result.get().contains("Mock")) {
                restoreLive(instrumentation); throw new AssertionError("Live Android request failed: "+failure.get());
            }
        }
        return "PASS live Android request; recipient="+OpenAiSettings.recipient(settings.snapshot().baseURL)+" model="+settings.snapshot().model+" updates="+updates.get()
                +" elapsedMs="+(android.os.SystemClock.elapsedRealtime()-start)+"; temporary encrypted profile ready for keyboard test\n";
    }
    static void configureLive(Instrumentation instrumentation) throws Exception {
        foreground(instrumentation);
        Context context=instrumentation.getTargetContext(); File file=new File(context.getCacheDir(),"ai-test-profile.json");
        JSONObject profile;
        try { profile=new JSONObject(new String(Files.readAllBytes(file.toPath()),StandardCharsets.UTF_8)); }
        finally { Files.deleteIfExists(file.toPath()); }
        String baseURL=OpenAiSettings.normalizeBaseURL(profile.getString("baseURL"));
        String model=profile.getString("model"),secret=profile.getString("key");
        SharedPreferences prefs=context.getSharedPreferences(KeyboardSettings.PREFERENCES_NAME,0);
        File backup=new File(context.getCacheDir(),"ai-test-restore.json");
        if(backup.exists()) throw new AssertionError("Restore the previous live test before configuring another");
        OfficialPluginStore store=new OfficialPluginStore(context);
        SharedPreferences grants=context.getSharedPreferences(OfficialPluginStore.PREFERENCES,0);
        JSONObject states=new JSONObject();org.json.JSONArray installed=new org.json.JSONArray();
        for(String id:new String[]{"ask","polish","translate"}) {
            OfficialPluginStore.Entry entry=store.entry(id);String key="state."+entry.id;
            states.put(key,grants.contains(key)?grants.getString(key,null):JSONObject.NULL);
            if(!store.state(entry).installed)installed.put(entry.id);
        }
        JSONObject restore=new JSONObject().put("profile",prefs.contains(OpenAiSettings.KEY)?prefs.getString(OpenAiSettings.KEY,null):JSONObject.NULL)
                .put("states",states).put("created",installed);
        Files.write(backup.toPath(),restore.toString().getBytes(StandardCharsets.UTF_8));
        try {
            new OpenAiSettings(context).save(baseURL,model,secret,true,true);
            for(String id:new String[]{"ask","polish","translate"}) {
                OfficialPluginStore.Entry entry=store.entry(id);
                if(!store.state(entry).installed) try(InputStream input=context.getAssets().open("official-plugins/"+entry.asset);ByteArrayOutputStream out=new ByteArrayOutputStream()) {
                    byte[] block=new byte[8192];int n;while((n=input.read(block))!=-1)out.write(block,0,n);
                    store.installData(entry,out.toByteArray(),store.state(entry).grant);
                }
                store.setEnabled(entry,true);
            }
        } catch(Exception failure) { restoreLive(instrumentation);throw failure; }
    }
    static void restoreLive(Instrumentation instrumentation) throws Exception {
        Context context=instrumentation.getTargetContext();File file=new File(context.getCacheDir(),"ai-test-restore.json");
        if(!file.exists())return;
        JSONObject data=new JSONObject(new String(Files.readAllBytes(file.toPath()),StandardCharsets.UTF_8));
        SharedPreferences.Editor prefs=context.getSharedPreferences(KeyboardSettings.PREFERENCES_NAME,0).edit();
        if(data.isNull("profile"))prefs.remove(OpenAiSettings.KEY);else prefs.putString(OpenAiSettings.KEY,data.getString("profile"));
        if(!prefs.commit())throw new IOException("Could not restore prior AI profile");
        JSONObject states=data.getJSONObject("states");SharedPreferences.Editor grants=context.getSharedPreferences(OfficialPluginStore.PREFERENCES,0).edit();
        java.util.Iterator<String> keys=states.keys();while(keys.hasNext()) { String key=keys.next();if(states.isNull(key))grants.remove(key);else grants.putString(key,states.getString(key)); }
        if(!grants.commit())throw new IOException("Could not restore prior plugin grants");
        org.json.JSONArray created=data.getJSONArray("created");
        for(int i=0;i<created.length();i++)Files.deleteIfExists(new File(context.getFilesDir(),"official-plugins-v1/"+created.getString(i)+".json").toPath());
        Files.delete(file.toPath());
    }
    static void foreground(Instrumentation instrumentation) throws Exception {
        // This physical host restricts networking for a background instrumentation-only UID.
        // Exercise the ordinary foreground application instead of relaxing device policy.
        try(android.os.ParcelFileDescriptor.AutoCloseInputStream launch=new android.os.ParcelFileDescriptor.AutoCloseInputStream(
                instrumentation.getUiAutomation().executeShellCommand("am start -W -n "+instrumentation.getTargetContext().getPackageName()+"/org.scholay.rimes.android.SetupActivity"))) {
            byte[] bytes=new byte[1024]; while(launch.read(bytes)!=-1) { /* Launch diagnostics contain no credentials. */ }
        }
    }
    private static class FakeConnection extends HttpsURLConnection {
        final ByteArrayOutputStream output=new ByteArrayOutputStream();
        final int code; final String type; volatile boolean disconnected; int reads;
        FakeConnection(int code,String type) throws java.net.MalformedURLException { super(new URL(ENDPOINT)); this.code=code; this.type=type; }
        public void disconnect() { disconnected=true; }
        public boolean usingProxy() { return false; }
        public void connect() {}
        public String getCipherSuite() { return "test"; }
        public Certificate[] getLocalCertificates() { return null; }
        public Certificate[] getServerCertificates() { return null; }
        public int getResponseCode() { return code; }
        public String getContentType() { return type; }
        public OutputStream getOutputStream() { return output; }
        public InputStream getInputStream() { reads++; return new ByteArrayInputStream(WIRE.getBytes(StandardCharsets.UTF_8)); }
    }
}
