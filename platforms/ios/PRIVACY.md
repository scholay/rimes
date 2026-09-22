# Privacy disclosure — RIMES iOS 0.1

Effective 22 September 2026. Publisher: Haiyang Cui.
Published policy: <https://scholay.github.io/rimes/ios/privacy/>.
Support and privacy contact: <https://scholay.github.io/rimes/ios/support/>
and the linked project issue tracker. Do not include credentials or private typing
in public issues. The website contains the complete bilingual public policy.

## 中文

RIMES 的普通输入在设备本地运行。学习词频只保存在当前设备，不提供账户或云同步。
我们不收集输入正文日志、广告标识符或使用遥测。Buffer 草稿保存在键盘会话内存中，
不写入文件；离开键盘会话时清除。

AI 功能可选。你配置自己的 HTTPS 服务地址、模型和 API Key，并在明确同意接收方后
主动提交当前 Buffer 文本。请求包含这段文本、所选操作的指令、模型 ID 和用于向该
服务认证的 Key。不会自动发送宿主文档全文、剪贴板或后台打字记录。服务方会处理
请求并可能将它关联到其 API 账户；保留、训练和删除政策取决于你选用的服务，RIMES
不能替该服务承诺。请仅配置你信任的服务。

API Key 保存在本设备 Keychain，不包含在配置导出和备份中。请求不跟随重定向。
你可以删除服务配置及其 Key、撤销发送许可，或关闭键盘完全访问。关闭完全访问后，
普通输入及 Buffer 仍可用。卸载应用不会保证系统删除 Keychain 中的项目，因此建议
先在 AI 服务列表中删除配置，必要时到服务方撤销 API Key。

## English

Ordinary typing runs locally. Learned word frequencies stay on this device; there
are no accounts, cloud sync, advertising identifiers, text logs or usage telemetry.
Buffer drafts stay in keyboard-session memory and are cleared when the session ends.

AI is optional. You configure an HTTPS provider, model and API key. After consenting
to the recipient, you explicitly submit the current Buffer text. The request includes
that text, the selected operation's instruction, model ID and authentication key.
Host documents, clipboard contents and background keystrokes are not sent automatically.
The provider processes the request and may link it to its API account. Retention,
training and deletion depend on that provider's policy; RIMES cannot promise them on
the provider's behalf. Configure only providers you trust.

Keys stay in this device's Keychain, outside configuration exports and backups.
Requests do not follow redirects. You can delete a provider and its key, withdraw
sending consent, or disable Full Access while continuing offline typing and Buffer.
Uninstalling does not guarantee Keychain deletion; delete configured providers first
and revoke the key at the provider when needed.

## App Store disclosure recorded on 22 September 2026

The App Store Connect privacy answers are published for app `6814620242`. They
disclose **Other User Content** and **User ID**, used for app functionality, linked
to the user and not used for tracking. This conservatively covers optional BYOK
requests: the selected text is transmitted, and the provider credential identifies
an API account. Build 8's privacy manifest declares the same two types.

Ordinary local typing does not create a collection event. Do not advertise the AI
mode as "no data leaves the device" or universally "not linked". Policy URLs are
saved for English, Simplified Chinese and Traditional Chinese. Published privacy
answers do not mean that the app has been submitted, approved or released.

## Build 2 local translation and preferences

The keyboard stores its last selected input scheme, haptics preference and language
pair in its own preferences container. Buffer text and plugin results remain in
memory and are cleared when the keyboard session ends. These preferences do not
require Full Access or contain API keys or typed text.

Apple translation uses downloaded on-device language models through Translation.
The containing app offers the system model-download flow, which can require a
network connection. The keyboard does not fall back to an external AI endpoint
when local translation is unavailable. Existing explicitly selected AI providers
retain their separate recipient consent and Keychain behavior.
