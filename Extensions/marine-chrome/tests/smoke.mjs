import assert from 'node:assert/strict';
import { createHash, createHmac } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const read = relative => readFileSync(join(root, relative), 'utf8');

function javascriptFiles(directory) {
  const output = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) output.push(...javascriptFiles(path));
    else if (entry.isFile() && entry.name.endsWith('.js')) output.push(path);
  }
  return output;
}

for (const path of javascriptFiles(root)) {
  assert.doesNotThrow(() => new vm.Script(readFileSync(path, 'utf8'), { filename: path }));
}

const manifest = JSON.parse(read('manifest.json'));
assert.equal(manifest.manifest_version, 3);
assert.equal(manifest.version, '0.2.0');
const extensionDigest = createHash('sha256')
  .update(Buffer.from(manifest.key, 'base64')).digest().subarray(0, 16);
const manifestExtensionId = Array.from(extensionDigest, byte =>
  String.fromCharCode(97 + (byte >> 4), 97 + (byte & 15))).join('');
assert.equal(manifestExtensionId, 'gpieknckmapliabifhgcedcjoigdjaah');
assert.equal(manifest.background.service_worker, 'src/background/service-worker.js');
assert.equal(manifest.incognito, 'not_allowed');
assert.match(manifest.content_security_policy.extension_pages, /script-src 'self'/);
assert.doesNotMatch(manifest.content_security_policy.extension_pages, /unsafe-eval/);
assert.equal(manifest.action.default_popup, 'popup/popup.html');
assert.equal(manifest.options_page, 'options/options.html');
assert.deepEqual([...manifest.permissions].sort(), ['activeTab', 'scripting', 'storage'],
  'manifest permissions must stay on the reviewed Chrome permission allowlist');
assert(!manifest.host_permissions.includes('<all_urls>'));
for (const forbidden of ['tabs', 'downloads', 'clipboardRead', 'clipboardWrite', 'debugger',
  'nativeMessaging', 'sidePanel', 'webNavigation']) {
  assert(!manifest.permissions.includes(forbidden), `unexpected permission: ${forbidden}`);
}
assert(manifest.host_permissions.includes('http://127.0.0.1/*'));
for (const script of manifest.content_scripts) {
  assert(script.matches.every(pattern => pattern.includes('bilibili.com/video/')),
    'persistent content script escaped the Bilibili video-page scope');
}

const sandbox = {
  console,
  URL,
  URLSearchParams,
  TextEncoder,
  TextDecoder,
  AbortController,
  Date,
  Math,
  setTimeout,
  clearTimeout,
  setInterval,
  clearInterval,
  getComputedStyle: () => ({ display: 'block', visibility: 'visible' }),
  crypto: { randomUUID: () => '00000000-0000-4000-8000-000000000001' },
  chrome: { dom: { openOrClosedShadowRoot: () => null } },
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
for (const relative of [
  'src/shared/protocol.js',
  'src/shared/text.js',
  'src/content/extract.js',
  'src/content/bilibili.js',
  'src/content/context-builder.js',
  'src/background/lease-state.js',
]) {
  new vm.Script(read(relative), { filename: relative }).runInContext(sandbox);
}

const Protocol = sandbox.MarineChromeProtocol;
const Bilibili = sandbox.MarineChromeBilibili;
const Builder = sandbox.MarineChromeContextBuilder;
const LeaseState = sandbox.MarineChromeLeaseState;

assert.equal(Protocol.EXPECTED_EXTENSION_ID, manifestExtensionId);
assert.equal(Protocol.PAIRING_SESSION_KEY, 'marineChromePairingV1');
assert.equal(Protocol.MESSAGE_PAIR, 'marine-chrome/pair-interactive-v1');
assert.equal(Protocol.MESSAGE_CONFIRM_PAIR, 'marine-chrome/confirm-pair-v1');
assert.equal(Protocol.LEASE_RESTORE_SECONDS, 6);
const legacyPathExtensionId = 'mgpjnahoibmapmpdamdclfljhbfjcbpl';
assert(Protocol.extensionIdentityMatches(manifestExtensionId));
assert(!Protocol.extensionIdentityMatches(legacyPathExtensionId));
const identityMismatchDetail = Protocol.extensionIdentityMismatchDetail(legacyPathExtensionId);
assert(identityMismatchDetail.includes(legacyPathExtensionId));
assert(identityMismatchDetail.includes(manifestExtensionId));
assert(identityMismatchDetail.includes('chrome://extensions'));
assert(identityMismatchDetail.includes('移除此扩展'));
assert(identityMismatchDetail.includes('加载已解压的扩展程序'));
assert(identityMismatchDetail.includes('“重新加载”不能修复'));
assert(Protocol.trustedExtensionPageURL(
  'chrome-extension://' + manifestExtensionId + '/options/options.html',
  manifestExtensionId,
));
assert(Protocol.trustedOptionsPageURL(
  'chrome-extension://' + manifestExtensionId + '/options/options.html',
  manifestExtensionId,
));
assert(!Protocol.trustedOptionsPageURL(
  'chrome-extension://' + manifestExtensionId + '/popup/popup.html',
  manifestExtensionId,
));
assert(Protocol.trustedExtensionPageURL(
  'chrome-extension://' + manifestExtensionId + '/popup/popup.html',
  manifestExtensionId,
));
for (const untrustedPage of [
  'https://www.bilibili.com/video/BV1abc',
  'chrome-extension://' + manifestExtensionId + '/src/content/entry.js',
  'chrome-extension://' + manifestExtensionId + '/options/options.html?next=evil',
  'chrome-extension://' + 'a'.repeat(32) + '/options/options.html',
]) assert(!Protocol.trustedExtensionPageURL(untrustedPage, manifestExtensionId));

const proofToken = 'A'.repeat(42) + '_';
const proofNonce = 'A'.repeat(43);
const proof = createHmac('sha256', Buffer.from(proofToken, 'utf8'))
  .update(Protocol.serverProofInput(proofNonce), 'utf8').digest('base64url');
assert.equal(proof.length, 43);
assert.equal(Protocol.serverProofInput(proofNonce),
  'marine-chrome-server-v1\n' + proofNonce);
assert(!Protocol.pairingCredentialAuthorized({ challengeSeen: true, confirmed: false }));
assert(!Protocol.pairingCredentialAuthorized({ challengeSeen: false, confirmed: true }));
assert(Protocol.pairingCredentialAuthorized({ challengeSeen: true, confirmed: true }));

assert.equal(Protocol.normalizeAPIBase('http://127.0.0.1:47700/'),
  'http://127.0.0.1:47700');
const token = 'A'.repeat(42) + '_';
assert.equal(Protocol.normalizeToken('  ' + token + '  '), token);
assert.equal(Protocol.normalizeToken('short'), '');
for (const invalid of [
  'http://localhost:47700',
  'https://127.0.0.1:47700',
  'http://127.0.0.1',
  'http://127.0.0.1:47700/path',
  'http://127.0.0.2:47700',
]) assert.equal(Protocol.normalizeAPIBase(invalid), '');
assert(Protocol.validIdentifier('marine-chrome:web:page-1'));
assert(!Protocol.validIdentifier('page-1\n'));
assert(!Protocol.validIdentifier('x'.repeat(257)));

const unicode = '你'.repeat(1000);
const truncated = Protocol.truncateUtf8(unicode, 1000);
assert(Protocol.utf8Bytes(truncated) <= 1000);
assert(!truncated.endsWith('\ud800'));

const capturedAt = Protocol.nowSeconds();
assert.equal(Protocol.nextTimestamp(10, 11), 11);
assert(Protocol.nextTimestamp(11, 11) > 11);
const direct = Protocol.makeContext({
  sourceId: 'page-direct',
  revision: 1,
  contextId: Protocol.makeContextId('page-direct', 1, 'web'),
  capturedAt,
  page: { platform: 'web', url: 'https://example.com/article', title: '示例页面' },
  mode: 'direct',
  targetSummary: '当前网页',
  target: null,
  source: { kind: 'selection', text: '被选择的正文' },
});
assert(direct && Protocol.validateContext(direct));
assert.equal(direct.target, null);

const hugeCommentId = '18446744073709551615';
const reply = Protocol.makeContext({
  sourceId: 'page-reply',
  revision: 7,
  contextId: Protocol.makeContextId('page-reply', 7, 'bilibili'),
  capturedAt,
  page: { platform: 'bilibili', url: 'https://www.bilibili.com/video/BV1abc', title: '视频' },
  mode: 'reply',
  targetSummary: '@作者：「正文」',
  target: {
    id: hugeCommentId,
    authorName: '作者',
    text: '精确评论正文',
    parentId: null,
    rootId: '42',
  },
  source: { kind: 'comments', text: '评论上下文' },
});
assert(reply && Protocol.validateContext(reply));
assert.equal(reply.target.id, hugeCommentId);
assert.equal(Protocol.makeContext({
  sourceId: 'page-stale',
  revision: 1,
  contextId: 'marine-chrome:web:page-stale:1',
  capturedAt: capturedAt - Protocol.MAX_CAPTURE_AGE_SECONDS - 1,
  page: { platform: 'web', url: 'https://example.com/', title: '' },
  mode: 'direct',
  targetSummary: '',
  source: { kind: 'article', text: '正文' },
}), null);
assert.equal(Protocol.makeContext({
  sourceId: 'page-no-target',
  revision: 1,
  contextId: 'marine-chrome:web:page-no-target:1',
  capturedAt,
  page: { platform: 'web', url: 'https://example.com/', title: '' },
  mode: 'reply',
  targetSummary: '',
  source: { kind: 'article', text: '正文' },
}), null);
const forgedDirect = JSON.parse(JSON.stringify(direct));
forgedDirect.target = reply.target;
assert(!Protocol.validateContext(forgedDirect));
const heartbeat = Protocol.makeHeartbeat(reply);
assert.equal(heartbeat.revision, reply.revision);
assert.equal(heartbeat.contextId, reply.contextId);
assert.equal(heartbeat.targetId, hugeCommentId);

assert.equal(Bilibili.exactId(hugeCommentId, Number.MAX_SAFE_INTEGER + 1, false),
  hugeCommentId);
assert.equal(Bilibili.exactId('', Number.MAX_SAFE_INTEGER + 1, false), '');
assert.equal(Bilibili.normalizeRecord({
  rpid_str: hugeCommentId,
  rpid: Number.MAX_SAFE_INTEGER + 1,
  member: { uname: '作者' },
  content: { message: '正文' },
}).id, hugeCommentId);
assert.equal(Bilibili.normalizeRecord({
  rpid: Number.MAX_SAFE_INTEGER + 1,
  member: { uname: '作者' },
  content: { message: '正文' },
}).id, '');

function element(className = '', text = '', attributes = {}, backing = {}) {
  return {
    nodeType: 1,
    tagName: 'DIV',
    className,
    innerText: text,
    textContent: text,
    children: [],
    parentElement: null,
    isConnected: true,
    data: backing,
    getAttribute(name) { return Object.hasOwn(attributes, name) ? attributes[name] : null; },
  };
}

function commentBoundary(author, text, backing = {}) {
  const boundary = element('comment-item', '', {}, backing);
  const authorElement = element('user-name', author);
  const textElement = element('reply-content', text);
  authorElement.parentElement = boundary;
  textElement.parentElement = boundary;
  boundary.children.push(authorElement, textElement);
  return boundary;
}

const modernCommentRoot = element();
modernCommentRoot.tagName = 'BILI-COMMENTS';
const legacyCommentRoot = element('comment-container');
const modernCommentEditor = element('', '', { contenteditable: 'true' });
modernCommentEditor.parentElement = modernCommentRoot;
modernCommentEditor.getBoundingClientRect = () => ({ width: 480, height: 64 });
modernCommentRoot.children.push(modernCommentEditor);
const commentRootQueries = [];
const mixedCommentDocument = {
  nodeType: 9,
  location: { hostname: 'www.bilibili.com', pathname: '/video/BV1abc' },
  querySelector(selector) {
    commentRootQueries.push(selector);
    if (selector === 'bili-comments') return modernCommentRoot;
    if (selector === '.comment-container' || selector.includes(',')) return legacyCommentRoot;
    return null;
  },
};
assert.equal(Bilibili.commentSearchRoot(mixedCommentDocument), modernCommentRoot,
  'the active Bilibili component must win over an earlier legacy container');
assert.deepEqual(commentRootQueries, ['bili-comments'],
  'comment roots must be probed by compatibility priority, not as a selector list');
assert(Bilibili.isCommentEditor(modernCommentEditor, mixedCommentDocument),
  'an editor inside the modern comment component must remain eligible');

const unsafeBoundary = commentBoundary('作者', '正文', { rpid: Number.MAX_SAFE_INTEGER + 1 });
assert.equal(Bilibili.commentId(unsafeBoundary), '');
const stringBoundary = commentBoundary('作者', '正文', { rpid_str: hugeCommentId });
assert.equal(Bilibili.commentId(stringBoundary), hugeCommentId);
const conflictingBoundary = commentBoundary('作者', '正文', { rpid_str: '101', rpid: 102 });
assert.equal(Bilibili.commentId(conflictingBoundary), '');

function fakeDocument(boundaries) {
  return {
    nodeType: 9,
    children: boundaries,
    location: { hostname: 'www.bilibili.com', pathname: '/video/BV1abc' },
    querySelector: () => null,
  };
}

Bilibili._records.clear();
Bilibili._records.set('101', {
  id: '101', authorName: '同名作者', text: '相同正文', parentId: null, rootId: null,
});
const anonymousBoundary = commentBoundary('同名作者', '相同正文');
assert.equal(Bilibili.resolveTarget(anonymousBoundary, fakeDocument([anonymousBoundary])).id, '101');
Bilibili._records.set('102', {
  id: '102', authorName: '同名作者', text: '相同正文', parentId: null, rootId: null,
});
assert.equal(Bilibili.resolveTarget(anonymousBoundary, fakeDocument([anonymousBoundary])), null,
  'ambiguous API identities must fail closed');
Bilibili._records.delete('102');
const duplicateRendered = commentBoundary('同名作者', '相同正文');
assert.equal(Bilibili.resolveTarget(anonymousBoundary,
  fakeDocument([anonymousBoundary, duplicateRendered])), null,
  'ambiguous rendered identities must fail closed');

const selected = Builder.chooseGenericSource({
  defaultView: { getSelection: () => ({ toString: () => '用户明确选中的文字' }) },
}, { href: 'https://example.com/' });
assert.equal(selected.kind, 'selection');
assert.equal(selected.text, '用户明确选中的文字');
const bilibiliSelected = await Builder.chooseSource({
  defaultView: { getSelection: () => ({ toString: () => 'Bilibili 显式选区' }) },
}, {
  hostname: 'www.bilibili.com',
  pathname: '/video/BV1abc',
  href: 'https://www.bilibili.com/video/BV1abc',
}, 'bilibili');
assert.equal(bilibiliSelected.kind, 'selection');
assert.equal(bilibiliSelected.text, 'Bilibili 显式选区');

const sender = { tab: { id: 8, windowId: 3 }, documentId: 'doc-1' };
const lease = LeaseState.fromContext(reply, sender);
assert(LeaseState.validStored(lease));
assert.equal(lease.capturedAt, reply.capturedAt);
assert(LeaseState.exactPayload(lease, heartbeat));
assert(LeaseState.exactSender(lease, sender));
assert(!LeaseState.exactSender(lease,
  { tab: { id: 8, windowId: 4 }, documentId: 'doc-1' }));
assert(!LeaseState.exactSender(lease,
  { tab: { id: 8, windowId: 3 } }));
assert(!LeaseState.exactPayload(lease, { ...heartbeat, revision: heartbeat.revision + 1 }));
assert(!LeaseState.exactSender(lease,
  { tab: { id: 8, windowId: 3 }, documentId: 'doc-2' }));

const workerSource = read('src/background/service-worker.js');
const controllerSource = read('src/content/target-controller.js');
const optionsSource = read('options/options.js');
const optionsHTML = read('options/options.html');
const readmeSource = read('README.md');
const productSource = [
  read('src/content/entry.js'),
  read('src/content/target-controller.js'),
  read('src/main/network-capture.js'),
].join('\n');

function optionsElement() {
  const listeners = new Map();
  return {
    className: '',
    disabled: false,
    hidden: false,
    textContent: '',
    value: '',
    listeners,
    addEventListener(type, listener) { listeners.set(type, listener); },
  };
}

const mismatchElements = Object.fromEntries([
  'api-base', 'connect', 'confirm', 'use-address', 'reset-address', 'reauthorize',
  'status-dot', 'status-title', 'status-detail', 'extension-id',
].map(id => [id, optionsElement()]));
mismatchElements['api-base'].value = Protocol.DEFAULT_API_BASE;
let mismatchFetchCount = 0;
let mismatchMessageCount = 0;
let mismatchStorageReadCount = 0;
const mismatchOptionsSandbox = {
  AbortController,
  MarineChromeProtocol: Protocol,
  clearInterval,
  clearTimeout,
  console,
  document: { getElementById: id => mismatchElements[id] },
  fetch: async () => {
    mismatchFetchCount += 1;
    throw new Error('identity mismatch must stop before fetch');
  },
  setInterval,
  setTimeout,
  chrome: {
    runtime: {
      id: legacyPathExtensionId,
      lastError: null,
      sendMessage(_message, callback) {
        mismatchMessageCount += 1;
        callback({ ok: false });
      },
    },
    storage: {
      local: {
        async get() {
          mismatchStorageReadCount += 1;
          return {};
        },
      },
    },
  },
};
mismatchOptionsSandbox.globalThis = mismatchOptionsSandbox;
vm.createContext(mismatchOptionsSandbox);
new vm.Script(optionsSource, { filename: 'options/options.js' })
  .runInContext(mismatchOptionsSandbox);
await Promise.resolve();
for (const [id, event] of [
  ['connect', {}],
  ['confirm', { isTrusted: true }],
  ['use-address', {}],
  ['reset-address', {}],
  ['reauthorize', {}],
]) mismatchElements[id].listeners.get('click')(event);
await new Promise(resolve => setTimeout(resolve, 0));
assert.equal(mismatchFetchCount, 0,
  'mismatched options page must not contact the loopback gateway');
assert.equal(mismatchMessageCount, 0,
  'mismatched options page must not ask its worker to pair or query status');
assert.equal(mismatchStorageReadCount, 0,
  'identity gate must run before reading prior connection state');
for (const id of ['connect', 'confirm', 'use-address', 'reset-address', 'reauthorize']) {
  assert.equal(mismatchElements[id].disabled, true, `${id} must stay disabled after mismatch`);
}
assert.equal(mismatchElements['api-base'].disabled, true);
assert.equal(mismatchElements['status-title'].textContent, '需要重新安装 marine-chrome');
assert.equal(mismatchElements['status-detail'].textContent, identityMismatchDetail);
assert.equal(mismatchElements['extension-id'].textContent, legacyPathExtensionId);

assert.match(workerSource,
  /status\(\)[\s\S]*queryActivePage\(\{ type: Protocol\.MESSAGE_STATUS \}\)/);
assert.match(workerSource, /storage\.local\.setAccessLevel/);
assert.match(workerSource, /storage\.session\.setAccessLevel/);
assert.match(workerSource,
  /setAccessLevel[\s\S]*setAccessLevel[\s\S]*setConnection\('storageUnsafe'/);
assert.match(workerSource,
  /value\.capturedAt >= Protocol\.nowSeconds\(\) - Protocol\.LEASE_RESTORE_SECONDS/);
assert.match(workerSource, /current === expected/);
assert.match(workerSource, /const context = authorityPayload\(payload\)/);
assert.match(workerSource, /if \(!currentLease\) return \{ ok: true, skipped: true \}/);
assert.doesNotMatch(workerSource,
  /status\(\)[\s\S]{0,300}sendToActivePage\(\{ type: Protocol\.MESSAGE_STATUS \}\)/);
assert.match(workerSource, /captureActivePage\(\)[\s\S]*sendToActivePage/);
assert.match(optionsSource,
  /prepareLocalNetwork\(apiBase\)[\s\S]*MESSAGE_PAIR/);
assert.match(optionsSource,
  /async function connect[\s\S]*if \(!requireExpectedExtensionIdentity\(\)\) return;[\s\S]*prepareLocalNetwork\(apiBase\)/);
assert.match(optionsSource,
  /async function initializeOptions\(\)[\s\S]*if \(!requireExpectedExtensionIdentity\(\)\) return;[\s\S]*MESSAGE_STATUS/);
assert.match(optionsSource,
  /const disabled = busy \|\| !extensionIdentityMatches[\s\S]*button\.disabled = disabled/);
assert.match(optionsSource, /event\.isTrusted !== true/);
assert.match(optionsSource, /MESSAGE_CONFIRM_PAIR/);
assert.doesNotMatch(optionsSource, /MESSAGE_MANUAL_CONFIG|saveAPIBase|tokenInput/);
assert.match(workerSource,
  /let pairingPromise = null[\s\S]*async function exclusivePairing/);
assert.match(workerSource,
  /'\/v1\/marine-chrome\/pair\/request'[\s\S]*claimSecret/);
assert(workerSource.includes("'/v1/marine-chrome/prove'"));
assert.match(workerSource, /crypto\.subtle\.sign/);
assert.match(workerSource,
  /expectedServerProof\(token, nonce\)[\s\S]*encoder\.encode\(token\)[\s\S]*serverProofInput\(nonce\)/);
assert.match(workerSource, /async function proveServer[\s\S]*const nonce = randomClaimSecret\(\)/);
assert.match(workerSource,
  /pairingCredentialAuthorized\(latest\)[\s\S]*storage\.local\.set/);
assert.match(workerSource,
  /MESSAGE_CONFIRM_PAIR[\s\S]*trustedOptionsPage\(sender\)/);
assert.match(workerSource,
  /trustedExtensionPage\(sender\)[\s\S]*trustedExtensionPageURL/);
assert.match(workerSource,
  /existing\.force === !!force[\s\S]*existing\.apiBase === apiBase/);
assert.match(workerSource, /Protocol\.normalizeToken\(value\.token\)/);
assert.match(workerSource, /value\.paired !== true/);
assert.doesNotMatch(workerSource, /请重新加载(?: marine-chrome|扩展)/);
assert((workerSource.match(/extensionIdentityMismatchDetail\(chrome\.runtime\.id\)/g) || [])
  .length >= 3, 'every worker identity mismatch path must use the removal guidance');
assert.equal((workerSource.match(/headers\.Authorization/g) || []).length, 1,
  'only the proof-gated low-level request helper may add a bearer');
const authenticatedRequestSource = workerSource.slice(
  workerSource.indexOf('async function requestWithConfiguration'),
  workerSource.indexOf('async function requestAPI'),
);
assert(authenticatedRequestSource.indexOf('await proveServer(config)') >= 0);
assert(authenticatedRequestSource.indexOf('await proveServer(config)') <
  authenticatedRequestSource.indexOf('return performRequest'),
  'server proof must complete before the bearer request');
assert.match(optionsHTML, /<details class="advanced">/);
assert.doesNotMatch(optionsHTML, /<details[^>]*\sopen(?:\s|>)/);
const defaultOptionsUI = optionsHTML.slice(0, optionsHTML.indexOf('<details class="advanced">'));
assert.doesNotMatch(defaultOptionsUI, /Token|终端|命令取得/);
assert.match(optionsHTML, /id="confirm"[\s\S]*确认连接/);
assert.doesNotMatch(optionsHTML, /Token|token|手动配置/);
assert.match(readmeSource, /从无固定 ID 的 0\.1 开发版迁移/);
assert.match(readmeSource, /chrome:\/\/extensions[\s\S]*“移除”[\s\S]*加载已解压的扩展程序/);
assert.match(readmeSource, /不要只点击[\s\S]*“重新加载”/);
assert(readmeSource.includes(manifestExtensionId));
for (const forbidden of ['document.execCommand', 'InputEvent(', 'insertText', 'nativeMessaging']) {
  assert(!productSource.includes(forbidden), `unexpected page mutation capability: ${forbidden}`);
}
for (const route of [
  '/v1/marine-chrome/context',
  '/v1/marine-chrome/heartbeat',
]) assert(workerSource.includes(route));
assert(workerSource.includes("'DELETE'"));
assert(workerSource.includes('chrome.windows.onFocusChanged'));
assert.match(controllerSource,
  /scheduleFullPutRetry\(active\)[\s\S]*void this\.publish\(info\)/);

let nextTimer = 0;
const timerCallbacks = new Map();
let resolveSecondPut;
const secondPut = new Promise(resolve => { resolveSecondPut = resolve; });
let putCount = 0;
const putRevisions = [];
const retrySandbox = {
  console,
  globalThis: null,
  MarineChromeProtocol: Protocol,
  MarineChromeText: { isVisible: () => false },
  MarineChromeBilibili: { isVideoPage: () => false },
  MarineChromeContextBuilder: {
    build: input => Protocol.makeContext({
      sourceId: input.sourceId,
      revision: input.revision,
      contextId: input.contextId,
      capturedAt: Protocol.nowSeconds(),
      page: { platform: 'web', url: input.location.href, title: '重试页面' },
      mode: input.mode,
      targetSummary: '当前网页',
      target: input.target || null,
      source: { kind: 'article', text: '正文' },
    }),
  },
  setTimeout(callback) {
    const id = ++nextTimer;
    timerCallbacks.set(id, callback);
    return id;
  },
  clearTimeout(id) { timerCallbacks.delete(id); },
  setInterval: () => ++nextTimer,
  clearInterval: () => {},
  requestAnimationFrame: () => ++nextTimer,
};
retrySandbox.globalThis = retrySandbox;
vm.createContext(retrySandbox);
new vm.Script(controllerSource, { filename: 'target-controller.js' }).runInContext(retrySandbox);
const retryController = retrySandbox.MarineChromeTargetController.create(
  { documentElement: null, body: null },
  { href: 'https://example.com/retry' },
  async message => {
    if (message.op === 'delete') return { ok: true };
    if (message.op === 'put') {
      putCount += 1;
      putRevisions.push(message.payload.revision);
      if (putCount === 1) return { ok: false, status: 503, error: '暂不可用' };
      resolveSecondPut();
      return { ok: true, status: 200 };
    }
    return { ok: true };
  },
);
const firstResult = await retryController.publish({
  mode: 'direct', editor: null, boundary: null, target: null, semanticKey: 'manual', manual: true,
});
assert.equal(firstResult.retrying, true);
const retryCallback = Array.from(timerCallbacks.values()).at(-1);
assert.equal(typeof retryCallback, 'function');
retryCallback();
await secondPut;
await new Promise(resolve => setImmediate(resolve));
assert.deepEqual(putRevisions, [1, 2]);
assert.equal(retryController.active.revision, 2);
assert.equal(retryController.active.accepted, true);

console.log('marine-chrome smoke: OK');
