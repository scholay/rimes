package org.scholay.rimes.android;

import android.app.Instrumentation;
import android.os.Bundle;
import android.os.Looper;
import android.os.SystemClock;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONObject;

/** Protocol/dictionary/backend checks only: no host authority, Rime, network or device injection. */
final class PluginBackendContract {
    private final Instrumentation instrumentation;
    private int checks;
    private PluginBackendContract(Instrumentation instrumentation) { this.instrumentation=instrumentation; }
    static int run(Instrumentation instrumentation) throws Exception {
        if(Looper.myLooper()==Looper.getMainLooper()) throw new IllegalStateException("PluginBackendContract must run off main");
        PluginBackendContract test=new PluginBackendContract(instrumentation);
        test.codec(); test.mock(); test.dictionary(); test.executor(); return test.checks;
    }
    private void check(boolean condition,String label) { checks++; if(!condition) throw new AssertionError("Plugins: "+label); }
    private interface Checked { void run() throws Exception; }
    private void failure(OpenAiChatCodec.Code expected,Checked action,String label) throws Exception {
        try { action.run(); throw new AssertionError("Plugins: missing "+expected+" for "+label); }
        catch(OpenAiChatCodec.Failure error) { check(error.code==expected,label+" typed "+expected); }
    }
    private static byte[] bytes(String value) { return value.getBytes(StandardCharsets.UTF_8); }
    private static String content(String value) {
        return "data: {\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":"
                +JSONObject.quote(value)+"},\"finish_reason\":null}]}\r\n\r\n";
    }
    private static final String STOP="data: {\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n";
    private static final String DONE="data: [DONE]\n\n";
    private static OpenAiChatCodec.Decoder decoder() {
        return new OpenAiChatCodec.Decoder(new PluginCancellation(),(text,complete) -> {});
    }
    private void codec() throws Exception {
        String unicode="中文𠮷😀\u0000\"\\\nZ";
        OpenAiChatCodec.Request request=OpenAiChatCodec.readRequest(OpenAiChatCodec.makeRequest("ask",unicode));
        check(unicode.equals(request.source) && "ask".equals(request.pluginID),"request JSON preserves Unicode, NUL and escaped punctuation");
        JSONObject json=new JSONObject(new String(OpenAiChatCodec.makeRequest("ask",unicode),StandardCharsets.UTF_8));
        check(Boolean.TRUE.equals(json.get("stream")) && OpenAiChatCodec.MOCK_MODEL.equals(json.getString("model"))
                && json.getJSONArray("messages").length()==2 && !json.has("api_key") && !json.has("Authorization"),"Chat Completions request shape without credentials");
        failure(OpenAiChatCodec.Code.EMPTY_INPUT,() -> OpenAiChatCodec.makeRequest("ask"," \n"),"empty source");
        failure(OpenAiChatCodec.Code.INPUT_LIMIT,() -> OpenAiChatCodec.makeRequest("ask","a".repeat(16385)),"source UTF16 bound");
        failure(OpenAiChatCodec.Code.INVALID_UNICODE,() -> OpenAiChatCodec.makeRequest("ask","x\ud800"),"unpaired source surrogate");
        failure(OpenAiChatCodec.Code.INVALID_REQUEST,() -> OpenAiChatCodec.makeRequest("unknown","text"),"unknown AI ID");
        failure(OpenAiChatCodec.Code.INVALID_REQUEST,() -> OpenAiChatCodec.readRequest(bytes("{\"model\":\"remote\",\"stream\":true,\"messages\":[]}")),"unconfigured model rejected");
        String validRequest=new String(OpenAiChatCodec.makeRequest("ask","text"),StandardCharsets.UTF_8);
        failure(OpenAiChatCodec.Code.INVALID_REQUEST,() -> OpenAiChatCodec.readRequest(bytes(validRequest+" trailing")),"request trailing junk rejected");
        failure(OpenAiChatCodec.Code.INVALID_REQUEST,() -> OpenAiChatCodec.readRequest(bytes(validRequest+"{}")),"request concatenated object rejected");
        failure(OpenAiChatCodec.Code.INVALID_REQUEST,() -> OpenAiChatCodec.readRequest(bytes(validRequest+" // comment")),"request trailing comment is not JSON whitespace");
        failure(OpenAiChatCodec.Code.INVALID_REQUEST,() -> OpenAiChatCodec.readRequest(bytes(validRequest+"\u0000")),"request literal NUL is not EOF");
        check("text".equals(OpenAiChatCodec.readRequest(bytes(validRequest+" \r\n\t")).source),"request trailing JSON whitespace allowed");
        check(OpenAiChatCodec.readRequest(OpenAiChatCodec.makeRequest("polish","\u0000".repeat(16383)+"x")).source.length()==16384,"maximum escaped source accepted");

        List<String> updates=new ArrayList<>(); AtomicInteger completions=new AtomicInteger();
        OpenAiChatCodec.Decoder decoded=new OpenAiChatCodec.Decoder(new PluginCancellation(),(text,complete) -> {
            updates.add(text); if(complete) completions.incrementAndGet();
        });
        String wire=": heartbeat\r\nevent: message\r\n"+content(unicode)+STOP
                +"data: {\"object\":\"chat.completion.chunk\",\"choices\":[],\"usage\":{\"total_tokens\":4}}\n\n"+DONE;
        for(byte value:bytes(wire)) decoded.append(new byte[]{value});
        check(completions.get()==0,"DONE alone does not authorize output before EOF validation");
        check(unicode.equals(decoded.finish()) && completions.get()==1,"byte-fragmented UTF8/CRLF/comments/usage retain exact output");
        decoded.finish(); check(completions.get()==1 && updates.size()==2,"completion callback exactly once");

        OpenAiChatCodec.Decoder multi=decoder();
        multi.append(bytes("data: {\"object\":\"chat.completion.chunk\",\n"
                +"data: \"choices\":[{\"index\":0,\"delta\":{\"content\":\"你好\"},\"finish_reason\":null}]}\n\n"+STOP+DONE));
        check("你好".equals(multi.finish()),"SSE multiline data joins into valid JSON");
        failure(OpenAiChatCodec.Code.INVALID_UTF8,() -> decoder().append(new byte[]{'d','a','t','a',':',' ',(byte)0xc3,0x28,'\n'}),"malformed UTF8 rejected");
        failure(OpenAiChatCodec.Code.INVALID_FRAME,() -> decoder().append(bytes("data: {}\n\n")),"malformed chunk shape");
        AtomicInteger malformedUpdates=new AtomicInteger();
        OpenAiChatCodec.Decoder trailingFrame=new OpenAiChatCodec.Decoder(new PluginCancellation(),(text,complete) -> malformedUpdates.incrementAndGet());
        failure(OpenAiChatCodec.Code.INVALID_FRAME,() -> trailingFrame.append(bytes(content("text").trim()+" trailing\n\n")),"frame trailing junk rejected");
        check(malformedUpdates.get()==0,"malformed frame cannot publish partial text");
        failure(OpenAiChatCodec.Code.INVALID_FRAME,() -> decoder().append(bytes(content("text").trim()+"{}\n\n")),"frame concatenated object rejected");
        failure(OpenAiChatCodec.Code.PROVIDER_ERROR,() -> decoder().append(bytes("data: {\"error\":{\"message\":\"private_source_sentinel\"}}\n\n")),"provider error typed");
        try { decoder().append(bytes("data: {\"error\":{\"message\":\"private_source_sentinel\"}}\n\n")); }
        catch(OpenAiChatCodec.Failure error) { check(!error.getMessage().contains("private_source_sentinel"),"provider body is not reflected into status"); }
        failure(OpenAiChatCodec.Code.INCOMPLETE,() -> decoder().append(bytes(content("a")+DONE)),"DONE without stop rejected");
        failure(OpenAiChatCodec.Code.INCOMPLETE,() -> { OpenAiChatCodec.Decoder d=decoder(); d.append(bytes(content("a")+STOP)); d.finish(); },"truncated stream missing DONE");
        failure(OpenAiChatCodec.Code.INCOMPLETE,() -> { OpenAiChatCodec.Decoder d=decoder(); d.append(bytes(content("a").trim())); d.finish(); },"unflushed SSE event at EOF");
        failure(OpenAiChatCodec.Code.INCOMPLETE,() -> decoder().append(bytes(content("a")+STOP.replace("stop","length"))),"length finish is not success");
        failure(OpenAiChatCodec.Code.INVALID_FRAME,() -> decoder().append(bytes(content("a")+STOP+content("b"))),"delta after finish rejected");
        failure(OpenAiChatCodec.Code.INVALID_FRAME,() -> decoder().append(bytes(content("a")+STOP+DONE+content("b"))),"event after DONE rejected");
        failure(OpenAiChatCodec.Code.INVALID_UNICODE,() -> decoder().append(bytes(
                "data: {\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"x\\ud800\"},\"finish_reason\":null}]}\n\n")),"unpaired decoded surrogate rejected");
        failure(OpenAiChatCodec.Code.OUTPUT_LIMIT,() -> decoder().append(bytes(content("a".repeat(16385)))),"output UTF16 bound");
        OpenAiChatCodec.Decoder maximum=decoder(); maximum.append(bytes(content("😀".repeat(8192))+STOP+DONE));
        check(maximum.finish().length()==16384,"maximum nonBMP output accepted");
        failure(OpenAiChatCodec.Code.WIRE_LIMIT,() -> decoder().append(new byte[OpenAiChatCodec.MAX_WIRE_BYTES+1]),"wire bound");
        failure(OpenAiChatCodec.Code.WIRE_LIMIT,() -> decoder().append(bytes("x".repeat(OpenAiChatCodec.MAX_LINE_BYTES+1))),"line bound");
        PluginCancellation cancelled=new PluginCancellation(); cancelled.cancel();
        try { new OpenAiChatCodec.Decoder(cancelled,(text,complete) -> {}).append(bytes(content("a"))); throw new AssertionError("cancellation ignored"); }
        catch(PluginCancellation.Cancelled expected) { check(true,"typed cancellation stops parser"); }
    }
    private void mock() throws Exception {
        for(String id:new String[]{"ask","polish","poem","art"}) {
            AtomicInteger progress=new AtomicInteger(),complete=new AtomicInteger();
            OpenAiChatCodec.Decoder decoder=new OpenAiChatCodec.Decoder(new PluginCancellation(),(text,done) -> {
                if(done) complete.incrementAndGet(); else progress.incrementAndGet();
            });
            MockOpenAiTransport.stream(OpenAiChatCodec.makeRequest(id,"你好𠮷😀"),new PluginCancellation(),decoder::append);
            String output=decoder.finish();
            check(output.contains("Mock") && output.contains("你好𠮷😀") && complete.get()==1 && progress.get()>=8 && progress.get()<=12,"local "+id+" mock true SSE with visible fragments");
        }
        check("/v1/chat/completions".equals(MockOpenAiTransport.PATH),"future transport endpoint metadata");
    }
    private void dictionary() throws Exception {
        OfflineDictionary dictionary=new OfflineDictionary(instrumentation.getTargetContext());
        PluginCancellation cancellation=new PluginCancellation();
        long firstStarted=SystemClock.elapsedRealtimeNanos();
        OfflineDictionary.Translation chinese=dictionary.translate("你好","zh-en",cancellation);
        long firstLoadLookupNs=SystemClock.elapsedRealtimeNanos()-firstStarted;
        check(chinese.hasMatches() && chinese.fullyCovered() && !"你好".equals(chinese.text),"real bundled dictionary Chinese greeting");
        OfflineDictionary.Translation english=dictionary.translate("hello","en-zh",cancellation);
        check(english.hasMatches() && english.fullyCovered() && !"hello".equals(english.text),"real bundled dictionary English greeting");
        check("zh-en".equals(dictionary.translate("你好","auto",cancellation).resolvedDirection)
                && "en-zh".equals(dictionary.translate("hello","auto",cancellation).resolvedDirection),"automatic pair uses source script");
        OfflineDictionary.Translation mixed=dictionary.translate("你好 rimeszzunknown 😀","zh-en",cancellation);
        check(mixed.hasMatches() && !mixed.fullyCovered() && mixed.unknownUnits>0 && mixed.text.contains("rimeszzunknown") && mixed.text.contains("😀"),"mixed uncovered fragments preserved with coverage");
        OfflineDictionary.Translation unknown=dictionary.translate("rimeszzunknown","en-zh",cancellation);
        check(!unknown.hasMatches() && unknown.unknownUnits>0 && "rimeszzunknown".equals(unknown.text),"unknown input is not fabricated translation");
        check(dictionary.translate("hello\n","en-zh",cancellation).text.endsWith("\n"),"dictionary retains exact line ending");
        final int samples=1000;
        boolean allMatched=true;
        long warmStarted=SystemClock.elapsedRealtimeNanos();
        for(int sample=0;sample<samples;sample++) {
            boolean chinesePair=(sample&1)==0;
            OfflineDictionary.Translation result=dictionary.translate(chinesePair?"你好":"hello",chinesePair?"zh-en":"en-zh",cancellation);
            allMatched&=result.hasMatches() && result.fullyCovered();
        }
        long warmTotalNs=SystemClock.elapsedRealtimeNanos()-warmStarted;
        check(allMatched,"all warm dictionary lookups retain coverage");
        Bundle timing=new Bundle();
        timing.putLong("dictionary_first_load_lookup_ns",firstLoadLookupNs);
        timing.putLong("dictionary_warm_lookup_total_ns",warmTotalNs);
        timing.putInt("dictionary_warm_lookup_samples",samples);
        timing.putString("stream","dictionary first_load_lookup_ns="+firstLoadLookupNs
                +" warm_lookup_total_ns="+warmTotalNs+" warm_lookup_samples="+samples+"\n");
        instrumentation.sendStatus(0,timing);
    }
    private static final class Capture implements BufferPluginExecutor.Listener {
        final CountDownLatch progress=new CountDownLatch(1),finished=new CountDownLatch(1);
        final AtomicInteger updates=new AtomicInteger(),completions=new AtomicInteger(),failures=new AtomicInteger();
        volatile String text="",failure=""; volatile boolean onMain;
        @Override public void onUpdate(String value,boolean complete) {
            onMain|=Looper.myLooper()==Looper.getMainLooper(); text=value; updates.incrementAndGet();
            if(complete) { completions.incrementAndGet(); finished.countDown(); } else progress.countDown();
        }
        @Override public void onFailure(String message) { onMain|=Looper.myLooper()==Looper.getMainLooper(); failure=message; failures.incrementAndGet(); finished.countDown(); }
    }
    private void await(CountDownLatch latch,String label) throws InterruptedException { check(latch.await(15,TimeUnit.SECONDS),label+" within15s"); }
    private void executor() throws Exception {
        try(PluginTestContext context=new PluginTestContext(instrumentation.getTargetContext(),true);
                BufferPluginExecutor executor=new BufferPluginExecutor(context)) {
            Capture complete=new Capture(); executor.run("ask","你好𠮷😀","auto",complete); await(complete.finished,"mock completion");
            check(!complete.onMain && complete.text.contains("Mock") && complete.completions.get()==1 && complete.failures.get()==0,"executor completes exactly once off-main");
            Capture cancelled=new Capture(); BufferPluginExecutor.Job job=executor.run("ask","取消验证","auto",cancelled);
            await(cancelled.progress,"observable cancellation point"); job.cancel(); int count=cancelled.updates.get(); SystemClock.sleep(150);
            check(cancelled.updates.get()==count && cancelled.completions.get()==0 && cancelled.failures.get()==0,"cancel suppresses all later callbacks without failure");
            Capture old=new Capture(); executor.run("ask","旧内容","auto",old); await(old.progress,"replacement old progress");
            Capture fresh=new Capture(); executor.run("polish","新内容","auto",fresh); int oldCount=old.updates.get(); await(fresh.finished,"replacement completion");
            check(old.updates.get()==oldCount && old.completions.get()==0 && fresh.completions.get()==1 && fresh.text.contains("新内容") && !fresh.text.contains("旧内容"),"latest job replaces old source without late publication");
            Capture translation=new Capture(); executor.run("translate","hello","en-zh",translation); await(translation.finished,"dictionary completion");
            check(translation.completions.get()==1 && translation.failures.get()==0 && !"hello".equals(translation.text),"translation backend uses dictionary");
            Capture partial=new Capture(); executor.run("translate","hello rimeszzunknown","en-zh",partial); await(partial.finished,"partial dictionary completion");
            check(partial.text.startsWith("【离线词典 · 部分匹配") && partial.text.contains("rimeszzunknown"),"partial translation is labelled");
            Capture noCoverage=new Capture(); executor.run("translate","rimeszzunknown","en-zh",noCoverage); await(noCoverage.finished,"unknown dictionary failure");
            check(noCoverage.failures.get()==1 && noCoverage.completions.get()==0,"zero-match translation remains failure");
            Capture badDirection=new Capture(); executor.run("translate","hello","fr-ja",badDirection); await(badDirection.finished,"invalid direction failure");
            check(badDirection.failures.get()==1 && badDirection.completions.get()==0,"unsupported direction fails closed");
            Capture empty=new Capture(); executor.run("ask","","auto",empty); await(empty.finished,"empty source failure");
            check(empty.failures.get()==1 && empty.completions.get()==0,"backend empty source failure");
            Capture closing=new Capture(); executor.run("ask","关闭验证","auto",closing); await(closing.progress,"close cancellation point");
            executor.close(); int closingCount=closing.updates.get(); SystemClock.sleep(150);
            check(closing.updates.get()==closingCount && closing.completions.get()==0 && closing.failures.get()==0,"close retires worker and listener");
            try { executor.run("ask","x","auto",new Capture()); throw new AssertionError("closed worker accepted job"); }
            catch(IllegalStateException expected) { check(true,"closed executor cannot enqueue"); }
        }
    }
}
