package org.scholay.rimes.android;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.SocketTimeoutException;
import java.net.URL;
import java.util.Locale;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import javax.net.ssl.HttpsURLConnection;

/** One bounded HTTPS request; no redirect, retry, response-body logging or mock fallback. */
final class HttpOpenAiTransport {
    interface Connections { HttpsURLConnection open(URL url) throws IOException; }
    private static final ScheduledExecutorService CONTROL=Executors.newScheduledThreadPool(2,task -> {
        Thread thread=new Thread(task,"RIMES-AI-cancel"); thread.setDaemon(true); return thread;
    });
    private final Connections connections;
    HttpOpenAiTransport() { this(url -> (HttpsURLConnection)url.openConnection()); }
    HttpOpenAiTransport(Connections connections) { this.connections=connections; }

    void stream(String endpoint,byte[] request,String key,PluginCancellation cancellation,MockOpenAiTransport.Receiver receiver)
            throws OpenAiChatCodec.Failure {
        cancellation.check();
        HttpsURLConnection connection=null;
        ScheduledFuture<?> timeout=null;
        AtomicBoolean expired=new AtomicBoolean();
        Runnable abort=null;
        try {
            String recipient=OpenAiSettings.normalizeBaseURL(endpoint)+"/chat/completions";
            connection=connections.open(new URL(recipient));
            HttpsURLConnection active=connection;
            abort=() -> CONTROL.execute(active::disconnect);
            cancellation.onCancel(abort);
            timeout=CONTROL.schedule(() -> { expired.set(true); active.disconnect(); },60,TimeUnit.SECONDS);
            connection.setConnectTimeout(10000); connection.setReadTimeout(20000);
            connection.setInstanceFollowRedirects(false); connection.setUseCaches(false);
            connection.setRequestMethod("POST"); connection.setDoOutput(true);
            connection.setRequestProperty("Authorization","Bearer "+key);
            connection.setRequestProperty("Content-Type","application/json; charset=utf-8");
            connection.setRequestProperty("Accept","text/event-stream");
            connection.setFixedLengthStreamingMode(request.length);
            cancellation.check();
            try(OutputStream output=connection.getOutputStream()) { output.write(request); }
            cancellation.check();
            int status=connection.getResponseCode();
            if(status!=200) {
                String code=errorCode(connection.getErrorStream(),cancellation);
                cancellation.check(); throw httpFailure(status,code);
            }
            String type=connection.getContentType();
            if(type==null || !type.split(";",2)[0].trim().toLowerCase(Locale.ROOT).equals("text/event-stream"))
                throw new OpenAiChatCodec.Failure(OpenAiChatCodec.Code.INVALID_FRAME,"服务未返回流式回复，原文已保留。");
            try(InputStream input=connection.getInputStream()) {
                byte[] bytes=new byte[4096]; int length;
                while((length=input.read(bytes))!=-1) {
                    cancellation.check(); if(expired.get()) throw new SocketTimeoutException();
                    receiver.onBytes(bytes,0,length);
                }
            }
            cancellation.check(); if(expired.get()) throw new SocketTimeoutException();
        } catch(IOException error) {
            cancellation.check();
            throw new OpenAiChatCodec.Failure(OpenAiChatCodec.Code.NETWORK_ERROR,
                    error instanceof SocketTimeoutException || expired.get()?"AI 请求超时，原文已保留。":"无法连接 AI 服务，请检查网络后重试。原文已保留。");
        } finally {
            if(timeout!=null) timeout.cancel(false);
            if(abort!=null) cancellation.removeOnCancel(abort);
            if(connection!=null) connection.disconnect();
        }
    }
    private static String errorCode(InputStream input,PluginCancellation cancellation) {
        if(input==null) return "";
        try(InputStream body=input; java.io.ByteArrayOutputStream bytes=new java.io.ByteArrayOutputStream()) {
            byte[] block=new byte[1024]; int count;
            while(bytes.size()<4096 && (count=body.read(block,0,Math.min(block.length,4096-bytes.size())))!=-1) {
                cancellation.check(); bytes.write(block,0,count);
            }
            org.json.JSONObject error=new org.json.JSONObject(bytes.toString("UTF-8")).optJSONObject("error");
            return error==null?"":error.optString("code","");
        } catch(IOException | org.json.JSONException ignored) { return ""; }
    }
    private static OpenAiChatCodec.Failure httpFailure(int status,String code) {
        // Use only a recognized code. Never surface the provider's message, body or request echo.
        String message=status==403 && "region_restricted".equals(code)?"AI 服务暂不支持当前地区，请联系服务商确认。"
                :status==401?"AI 密钥不可用，请检查配置。"
                :status==403?"AI 服务拒绝访问（HTTP 403），请检查服务地区与模型权限。"
                :status==402?"AI 账户额度不足。":status==429?"AI 服务请求过多或额度受限，请稍后重试。"
                :status>=300 && status<400?"AI 服务返回重定向，已停止请求。"
                :status>=500?"AI 服务暂时不可用，请稍后重试。":"AI 请求失败（HTTP "+status+"）。";
        return new OpenAiChatCodec.Failure(OpenAiChatCodec.Code.HTTP_ERROR,message+"原文已保留。");
    }
}
