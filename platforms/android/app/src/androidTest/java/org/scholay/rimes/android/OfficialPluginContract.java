package org.scholay.rimes.android;

import android.app.Instrumentation;
import android.content.Context;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import org.json.JSONObject;

/** Install and revoke real, hashed packages without touching the device's active profile. */
final class OfficialPluginContract {
    private int checks;
    private void check(boolean value,String label) { checks++; if(!value)throw new AssertionError(label); }
    static int run(Instrumentation instrumentation) throws Exception {
        OfficialPluginContract test=new OfficialPluginContract();
        try(PluginTestContext context=new PluginTestContext(instrumentation.getTargetContext(),false)) { test.fresh(context); }
        try(PluginTestContext context=new PluginTestContext(instrumentation.getTargetContext(),true)) { test.legacy(context); }
        return test.checks;
    }
    private byte[] asset(Context context,OfficialPluginStore.Entry entry) throws Exception {
        try(InputStream input=context.getAssets().open("official-plugins/"+entry.asset);ByteArrayOutputStream out=new ByteArrayOutputStream()) {
            byte[] block=new byte[8192];int n;while((n=input.read(block))!=-1)out.write(block,0,n);return out.toByteArray();
        }
    }
    private void fresh(PluginTestContext context) throws Exception {
        OfficialPluginStore store=new OfficialPluginStore(context);
        check(store.entries().size()==6,"Android has six actual adapters");
        OfficialPluginStore.Entry polish=store.entry("polish"),chord=store.entry("chord");
        check(!store.state(polish).installed && !store.enabled("polish"),"fresh optional plugin is absent");
        check(store.enabled("chord") && store.enabled("translate"),"bundled features available");
        File source=new File(context.getFilesDir(),"keep-user-draft.txt");Files.write(source.toPath(),"Keep me".getBytes(StandardCharsets.UTF_8));
        byte[] data=asset(context,polish);String old=store.state(polish).grant;
        store.installData(polish,data,old);
        check(store.state(polish).installed && !store.enabled("polish"),"verified install starts disabled");
        store.setEnabled(polish,true);String grant=store.grant("polish");
        check(grant!=null && !old.equals(grant),"enable creates a fresh grant");
        String instruction=store.instruction("polish");
        JSONObject request=new JSONObject(new String(OpenAiChatCodec.makeRemoteRequest("polish","原文",OpenAiSettings.DEFAULT_MODEL,"auto",instruction),StandardCharsets.UTF_8));
        check(instruction.equals(request.getJSONArray("messages").getJSONObject(0).getString("content")),"actual package instruction enters the remote request");
        store.setEnabled(polish,false);store.setEnabled(polish,true);
        check(!grant.equals(store.grant("polish")),"re-enable invalidates the previous result grant");
        String downloading=store.state(polish).grant;store.uninstall(polish);
        check(!store.state(polish).installed && store.grant("polish")==null,"uninstall revokes execution");
        try { store.installData(polish,data,downloading);throw new AssertionError("late download resurrected plugin"); }
        catch(IOException expected) { check(true,"late download rejected"); }
        store.installData(polish,data,store.state(polish).grant);store.setEnabled(polish,true);
        File packageFile=new File(context.getFilesDir(),"official-plugins-v1/"+polish.id+".json");Files.write(packageFile.toPath(),"{}".getBytes(StandardCharsets.UTF_8));
        check(!store.enabled("polish"),"tampered package cannot execute");
        try { store.installData(polish,new byte[]{0},store.state(polish).grant);throw new AssertionError("invalid hash installed"); }
        catch(IOException expected) { check(true,"bad hash rejected before install"); }
        store.uninstall(chord);check(!store.enabled("chord"),"bundled input plugin can be uninstalled");
        store.install(chord);check(!store.enabled("chord"),"bundled reinstall still requires enable");
        store.setEnabled(chord,true);check(store.enabled("chord"),"bundled restore executes validated content");
        check(source.exists(),"plugin lifecycle retains user data");
        context.getSharedPreferences(KeyboardSettings.PREFERENCES_NAME,0).edit().putString("schema","rimes_pinyin").commit();
        check(!new OfficialPluginStore(context).state(store.entry("ask")).installed,"later settings save does not turn a fresh install into legacy");
    }
    private void legacy(PluginTestContext context) throws Exception {
        OfficialPluginStore store=new OfficialPluginStore(context);
        for(OfficialPluginStore.Entry entry:store.entries()) check(store.enabled(entry.legacyID),"legacy feature remains usable: "+entry.legacyID);
        store.uninstall(store.entry("ask"));
        check(!new OfficialPluginStore(context).enabled("ask"),"explicit uninstall survives restart of migrated profile");
    }
}
