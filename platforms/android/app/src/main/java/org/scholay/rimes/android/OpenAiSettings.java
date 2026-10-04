package org.scholay.rimes.android;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.KeyStore;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import org.json.JSONObject;

/** Host-owned OpenAI-compatible profile; legacy Comet settings and Keystore keys remain readable. */
final class OpenAiSettings {
    static final String KEY="comet_ai_profile";
    static final String DEFAULT_BASE_URL="https://api.deepseek.com";
    static final String DEFAULT_MODEL="deepseek-flash";
    static final String LEGACY_BASE_URL="https://api.cometapi.com/v1";
    static final String LEGACY_MODEL="deepseek-v4-flash";
    private static final String ALIAS="rimes.comet-api.v1";
    private final SharedPreferences preferences;

    OpenAiSettings(Context context) {
        this(context.getSharedPreferences(KeyboardSettings.PREFERENCES_NAME,Context.MODE_PRIVATE));
    }
    OpenAiSettings(SharedPreferences preferences) { this.preferences=preferences; }
    static final class Snapshot {
        final boolean enabled,translation;
        final String baseURL,model;
        private final String encryptedKey,iv;
        Snapshot(boolean enabled,boolean translation,String baseURL,String model,String encryptedKey,String iv) {
            this.enabled=enabled; this.translation=translation; this.baseURL=baseURL; this.model=model;
            this.encryptedKey=encryptedKey; this.iv=iv;
        }
        String endpoint() { return baseURL+"/chat/completions"; }
        boolean hasKey() { return !encryptedKey.isEmpty() && !iv.isEmpty(); }
        boolean remote(String plugin) { return enabled && (!"translate".equals(plugin) || translation); }
    }
    static Snapshot disabled() { return new Snapshot(false,false,DEFAULT_BASE_URL,DEFAULT_MODEL,"",""); }
    Snapshot snapshot() {
        try {
            String raw=preferences.getString(KEY,null);
            if(raw==null) return disabled();
            JSONObject json=new JSONObject(raw);
            // A profile saved before 1.1 has no URL. Preserve its recipient and encrypted key.
            String baseURL=normalizeBaseURL(json.optString("baseURL",LEGACY_BASE_URL));
            String model=json.optString("model",LEGACY_MODEL);
            if(!validModel(model)) return disabled();
            return new Snapshot(json.optBoolean("enabled",false),json.optBoolean("translation",false),baseURL,model,
                    json.optString("ciphertext",""),json.optString("iv",""));
        } catch(Exception ignored) { return disabled(); }
    }
    static boolean validModel(String model) { return model!=null && model.matches("[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}"); }
    static String normalizeBaseURL(String value) throws OpenAiChatCodec.Failure {
        if(value==null || value.length()>2048) throw failure("请输入有效的 HTTPS API 地址。");
        value=value.trim();
        try {
            java.net.URI url=new java.net.URI(value);
            if(!"https".equalsIgnoreCase(url.getScheme()) || url.getHost()==null || url.getHost().isEmpty()
                    || url.getRawUserInfo()!=null || url.getRawQuery()!=null || url.getRawFragment()!=null
                    || url.getPort()==0 || url.getPort()>65535 || !url.normalize().equals(url)
                    || (url.getRawPath()!=null && url.getRawPath().contains("%"))) throw new IllegalArgumentException();
            String path=url.getPath();
            if(path==null) path="";
            while(path.endsWith("/")) path=path.substring(0,path.length()-1);
            if(path.endsWith("/chat/completions")) path=path.substring(0,path.length()-17);
            return new java.net.URI("https",null,url.getHost().toLowerCase(java.util.Locale.ROOT),
                    url.getPort()==443?-1:url.getPort(),path,null,null).toASCIIString();
        } catch(Exception error) { throw failure("请输入有效的 HTTPS API 地址，不要包含账号、查询参数或片段。"); }
    }
    static String recipient(String baseURL) {
        java.net.URI uri=java.net.URI.create(baseURL);
        return uri.getHost()+":"+(uri.getPort()==-1?443:uri.getPort());
    }
    void save(String baseURL,String model,String replacementKey,boolean enabled,boolean translation) throws OpenAiChatCodec.Failure {
        baseURL=normalizeBaseURL(baseURL);
        model=model.trim();
        if(!validModel(model)) throw failure("模型名称无效。");
        Snapshot previous=snapshot(); String ciphertext=previous.encryptedKey,iv=previous.iv;
        if(previous.hasKey() && !recipient(previous.baseURL).equals(recipient(baseURL))
                && (replacementKey==null || replacementKey.trim().isEmpty()))
            throw failure("API 地址已换到其他服务，请填写该服务的密钥。");
        try {
            if(replacementKey!=null && !replacementKey.trim().isEmpty()) {
                String value=replacementKey.trim();
                if(value.length()>4096 || !value.matches("[!-~]+")) throw failure("API Key 格式无效。");
                Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");
                cipher.init(Cipher.ENCRYPT_MODE,key(true));
                ciphertext=Base64.encodeToString(cipher.doFinal(value.getBytes(StandardCharsets.UTF_8)),Base64.NO_WRAP);
                iv=Base64.encodeToString(cipher.getIV(),Base64.NO_WRAP);
            }
            if(enabled && (ciphertext.isEmpty() || iv.isEmpty())) throw failure("请先填写 API Key。");
            String json=new JSONObject().put("baseURL",baseURL).put("model",model).put("enabled",enabled).put("translation",translation)
                    .put("ciphertext",ciphertext).put("iv",iv).toString();
            if(!preferences.edit().putString(KEY,json).commit()) throw failure("AI 设置无法保存，请重试。");
        } catch(OpenAiChatCodec.Failure error) { throw error; }
        catch(Exception ignored) { throw failure("密钥无法安全保存，请重试。"); }
    }
    void clear() throws OpenAiChatCodec.Failure {
        if(!preferences.edit().remove(KEY).commit()) throw failure("AI 设置无法移除，请重试。");
    }
    String credential(Snapshot snapshot) throws OpenAiChatCodec.Failure {
        if(!snapshot.enabled || !snapshot.hasKey()) throw failure("请在 RIMES 主应用的 AI 服务中配置密钥。");
        try {
            Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE,key(false),new GCMParameterSpec(128,Base64.decode(snapshot.iv,Base64.NO_WRAP)));
            return new String(cipher.doFinal(Base64.decode(snapshot.encryptedKey,Base64.NO_WRAP)),StandardCharsets.UTF_8);
        } catch(Exception ignored) { throw failure("密钥无法读取，请在 AI 服务中重新填写。"); }
    }
    private static synchronized SecretKey key(boolean create) throws Exception {
        KeyStore store=KeyStore.getInstance("AndroidKeyStore"); store.load(null);
        if(store.containsAlias(ALIAS)) return (SecretKey)store.getKey(ALIAS,null);
        if(!create) throw new GeneralSecurityException("Missing key");
        KeyGenerator generator=KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(ALIAS,KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
        return generator.generateKey();
    }
    private static OpenAiChatCodec.Failure failure(String message) {
        return new OpenAiChatCodec.Failure(OpenAiChatCodec.Code.NOT_CONFIGURED,message);
    }
}
