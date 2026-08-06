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
assert.equal(manifest.version, '0.2.3');
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
assert.deepEqual([...manifest.permissions].sort(), ['activeTab', 'dom', 'scripting', 'storage'],
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
const Extract = sandbox.MarineChromeExtract;
const Bilibili = sandbox.MarineChromeBilibili;
const Builder = sandbox.MarineChromeContextBuilder;
const LeaseState = sandbox.MarineChromeLeaseState;

assert.equal(Protocol.EXPECTED_EXTENSION_ID, manifestExtensionId);
assert.equal(Protocol.PAIRING_SESSION_KEY, 'marineChromePairingV1');
assert.equal(Protocol.MESSAGE_PAIR, 'marine-chrome/pair-interactive-v1');
assert.equal(Protocol.MESSAGE_CONFIRM_PAIR, 'marine-chrome/confirm-pair-v1');
assert.equal(Protocol.MESSAGE_FOREGROUND, 'marine-chrome/foreground-probe-v1');
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
const foregroundProbe = Protocol.makeForegroundProbe('https://example.com/retry');
assert.equal(foregroundProbe.protocolVersion, Protocol.VERSION);
assert.equal(foregroundProbe.url, 'https://example.com/retry');
assert(Protocol.validateForegroundProbe(foregroundProbe));
assert(!Protocol.validateForegroundProbe({ ...foregroundProbe, sourceText: '不应出现' }));

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

const emptyArticleDocument = {
  title: '',
  body: null,
  defaultView: { getSelection: () => ({ toString: () => '' }) },
  querySelector: () => null,
  querySelectorAll: () => [],
};
const genericURLOnly = Extract.articleSnapshot(
  emptyArticleDocument,
  { href: 'https://example.com/url-only' },
);
assert.equal(genericURLOnly.quality, 'url');
assert.equal(genericURLOnly.usable, true,
  'an explicit generic-page capture may use the URL as locator context');
assert.match(Builder.chooseGenericSource(
  emptyArticleDocument,
  { href: 'https://example.com/url-only' },
).text, /https:\/\/example\.com\/url-only/);

const bilibiliLocation = {
  hostname: 'www.bilibili.com',
  pathname: '/video/BV1ready',
  search: '',
  href: 'https://www.bilibili.com/video/BV1ready',
};
const bilibiliLocator = Bilibili.articleSnapshot(emptyArticleDocument, bilibiliLocation);
assert.equal(bilibiliLocator.quality, 'locator');
assert.equal(bilibiliLocator.ready, false,
  'a Bilibili URL alone must not stop the content-readiness loop');
const bilibiliMetadata = Bilibili.articleSnapshot(
  { ...emptyArticleDocument, title: '只有视频标题' },
  bilibiliLocation,
);
assert.equal(bilibiliMetadata.quality, 'metadata');
assert.equal(bilibiliMetadata.ready, false,
  'Bilibili title metadata alone must not masquerade as page content');
const descriptionElement = element('', '这是真实的视频简介');
const bilibiliArticle = Bilibili.articleSnapshot({
  ...emptyArticleDocument,
  title: '视频标题',
  querySelector(selector) {
    return selector.includes('.video-desc-container') ? descriptionElement : null;
  },
}, bilibiliLocation);
assert.equal(bilibiliArticle.quality, 'article');
assert.equal(bilibiliArticle.ready, true);
assert.match(bilibiliArticle.text, /真实的视频简介/);

function bilibiliContentHarness(initialFetch) {
  let fetchImplementation = initialFetch;
  let nextTimer = 0;
  const timers = new Map();
  const localSandbox = {
    console,
    URL,
    URLSearchParams,
    TextEncoder,
    TextDecoder,
    AbortController,
    Date,
    Math,
    document: { hidden: false },
    getComputedStyle: () => ({ display: 'block', visibility: 'visible' }),
    chrome: { dom: { openOrClosedShadowRoot: () => null } },
    setTimeout(callback, delay) {
      const id = ++nextTimer;
      timers.set(id, { callback, delay });
      return id;
    },
    clearTimeout(id) { timers.delete(id); },
    fetch() { return fetchImplementation(...arguments); },
  };
  localSandbox.globalThis = localSandbox;
  vm.createContext(localSandbox);
  for (const relative of [
    'src/shared/protocol.js',
    'src/shared/text.js',
    'src/content/extract.js',
    'src/content/bilibili.js',
    'src/content/context-builder.js',
  ]) new vm.Script(read(relative), { filename: relative }).runInContext(localSandbox);
  return {
    Bilibili: localSandbox.MarineChromeBilibili,
    Builder: localSandbox.MarineChromeContextBuilder,
    timers,
    setFetch(next) { fetchImplementation = next; },
    runTimer(delay) {
      const entry = Array.from(timers.entries()).find(([, timer]) => timer.delay === delay);
      assert(entry, `expected a ${delay}ms Bilibili timer`);
      timers.delete(entry[0]);
      entry[1].callback();
    },
  };
}

const readinessHarness = bilibiliContentHarness(async () => ({ ok: false }));
const notReadyContext = await readinessHarness.Builder.build({
  document: emptyArticleDocument,
  location: bilibiliLocation,
  sourceId: 'page-bilibili-waiting',
  revision: 1,
  contextId: 'marine-chrome:bilibili:page-bilibili-waiting:1',
  mode: 'direct',
  target: null,
});
assert.equal(notReadyContext, null,
  'the real Bilibili builder must suspend while only title/URL metadata exists');
readinessHarness.Bilibili.resetForNavigation();

let subtitleFetchCount = 0;
let subtitleFetchMode = 'empty';
const subtitleHarness = bilibiliContentHarness(async url => {
  subtitleFetchCount += 1;
  if (subtitleFetchMode === 'empty') return { ok: false };
  if (String(url).includes('/x/web-interface/view?')) {
    return { ok: true, json: async () => ({
      code: 0,
      data: { aid: 11, cid: 22, pages: [{ cid: 22 }] },
    }) };
  }
  if (String(url).includes('/x/player/wbi/v2?')) {
    return { ok: true, json: async () => ({
      code: 0,
      data: { subtitle: { subtitles: [{ subtitle_url: '//subtitle.test/ready.json' }] } },
    }) };
  }
  return { ok: true, json: async () => ({ body: [
    { content: '后来才出现的字幕' },
  ] }) };
});
let subtitleChanges = 0;
subtitleHarness.Bilibili.onDataChanged(() => { subtitleChanges += 1; });
assert.equal(await subtitleHarness.Bilibili.prefetchSubtitle(bilibiliLocation, true), '');
assert.equal(subtitleFetchCount, 1);
assert(Array.from(subtitleHarness.timers.values()).some(timer => timer.delay === 2000),
  'an empty first subtitle request must schedule the first backoff retry');
subtitleFetchMode = 'ready';
subtitleHarness.runTimer(2000);
for (let index = 0; index < 8; index += 1) {
  await new Promise(resolve => setImmediate(resolve));
}
assert.equal(subtitleFetchCount, 4,
  'the retry must repeat the complete view/player/subtitle request chain');
assert.equal(await subtitleHarness.Bilibili.prefetchSubtitle(bilibiliLocation, true),
  '后来才出现的字幕');
assert.equal(subtitleChanges, 1,
  'a newly available subtitle must notify the active context exactly once');
const fetchCountAfterCacheHit = subtitleFetchCount;
assert.equal(await subtitleHarness.Bilibili.prefetchSubtitle(bilibiliLocation, true),
  '后来才出现的字幕');
assert.equal(subtitleFetchCount, fetchCountAfterCacheHit,
  'a successful subtitle is cached for the exact BV/part');
assert.equal(subtitleHarness.Bilibili.subtitleRequest({
  pathname: '/video/BV1ready', search: '?p=2',
}).key, 'BV1ready:p2');
subtitleHarness.Bilibili.resetForNavigation();

let resolveOldView;
const staleSubtitleHarness = bilibiliContentHarness(async url => {
  const raw = String(url);
  if (raw.includes('bvid=BV1old')) {
    return new Promise(resolve => { resolveOldView = resolve; });
  }
  if (raw.includes('bvid=BV1new')) {
    return { ok: true, json: async () => ({
      code: 0,
      data: { aid: 202, cid: 303, pages: [{ cid: 303 }] },
    }) };
  }
  if (raw.includes('aid=202')) {
    return { ok: true, json: async () => ({
      code: 0,
      data: { subtitle: { subtitles: [{ subtitle_url: '//subtitle.test/new.json' }] } },
    }) };
  }
  if (raw.includes('aid=101')) {
    return { ok: true, json: async () => ({
      code: 0,
      data: { subtitle: { subtitles: [{ subtitle_url: '//subtitle.test/old.json' }] } },
    }) };
  }
  return { ok: true, json: async () => ({ body: [
    { content: raw.includes('/old.json') ? '过期字幕' : '当前字幕' },
  ] }) };
});
const oldSubtitleLocation = {
  hostname: 'www.bilibili.com',
  pathname: '/video/BV1old',
  search: '',
  href: 'https://www.bilibili.com/video/BV1old',
};
const newSubtitleLocation = {
  hostname: 'www.bilibili.com',
  pathname: '/video/BV1new',
  search: '?p=1',
  href: 'https://www.bilibili.com/video/BV1new?p=1',
};
const staleSubtitle = staleSubtitleHarness.Bilibili.prefetchSubtitle(
  oldSubtitleLocation,
  true,
);
assert.equal(typeof resolveOldView, 'function');
staleSubtitleHarness.Bilibili.resetForNavigation();
assert.equal(await staleSubtitleHarness.Bilibili.prefetchSubtitle(
  newSubtitleLocation,
  true,
), '当前字幕');
resolveOldView({ ok: true, json: async () => ({
  code: 0,
  data: { aid: 101, cid: 102, pages: [{ cid: 102 }] },
}) });
assert.equal(await staleSubtitle, '',
  'a subtitle response from the previous navigation generation must be discarded');
assert.equal(await staleSubtitleHarness.Bilibili.prefetchSubtitle(
  newSubtitleLocation,
  true,
), '当前字幕');
staleSubtitleHarness.Bilibili.resetForNavigation();

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

function extensionWorkerHarness() {
  const event = () => {
    const listeners = [];
    return {
      listeners,
      addListener(listener) { listeners.push(listener); },
    };
  };
  const runtimeMessages = event();
  const localState = {
    [Protocol.CONFIG_KEY]: {
      apiBase: Protocol.DEFAULT_API_BASE,
      token: proofToken,
    },
  };
  const sessionState = {};
  const storageArea = state => ({
    async setAccessLevel() {},
    async get(keys) {
      if (typeof keys === 'string') return { [keys]: state[keys] };
      if (Array.isArray(keys)) {
        return Object.fromEntries(keys.map(key => [key, state[key]]));
      }
      if (keys && typeof keys === 'object') {
        return Object.fromEntries(Object.entries(keys)
          .map(([key, fallback]) => [key, state[key] === undefined ? fallback : state[key]]));
      }
      return { ...state };
    },
    async set(value) { Object.assign(state, value); },
    async remove(keys) {
      for (const key of Array.isArray(keys) ? keys : [keys]) delete state[key];
    },
  });
  let nowSeconds = Math.floor(Protocol.nowSeconds());
  const contentTabId = 8;
  const tabsById = new Map();
  const activeTabIdsByWindow = new Map();
  let lastFocusedWindowId = 3;
  let nativeFocusedWindowId = 3;
  const initialTab = {
    id: 8,
    windowId: 3,
    active: true,
    url: 'https://example.com/retry',
  };
  tabsById.set(initialTab.id, initialTab);
  activeTabIdsByWindow.set(initialTab.windowId, initialTab.id);
  const updateActiveTab = value => {
    const prior = tabsById.get(value.id) || {};
    const next = { ...prior, ...value, active: true };
    const previousId = activeTabIdsByWindow.get(next.windowId);
    if (previousId !== undefined && previousId !== next.id) {
      const previous = tabsById.get(previousId);
      if (previous) tabsById.set(previousId, { ...previous, active: false });
    }
    tabsById.set(next.id, next);
    activeTabIdsByWindow.set(next.windowId, next.id);
    return next;
  };
  const activeTabForWindow = windowId => {
    const tabId = activeTabIdsByWindow.get(windowId);
    return tabId === undefined ? null : tabsById.get(tabId) || null;
  };
  let pageStatus = { ok: true, active: false, retrying: false };
  let fetchBehavior = 'success';
  let heldProof = null;
  let workerContext = null;
  const tabEvents = {
    onActivated: event(),
    onUpdated: event(),
    onRemoved: event(),
  };
  const windowEvents = { onFocusChanged: event() };
  const runtimeEvents = { onInstalled: event(), onStartup: event() };
  const storageEvents = { onChanged: event() };
  const workerSandbox = {
    AbortController,
    TextDecoder,
    TextEncoder,
    URL,
    Uint8Array,
    atob,
    btoa,
    clearInterval,
    clearTimeout,
    console,
    crypto: globalThis.crypto,
    Date: { now: () => nowSeconds * 1000 },
    fetch: async (rawURL, options = {}) => {
      if (fetchBehavior === 'network-error') throw new TypeError('loopback unavailable');
      const path = new URL(rawURL).pathname;
      if (path === '/v1/marine-chrome/prove') {
        const pending = heldProof;
        if (pending) {
          pending.arrivedResolve();
          await pending.gate;
          if (heldProof === pending) heldProof = null;
        }
        const nonce = JSON.parse(options.body).nonce;
        const proofValue = createHmac('sha256', Buffer.from(proofToken, 'utf8'))
          .update(workerSandbox.MarineChromeProtocol.serverProofInput(nonce), 'utf8')
          .digest('base64url');
        return {
          ok: true,
          status: 200,
          async json() {
            return { protocolVersion: Protocol.VERSION, proof: proofValue };
          },
        };
      }
      if (path === '/v1/marine-chrome/context' && options.method === 'PUT' &&
          fetchBehavior === 'terminal-conflict') {
        return {
          ok: false,
          status: 409,
          async json() { return { error: 'stale browser context' }; },
        };
      }
      return {
        ok: true,
        status: 200,
        async json() { return { ok: true }; },
      };
    },
    setInterval,
    setTimeout,
    chrome: {
      runtime: {
        id: manifestExtensionId,
        getURL: value => value,
        openOptionsPage: async () => {},
        onMessage: runtimeMessages,
        ...runtimeEvents,
      },
      scripting: { executeScript: async () => {} },
      storage: {
        local: storageArea(localState),
        session: storageArea(sessionState),
        ...storageEvents,
      },
      tabs: {
        ...tabEvents,
        async query(query) {
          let windowId = query.windowId;
          if (query.lastFocusedWindow === true || windowId === undefined) {
            windowId = lastFocusedWindowId;
          }
          const tab = activeTabForWindow(windowId);
          return tab ? [{ ...tab }] : [];
        },
        async get(tabId) {
          const tab = tabsById.get(tabId);
          if (!tab) throw new Error('tab not found');
          return { ...tab };
        },
        async sendMessage(tabId) {
          if (!tabsById.has(tabId)) throw new Error('tab not found');
          return { ...pageStatus };
        },
      },
      windows: {
        WINDOW_ID_NONE: -1,
        ...windowEvents,
        async get(windowId) {
          return { id: windowId, focused: nativeFocusedWindowId === windowId };
        },
        async getLastFocused() {
          return {
            id: lastFocusedWindowId,
            focused: nativeFocusedWindowId === lastFocusedWindowId,
          };
        },
      },
    },
    importScripts: (...paths) => {
      for (const path of paths) {
        new vm.Script(read(path), { filename: path }).runInContext(workerContext);
      }
    },
  };
  workerSandbox.globalThis = workerSandbox;
  workerContext = vm.createContext(workerSandbox);
  new vm.Script(workerSource, { filename: 'src/background/service-worker.js' })
    .runInContext(workerContext);
  const listener = runtimeMessages.listeners[0];
  assert.equal(typeof listener, 'function');

  function send(message, sender) {
    return new Promise(resolve => {
      const pending = listener(message, sender, resolve);
      assert.equal(pending, true, 'worker operation must keep the response channel open');
    });
  }

  function contentSender() {
    const tab = tabsById.get(contentTabId);
    return {
      id: manifestExtensionId,
      url: tab.url,
      frameId: 0,
      documentId: 'doc-1',
      tab: { ...tab },
    };
  }

  return {
    protocol: workerSandbox.MarineChromeProtocol,
    sendContentMessage(message) { return send(message, contentSender()); },
    sendContext(op, payload) {
      return send({ type: Protocol.MESSAGE_CONTEXT, op, payload }, contentSender());
    },
    sendForeground(payload) {
      return send({ type: Protocol.MESSAGE_FOREGROUND, payload }, contentSender());
    },
    sendStatus() {
      return send({ type: Protocol.MESSAGE_STATUS }, {
        id: manifestExtensionId,
        url: 'chrome-extension://' + manifestExtensionId + '/popup/popup.html',
      });
    },
    setNativeFocused(value) {
      nativeFocusedWindowId = value ? lastFocusedWindowId : null;
    },
    openActionPopup() {
      nativeFocusedWindowId = null;
      for (const listener of windowEvents.onFocusChanged.listeners) {
        listener(-1);
      }
    },
    focusWindow(windowId) {
      lastFocusedWindowId = windowId;
      nativeFocusedWindowId = windowId;
      for (const listener of windowEvents.onFocusChanged.listeners) {
        listener(windowId);
      }
    },
    setFetchBehavior(value) { fetchBehavior = value; },
    setPageStatus(value) { pageStatus = { ok: true, ...value }; },
    setActiveTab(value) { updateActiveTab(value); },
    activateTab(value) {
      const activeTab = updateActiveTab(value);
      for (const listener of tabEvents.onActivated.listeners) {
        listener({ tabId: activeTab.id, windowId: activeTab.windowId });
      }
    },
    navigateTab(tabId, changeInfo = { status: 'loading' }) {
      const previous = tabsById.get(tabId);
      if (!previous) throw new Error('tab not found');
      const next = { ...previous };
      if (typeof changeInfo.url === 'string') next.url = changeInfo.url;
      if (typeof changeInfo.pendingUrl === 'string') next.pendingUrl = changeInfo.pendingUrl;
      tabsById.set(tabId, next);
      for (const listener of tabEvents.onUpdated.listeners) {
        listener(tabId, { ...changeInfo }, { ...next });
      }
    },
    advance(seconds) { nowSeconds += seconds; },
    holdNextProof() {
      let arrivedResolve;
      let release;
      const arrived = new Promise(resolve => { arrivedResolve = resolve; });
      const gate = new Promise(resolve => { release = resolve; });
      heldProof = { arrived, arrivedResolve, gate, release };
      return heldProof;
    },
  };
}

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
  /status\(\)[\s\S]*queryActivePage\(activeTab, \{ type: Protocol\.MESSAGE_STATUS \}\)/);
assert.match(workerSource, /storage\.local\.setAccessLevel/);
assert.match(workerSource, /storage\.session\.setAccessLevel/);
assert.match(workerSource,
  /setAccessLevel[\s\S]*setAccessLevel[\s\S]*setConnection\('storageUnsafe'/);
assert.match(workerSource,
  /lease\.capturedAt >= Protocol\.nowSeconds\(\) - Protocol\.LEASE_RESTORE_SECONDS/);
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
assert.match(workerSource, /lastFocusedWindow:\s*true/);
assert.doesNotMatch(workerSource, /currentWindow:\s*true/);
assert.match(workerSource,
  /function retryableAuthorityFailure[\s\S]*retryable:\s*true[\s\S]*retryReason/);
assert.match(workerSource,
  /message\.type === Protocol\.MESSAGE_FOREGROUND[\s\S]{0,500}operation = handleForegroundProbe\(message\.payload, sender\)/);
assert.match(workerSource,
  /async function handleForegroundProbe[\s\S]*validateForegroundProbe[\s\S]*foregroundSender/);
assert.match(workerSource,
  /const leaseActive = await queue\(async \(\) => \{[\s\S]*!leaseIsFresh\(currentLease\)[\s\S]*currentLease = null[\s\S]*persistSession/);
assert.match(workerSource,
  /currentLease\.tabId === activeTab\.id[\s\S]*currentLease\.windowId === activeTab\.windowId[\s\S]*LeaseState\.exactPayload\(currentLease, page\)/);
assert.match(workerSource,
  /tabActivationSequences\.get\(windowId\)[\s\S]*displacedAtEvent[\s\S]*interruptedPut[\s\S]*activeTabId !== tabId[\s\S]*displacedLease[\s\S]*documentId !== displacedLease\.documentId/);
assert.match(controllerSource,
  /scheduleFullPutRetry\(active, delayMilliseconds\)[\s\S]*captureGeneric\(active\.intentURL\)[\s\S]*activateEditor\(active\.editor, true\)/);
assert.match(controllerSource,
  /retryIntentIsCurrent[\s\S]*deepActiveElement[\s\S]*activateEditor\(active\.editor, true\)/);
assert.match(controllerSource,
  /captureGeneric\(intentURL\)[\s\S]*currentURL !== expectedURL[\s\S]*manual-url-changed/);
assert.match(controllerSource,
  /status\(\)[\s\S]*sourceId:[\s\S]*revision:[\s\S]*contextId:/);

const workerHarness = extensionWorkerHarness();
const WorkerProtocol = workerHarness.protocol;
const workerContextPayload = WorkerProtocol.makeContext({
  sourceId: 'page-worker',
  revision: 1,
  contextId: WorkerProtocol.makeContextId('page-worker', 1, 'web'),
  capturedAt: WorkerProtocol.nowSeconds(),
  page: {
    platform: 'web',
    url: 'https://example.com/retry',
    title: '后台回归测试',
  },
  mode: 'direct',
  targetSummary: '当前网页',
  target: null,
  source: { kind: 'article', text: '正文' },
});
assert(workerContextPayload);

workerHarness.setActiveTab({
  id: 9,
  windowId: 4,
  url: 'https://example.com/other-window',
});
workerHarness.focusWindow(4);
await new Promise(resolve => setImmediate(resolve));
const workerBackgroundProbe = await workerHarness.sendForeground(foregroundProbe);
assert.equal(workerBackgroundProbe.ok, true);
assert.equal(workerBackgroundProbe.foreground, false);
const workerBackgroundResult = await workerHarness.sendContext('put', workerContextPayload);
assert.equal(workerBackgroundResult.status, 409);
assert.equal(workerBackgroundResult.retryable, true);
assert.equal(workerBackgroundResult.retryReason, 'page-not-foreground');
workerHarness.focusWindow(3);
await new Promise(resolve => setImmediate(resolve));

const inFlightWorkerHarness = extensionWorkerHarness();
const heldPutProof = inFlightWorkerHarness.holdNextProof();
const interruptedPutPromise = inFlightWorkerHarness.sendContext('put', workerContextPayload);
await heldPutProof.arrived;
inFlightWorkerHarness.activateTab({
  id: 9,
  windowId: 3,
  url: 'https://example.com/temporary-tab',
});
inFlightWorkerHarness.activateTab({
  id: 8,
  windowId: 3,
  url: 'https://example.com/retry',
});
heldPutProof.release();
const interruptedPutResult = await interruptedPutPromise;
assert.equal(interruptedPutResult.retryable, true);
assert.equal(interruptedPutResult.retryReason, 'page-lost-foreground',
  'a rapid away-and-back activation must invalidate an in-flight PUT');

workerHarness.openActionPopup();
await new Promise(resolve => setImmediate(resolve));
const workerPopupProbe = await workerHarness.sendForeground(foregroundProbe);
assert.equal(workerPopupProbe.ok, true);
assert.equal(workerPopupProbe.foreground, true,
  'an action popup leaves its parent tab authoritative even though the native browser window is not focused');
workerHarness.setFetchBehavior('network-error');
const workerNetworkResult = await workerHarness.sendContext('put', workerContextPayload);
assert.equal(workerNetworkResult.status, 0);
assert.equal(workerNetworkResult.retryable, true,
  'worker transport failures must remain recoverable');

workerHarness.setFetchBehavior('terminal-conflict');
const workerConflictResult = await workerHarness.sendContext('put', workerContextPayload);
assert.equal(workerConflictResult.status, 409);
assert.equal(workerConflictResult.retryable, false,
  'an unstructured server conflict must remain terminal');

workerHarness.setFetchBehavior('success');
const workerPutResult = await workerHarness.sendContext('put', workerContextPayload);
assert.equal(workerPutResult.ok, true);
workerHarness.setPageStatus({
  active: true,
  retrying: false,
  sourceId: workerContextPayload.sourceId,
  revision: workerContextPayload.revision,
  contextId: workerContextPayload.contextId,
});
workerHarness.focusWindow(3);
await new Promise(resolve => setImmediate(resolve));
workerHarness.openActionPopup();
await new Promise(resolve => setImmediate(resolve));
const workerActiveStatus = await workerHarness.sendStatus();
assert.equal(workerActiveStatus.leaseActive, true,
  'WINDOW_ID_NONE from an action popup must not revoke the selected page lease');

workerHarness.advance(7);
const heldHeartbeatProof = workerHarness.holdNextProof();
const workerHeartbeatPromise = workerHarness.sendContext(
  'heartbeat',
  WorkerProtocol.makeHeartbeat(workerContextPayload),
);
await heldHeartbeatProof.arrived;
const workerRacingStatusPromise = workerHarness.sendStatus();
await new Promise(resolve => setImmediate(resolve));
heldHeartbeatProof.release();
const [workerHeartbeatResult, workerRacingStatus] = await Promise.all([
  workerHeartbeatPromise,
  workerRacingStatusPromise,
]);
assert.equal(workerHeartbeatResult.ok, true);
assert.equal(workerRacingStatus.leaseActive, true,
  'status polling must wait for an in-flight heartbeat before pruning a lease');

workerHarness.setActiveTab({
  id: 9,
  windowId: 4,
  url: 'https://example.com/other',
});
workerHarness.focusWindow(4);
await new Promise(resolve => setImmediate(resolve));
workerHarness.setPageStatus({
  active: true,
  retrying: false,
  sourceId: workerContextPayload.sourceId,
  revision: workerContextPayload.revision,
  contextId: workerContextPayload.contextId,
});
const workerOtherWindowLeaseStatus = await workerHarness.sendStatus();
assert.equal(workerOtherWindowLeaseStatus.leaseActive, false,
  'a live lease from another tab/window must not be reported as the current page');

workerHarness.setActiveTab({
  id: 8,
  windowId: 3,
  url: 'https://example.com/retry',
});
workerHarness.focusWindow(3);
await new Promise(resolve => setImmediate(resolve));
workerHarness.setPageStatus({
  active: true,
  retrying: false,
  sourceId: workerContextPayload.sourceId,
  revision: workerContextPayload.revision + 1,
  contextId: workerContextPayload.contextId,
});
const workerWrongIdentityStatus = await workerHarness.sendStatus();
assert.equal(workerWrongIdentityStatus.leaseActive, false,
  'a content identity mismatch must not inherit the tab lease');
workerHarness.setPageStatus({
  active: true,
  retrying: false,
  sourceId: workerContextPayload.sourceId,
  revision: workerContextPayload.revision,
  contextId: workerContextPayload.contextId,
});

workerHarness.activateTab({
  id: 9,
  windowId: 3,
  url: 'https://example.com/temporary-tab',
});
workerHarness.activateTab({
  id: 8,
  windowId: 3,
  url: 'https://example.com/retry',
});
await new Promise(resolve => setImmediate(resolve));
const workerFastReturnStatus = await workerHarness.sendStatus();
assert.equal(workerFastReturnStatus.leaseActive, false,
  'a rapid away-and-back activation must still revoke the earlier page lease');

const tabSwitchWorkerHarness = extensionWorkerHarness();
const tabSwitchPut = await tabSwitchWorkerHarness.sendContext('put', workerContextPayload);
assert.equal(tabSwitchPut.ok, true);
tabSwitchWorkerHarness.setPageStatus({
  active: true,
  retrying: false,
  sourceId: workerContextPayload.sourceId,
  revision: workerContextPayload.revision,
  contextId: workerContextPayload.contextId,
});
tabSwitchWorkerHarness.activateTab({
  id: 10,
  windowId: 3,
  url: 'https://example.com/same-window-tab',
});
await new Promise(resolve => setImmediate(resolve));
const tabSwitchStatus = await tabSwitchWorkerHarness.sendStatus();
assert.equal(tabSwitchStatus.leaseActive, false,
  'selecting another tab in the authoritative window must revoke the old page lease');
const tabSwitchProbe = await tabSwitchWorkerHarness.sendForeground(foregroundProbe);
assert.equal(tabSwitchProbe.foreground, false,
  'a tab may remain loaded but is not authoritative after a same-window tab switch');

const navigationWorkerHarness = extensionWorkerHarness();
const navigationPut = await navigationWorkerHarness.sendContext('put', workerContextPayload);
assert.equal(navigationPut.ok, true);
navigationWorkerHarness.setPageStatus({
  active: true,
  retrying: false,
  sourceId: workerContextPayload.sourceId,
  revision: workerContextPayload.revision,
  contextId: workerContextPayload.contextId,
});
navigationWorkerHarness.navigateTab(8, { status: 'loading' });
await new Promise(resolve => setImmediate(resolve));
const navigationStatus = await navigationWorkerHarness.sendStatus();
assert.equal(navigationStatus.leaseActive, false,
  'navigation start must revoke the exact document lease even before its URL changes');
const navigationHeartbeat = await navigationWorkerHarness.sendContext(
  'heartbeat',
  WorkerProtocol.makeHeartbeat(workerContextPayload),
);
assert.equal(navigationHeartbeat.retryable, true);
assert.equal(navigationHeartbeat.retryReason, 'lease-reacquire');

workerHarness.setActiveTab({
  id: 9,
  windowId: 4,
  url: 'https://example.com/other',
});
workerHarness.focusWindow(4);
await new Promise(resolve => setImmediate(resolve));
workerHarness.setPageStatus({
  active: false,
  retrying: true,
  retryDetail: '网页已不在前台',
  retryReason: 'page-not-foreground',
});
const workerOtherTabStatus = await workerHarness.sendStatus();
assert.equal(workerOtherTabStatus.leaseActive, false,
  'a retrying page must not be reported as leased');
assert.equal(workerOtherTabStatus.pageRetrying, true);

function retryContext(input) {
  return Protocol.makeContext({
    sourceId: input.sourceId,
    revision: input.revision,
    contextId: input.contextId,
    capturedAt: Protocol.nowSeconds(),
    page: { platform: 'web', url: input.location.href, title: '重试页面' },
    mode: input.mode,
    targetSummary: '当前网页',
    target: input.target || null,
    source: { kind: 'article', text: '正文' },
  });
}

function retryHarness(build, sendMessage, options = {}) {
  let nextTimer = 0;
  const timeoutCallbacks = new Map();
  const intervalCallbacks = new Map();
  const documentLike = {
    activeElement: null,
    body: null,
    documentElement: null,
    hidden: false,
    focused: true,
    hasFocus() { return this.focused; },
  };
  const locationLike = { href: 'https://example.com/retry' };
  const retrySandbox = {
    console,
    globalThis: null,
    MarineChromeProtocol: Protocol,
    MarineChromeText: {
      deepActiveElement: value => value.activeElement,
      isEditor: value => !!value && value.isConnected === true,
      isVisible: () => true,
    },
    MarineChromeBilibili: {
      isVideoPage: () => options.bilibili === true,
      isCommentEditor: value => !!value && value.isConnected === true,
    },
    MarineChromeContextBuilder: { build },
    setTimeout(callback) {
      const id = ++nextTimer;
      timeoutCallbacks.set(id, callback);
      return id;
    },
    clearTimeout(id) { timeoutCallbacks.delete(id); },
    setInterval(callback) {
      const id = ++nextTimer;
      intervalCallbacks.set(id, callback);
      return id;
    },
    clearInterval(id) { intervalCallbacks.delete(id); },
    requestAnimationFrame: () => ++nextTimer,
  };
  retrySandbox.globalThis = retrySandbox;
  vm.createContext(retrySandbox);
  new vm.Script(controllerSource, { filename: 'target-controller.js' })
    .runInContext(retrySandbox);
  return {
    controller: retrySandbox.MarineChromeTargetController.create(
      documentLike,
      locationLike,
      sendMessage,
    ),
    documentLike,
    locationLike,
    intervalCallbacks,
    timeoutCallbacks,
  };
}

async function runLatestTimeout(harness) {
  const entry = Array.from(harness.timeoutCallbacks.entries()).at(-1);
  assert(entry, 'expected a pending retry timeout');
  harness.timeoutCallbacks.delete(entry[0]);
  entry[1]();
  await new Promise(resolve => setImmediate(resolve));
}

for (const transient of [
  { status: 503, error: '暂不可用' },
  { status: 0, error: '连接 RIMES 超时', retryable: true },
  {
    status: 409,
    error: '网页已不在前台',
    retryable: true,
    retryReason: 'page-not-foreground',
  },
]) {
  let putCount = 0;
  const putRevisions = [];
  const harness = retryHarness(retryContext, async message => {
    if (message.op === 'delete') return { ok: true };
    if (message.op === 'put') {
      putCount += 1;
      putRevisions.push(message.payload.revision);
      if (putCount === 1) return { ok: false, ...transient };
      return { ok: true, status: 200 };
    }
    return { ok: true };
  });
  const firstResult = await harness.controller.captureGeneric();
  assert.equal(firstResult.retrying, true);
  assert.equal(harness.controller.active.context, null,
    'retry state must not retain rejected page text');
  await runLatestTimeout(harness);
  assert.deepEqual(putRevisions, [1, 2]);
  assert.equal(harness.controller.active.revision, 2);
  assert.equal(harness.controller.active.accepted, true);
}

let delayedBuildCount = 0;
const delayedHarness = retryHarness(input => {
  delayedBuildCount += 1;
  return delayedBuildCount === 1 ? null : retryContext(input);
}, async () => ({ ok: true, status: 200 }));
const delayedResult = await delayedHarness.controller.captureGeneric();
assert.equal(delayedResult.retrying, true);
await runLatestTimeout(delayedHarness);
assert.equal(delayedBuildCount, 2);
assert.equal(delayedHarness.controller.active.accepted, true);

let foregroundBuildCount = 0;
let foregroundPutCount = 0;
let foregroundProbeCount = 0;
const foregroundHarness = retryHarness(input => {
  foregroundBuildCount += 1;
  return retryContext(input);
}, async message => {
  if (message.type === Protocol.MESSAGE_FOREGROUND) {
    foregroundProbeCount += 1;
    return { ok: true, status: 200, foreground: foregroundProbeCount >= 2 };
  }
  if (message.op !== 'put') return { ok: true };
  foregroundPutCount += 1;
  return foregroundPutCount === 1
    ? {
      ok: false,
      status: 409,
      error: '网页已不在前台',
      retryable: true,
      retryReason: 'page-not-foreground',
    }
    : { ok: true, status: 200 };
});
await foregroundHarness.controller.captureGeneric();
foregroundHarness.documentLike.focused = false;
await runLatestTimeout(foregroundHarness);
assert.equal(foregroundPutCount, 1,
  'a negative foreground probe must not rebuild or PUT page content');
assert.equal(foregroundBuildCount, 1);
await runLatestTimeout(foregroundHarness);
assert.equal(foregroundPutCount, 2);
assert.equal(foregroundBuildCount, 2);
assert.equal(foregroundProbeCount, 2);
assert.equal(foregroundHarness.controller.active.accepted, true);

const popupWorkerHarness = extensionWorkerHarness();
popupWorkerHarness.setActiveTab({
  id: 9,
  windowId: 4,
  url: 'https://example.com/other-window',
});
popupWorkerHarness.focusWindow(4);
await new Promise(resolve => setImmediate(resolve));
let popupBuildCount = 0;
const popupFocusHarness = retryHarness(input => {
  popupBuildCount += 1;
  return retryContext(input);
}, message => popupWorkerHarness.sendContentMessage(message));
const popupFirstResult = await popupFocusHarness.controller.captureGeneric();
assert.equal(popupFirstResult.retrying, true);
popupFocusHarness.documentLike.focused = false;
popupWorkerHarness.focusWindow(3);
popupWorkerHarness.openActionPopup();
await new Promise(resolve => setImmediate(resolve));
await runLatestTimeout(popupFocusHarness);
for (let attempt = 0; attempt < 10 &&
    !popupFocusHarness.controller.active.accepted; attempt += 1) {
  await new Promise(resolve => setImmediate(resolve));
}
assert.equal(popupBuildCount, 2);
assert.equal(popupFocusHarness.controller.active.revision, 2);
assert.equal(popupFocusHarness.controller.active.accepted, true,
  'an action popup may own DOM focus while its Chrome page remains authoritative');

popupFocusHarness.controller.contextDataChanged();
await runLatestTimeout(popupFocusHarness);
assert.equal(popupBuildCount, 2,
  'new page data must not be extracted while the action popup owns DOM focus');
assert.equal(popupFocusHarness.controller.contextDataDirty, true,
  'page data arriving behind the popup must stay pending');
popupWorkerHarness.focusWindow(3);
popupFocusHarness.documentLike.focused = true;
popupFocusHarness.controller.rearmFocusedEditor();
for (let attempt = 0; attempt < 20 &&
    (!popupFocusHarness.controller.active ||
      popupFocusHarness.controller.active.revision < 3 ||
      !popupFocusHarness.controller.active.accepted); attempt += 1) {
  await new Promise(resolve => setImmediate(resolve));
}
assert.equal(popupBuildCount, 3,
  'restoring page focus must rebuild context from data observed behind the popup');
assert.equal(popupFocusHarness.controller.active.revision, 3);
assert.equal(popupFocusHarness.controller.active.accepted, true);
assert.equal(popupFocusHarness.controller.contextDataDirty, false,
  'the fresh extraction must consume the pending data marker');

let unavailableProbeBuildCount = 0;
const unavailableProbeHarness = retryHarness(input => {
  unavailableProbeBuildCount += 1;
  return retryContext(input);
}, async message => {
  if (message.type === Protocol.MESSAGE_FOREGROUND) {
    return { ok: false, status: 0, error: '扩展后台暂时无响应' };
  }
  if (message.op === 'put') {
    return {
      ok: false,
      status: 409,
      error: '网页已不在前台',
      retryable: true,
      retryReason: 'page-not-foreground',
    };
  }
  return { ok: true };
});
await unavailableProbeHarness.controller.captureGeneric();
unavailableProbeHarness.documentLike.focused = false;
await runLatestTimeout(unavailableProbeHarness);
assert.equal(unavailableProbeBuildCount, 1,
  'a failed foreground probe must not re-read page content');
assert.equal(unavailableProbeHarness.controller.active.retrying, true);
assert.equal(unavailableProbeHarness.timeoutCallbacks.size, 1,
  'a transient probe failure must remain suspended and keep polling');

let terminalProbeBuildCount = 0;
const terminalProbeHarness = retryHarness(input => {
  terminalProbeBuildCount += 1;
  return retryContext(input);
}, async message => {
  if (message.type === Protocol.MESSAGE_FOREGROUND) {
    return { ok: false, status: 400, error: '无效的前台探测请求' };
  }
  if (message.op === 'put') {
    return {
      ok: false,
      status: 409,
      error: '网页已不在前台',
      retryable: true,
      retryReason: 'page-not-foreground',
    };
  }
  return { ok: true };
});
await terminalProbeHarness.controller.captureGeneric();
terminalProbeHarness.documentLike.focused = false;
await runLatestTimeout(terminalProbeHarness);
assert.equal(terminalProbeBuildCount, 1);
assert.equal(terminalProbeHarness.controller.active, null,
  'a malformed or unauthorized foreground probe must terminate the intent');
assert.equal(terminalProbeHarness.timeoutCallbacks.size, 0);

let pendingProbeResolve;
let pendingProbeStartedResolve;
const pendingProbeStarted = new Promise(resolve => { pendingProbeStartedResolve = resolve; });
let pendingProbeBuildCount = 0;
const pendingProbeHarness = retryHarness(input => {
  pendingProbeBuildCount += 1;
  return retryContext(input);
}, async message => {
  if (message.type === Protocol.MESSAGE_FOREGROUND) {
    pendingProbeStartedResolve();
    return new Promise(resolve => { pendingProbeResolve = resolve; });
  }
  if (message.op === 'put') {
    return {
      ok: false,
      status: 409,
      error: '网页已不在前台',
      retryable: true,
      retryReason: 'page-not-foreground',
    };
  }
  return { ok: true };
});
await pendingProbeHarness.controller.captureGeneric();
pendingProbeHarness.documentLike.focused = false;
await runLatestTimeout(pendingProbeHarness);
await pendingProbeStarted;
await pendingProbeHarness.controller.clear('navigation');
pendingProbeResolve({ ok: true, status: 200, foreground: true });
await new Promise(resolve => setImmediate(resolve));
assert.equal(pendingProbeBuildCount, 1);
assert.equal(pendingProbeHarness.controller.active, null,
  'a late positive probe must not revive a cleared intent');
assert.equal(pendingProbeHarness.timeoutCallbacks.size, 0);

const probeRaceWorkerHarness = extensionWorkerHarness();
probeRaceWorkerHarness.setActiveTab({
  id: 9,
  windowId: 4,
  url: 'https://example.com/other-window',
});
probeRaceWorkerHarness.focusWindow(4);
await new Promise(resolve => setImmediate(resolve));
let probeRaceBuildCount = 0;
let probeRaceSecondBuildResolve;
let probeRaceSecondBuildStartedResolve;
const probeRaceSecondBuildStarted = new Promise(resolve => {
  probeRaceSecondBuildStartedResolve = resolve;
});
let probeRaceSecondInput = null;
const probeRaceHarness = retryHarness(input => {
  probeRaceBuildCount += 1;
  if (probeRaceBuildCount === 1) return retryContext(input);
  probeRaceSecondInput = input;
  probeRaceSecondBuildStartedResolve();
  return new Promise(resolve => { probeRaceSecondBuildResolve = resolve; });
}, message => probeRaceWorkerHarness.sendContentMessage(message));
await probeRaceHarness.controller.captureGeneric();
probeRaceHarness.documentLike.focused = false;
probeRaceWorkerHarness.focusWindow(3);
probeRaceWorkerHarness.openActionPopup();
await new Promise(resolve => setImmediate(resolve));
await runLatestTimeout(probeRaceHarness);
await probeRaceSecondBuildStarted;
probeRaceWorkerHarness.activateTab({
  id: 9,
  windowId: 3,
  url: 'https://example.com/another-tab',
});
probeRaceSecondBuildResolve(retryContext(probeRaceSecondInput));
await new Promise(resolve => setImmediate(resolve));
await new Promise(resolve => setImmediate(resolve));
assert.equal(probeRaceHarness.controller.active.accepted, false);
assert.equal(probeRaceHarness.controller.active.retrying, true);
assert.equal(probeRaceHarness.controller.active.context, null,
  'a positive probe is only a hint; the PUT must still reject a later tab switch');

for (const heartbeatFailure of [
  {
    ok: false,
    status: 409,
    error: '网页已不在前台',
    retryable: true,
    retryReason: 'page-not-foreground',
  },
  {
    ok: false,
    status: 0,
    error: '连接 RIMES 超时',
    retryable: true,
    retryReason: 'network-unavailable',
  },
]) {
  let heartbeatPutCount = 0;
  const heartbeatHarness = retryHarness(retryContext, async message => {
    if (message.op === 'put') {
      heartbeatPutCount += 1;
      return { ok: true, status: 200 };
    }
    if (message.op === 'heartbeat') return heartbeatFailure;
    return { ok: true };
  });
  await heartbeatHarness.controller.captureGeneric();
  const heartbeatCallback = Array.from(heartbeatHarness.intervalCallbacks.values()).at(-1);
  assert.equal(typeof heartbeatCallback, 'function');
  await heartbeatCallback();
  assert.equal(heartbeatHarness.controller.active.retrying, true);
  assert.equal(heartbeatHarness.controller.active.context, null);
  await runLatestTimeout(heartbeatHarness);
  assert.equal(heartbeatPutCount, 2,
    'a transient heartbeat loss must rebuild the context with a full PUT');
  assert.equal(heartbeatHarness.controller.active.revision, 2);
  assert.equal(heartbeatHarness.controller.active.accepted, true);
  assert.equal(heartbeatHarness.controller.active.retrying, false);
  assert(heartbeatHarness.controller.active.context,
    'heartbeat recovery must restore the accepted context');
  assert.equal(heartbeatHarness.intervalCallbacks.size, 1,
    'heartbeat recovery must leave exactly one live interval');
}

let slowHeartbeatCount = 0;
let resolveSlowHeartbeat;
let markSlowHeartbeatStarted;
const slowHeartbeatStarted = new Promise(resolve => { markSlowHeartbeatStarted = resolve; });
const slowHeartbeatHarness = retryHarness(retryContext, async message => {
  if (message.op === 'heartbeat') {
    slowHeartbeatCount += 1;
    if (slowHeartbeatCount === 1) {
      markSlowHeartbeatStarted();
      return new Promise(resolve => { resolveSlowHeartbeat = resolve; });
    }
  }
  return { ok: true, status: 200 };
});
await slowHeartbeatHarness.controller.captureGeneric();
const slowHeartbeatCallback = Array.from(
  slowHeartbeatHarness.intervalCallbacks.values(),
).at(-1);
assert.equal(typeof slowHeartbeatCallback, 'function');
const firstSlowHeartbeat = slowHeartbeatCallback();
await slowHeartbeatStarted;
const overlappingSlowHeartbeat = slowHeartbeatCallback();
await overlappingSlowHeartbeat;
assert.equal(slowHeartbeatCount, 1,
  'a second interval tick must not enqueue behind an in-flight heartbeat');
resolveSlowHeartbeat({ ok: true, status: 200 });
await firstSlowHeartbeat;
await slowHeartbeatCallback();
assert.equal(slowHeartbeatCount, 2,
  'the heartbeat loop must unlock after the in-flight request completes');
assert.equal(slowHeartbeatHarness.controller.active.accepted, true);
assert.equal(slowHeartbeatHarness.intervalCallbacks.size, 1);

let spaPutCount = 0;
const spaHarness = retryHarness(retryContext, async message => {
  if (message.op !== 'put') return { ok: true };
  spaPutCount += 1;
  return { ok: false, status: 503, error: '暂不可用' };
});
await spaHarness.controller.captureGeneric();
spaHarness.locationLike.href = 'https://example.com/another-route';
await runLatestTimeout(spaHarness);
assert.equal(spaPutCount, 1,
  'a manual retry must not publish content from a different same-document URL');
assert.equal(spaHarness.controller.active, null);
assert.equal(spaHarness.timeoutCallbacks.size, 0);

let resolveInFlightBuild;
let markInFlightBuildStarted;
const inFlightBuildStarted = new Promise(resolve => { markInFlightBuildStarted = resolve; });
let inFlightBuildInput = null;
let inFlightPutCount = 0;
const inFlightSPAHarness = retryHarness(input => {
  inFlightBuildInput = input;
  markInFlightBuildStarted();
  return new Promise(resolve => { resolveInFlightBuild = resolve; });
}, async message => {
  if (message.op === 'put') inFlightPutCount += 1;
  return { ok: true, status: 200 };
});
const inFlightCapture = inFlightSPAHarness.controller.captureGeneric();
await inFlightBuildStarted;
inFlightSPAHarness.locationLike.href = 'https://example.com/changed-during-build';
resolveInFlightBuild(retryContext(inFlightBuildInput));
const inFlightSPAResult = await inFlightCapture;
assert.equal(inFlightSPAResult.stale, true);
assert.equal(inFlightPutCount, 0,
  'a URL change during asynchronous extraction must stop before the PUT');
assert.equal(inFlightSPAHarness.controller.active, null);

const cancelHarness = retryHarness(retryContext, async message => message.op === 'put'
  ? {
    ok: false,
    status: 409,
    error: '网页已不在前台',
    retryable: true,
    retryReason: 'page-not-foreground',
  }
  : { ok: true });
await cancelHarness.controller.captureGeneric();
assert.equal(cancelHarness.timeoutCallbacks.size, 1);
await cancelHarness.controller.clear('page-hidden');
assert.equal(cancelHarness.controller.active, null);
assert.equal(cancelHarness.timeoutCallbacks.size, 0,
  'page lifecycle cancellation must stop a suspended capture');

let hiddenBuildCount = 0;
let hiddenProbeCount = 0;
let hiddenPutCount = 0;
const hiddenHarness = retryHarness(input => {
  hiddenBuildCount += 1;
  return retryContext(input);
}, async message => {
  if (message.type === Protocol.MESSAGE_FOREGROUND) {
    hiddenProbeCount += 1;
    return { ok: true, status: 200, foreground: true };
  }
  if (message.op === 'put') {
    hiddenPutCount += 1;
    return {
      ok: false,
      status: 409,
      error: '网页已不在前台',
      retryable: true,
      retryReason: 'page-not-foreground',
    };
  }
  return { ok: true };
});
await hiddenHarness.controller.captureGeneric();
hiddenHarness.documentLike.hidden = true;
hiddenHarness.documentLike.focused = false;
await runLatestTimeout(hiddenHarness);
assert.equal(hiddenBuildCount, 1);
assert.equal(hiddenProbeCount, 0,
  'a hidden document must never ask the worker to recover foreground authority');
assert.equal(hiddenPutCount, 1,
  'a hidden document must not re-extract or republish page content');
assert.equal(hiddenHarness.timeoutCallbacks.size, 1,
  'a hidden manual intent may stay suspended until visibility returns');

const terminalHarness = retryHarness(retryContext, async message => message.op === 'put'
  ? { ok: false, status: 409, error: 'stale browser context' }
  : { ok: true });
const terminalResult = await terminalHarness.controller.captureGeneric();
assert.equal(terminalResult.retrying, undefined);
assert.equal(terminalHarness.controller.active, null);
assert.equal(terminalHarness.timeoutCallbacks.size, 0,
  'unstructured server conflicts must remain terminal');

let directPutCount = 0;
let directProbeCount = 0;
const directEditor = { isConnected: true };
const directHarness = retryHarness(retryContext, async message => {
  if (message.type === Protocol.MESSAGE_FOREGROUND) {
    directProbeCount += 1;
    return { ok: true, status: 200, foreground: true };
  }
  if (message.op !== 'put') return { ok: true };
  directPutCount += 1;
  return directPutCount === 1
    ? {
      ok: false,
      status: 409,
      error: '网页已不在前台',
      retryable: true,
      retryReason: 'page-not-foreground',
    }
    : { ok: true, status: 200 };
}, { bilibili: true });
directHarness.documentLike.activeElement = directEditor;
directHarness.controller.classify = currentEditor => ({
  mode: 'direct',
  editor: currentEditor,
  boundary: null,
  target: null,
  semanticKey: 'direct',
});
const directFirstResult = await directHarness.controller.activateEditor(directEditor, true);
assert.equal(directFirstResult.retrying, true);
directHarness.documentLike.focused = false;
await runLatestTimeout(directHarness);
assert.equal(directProbeCount, 1,
  'an unfocused Bilibili direct editor must ask the worker for selected-page authority');
assert.equal(directPutCount, 2,
  'a positive direct-editor probe must rebuild and PUT a fresh context');
assert.equal(directHarness.controller.active.accepted, true);
assert.equal(directHarness.controller.active.mode, 'direct');
assert.equal(directHarness.controller.active.target, null);

let popupBlurPutCount = 0;
const popupBlurEditor = { isConnected: true };
const popupBlurHarness = retryHarness(retryContext, async message => {
  if (message.op === 'put') popupBlurPutCount += 1;
  return { ok: true, status: 200 };
}, { bilibili: true });
popupBlurHarness.documentLike.activeElement = popupBlurEditor;
popupBlurHarness.controller.classify = currentEditor => ({
  mode: 'direct',
  editor: currentEditor,
  boundary: null,
  target: null,
  semanticKey: 'direct',
});
popupBlurHarness.controller.handleFocusOut();
const pendingPopupBlur = Array.from(popupBlurHarness.timeoutCallbacks.entries()).at(-1);
assert(pendingPopupBlur, 'popup focusout must schedule its delayed editor check');
const popupManualResult = await popupBlurHarness.controller.captureGeneric();
assert.equal(popupManualResult.ok, true);
if (popupBlurHarness.timeoutCallbacks.has(pendingPopupBlur[0])) {
  popupBlurHarness.timeoutCallbacks.delete(pendingPopupBlur[0]);
  pendingPopupBlur[1]();
  for (let attempt = 0; attempt < 5; attempt += 1) {
    await new Promise(resolve => setImmediate(resolve));
  }
}
assert.equal(popupBlurHarness.controller.active.manual, true,
  'a delayed popup focusout must not replace a newer manual capture with direct mode');
assert.equal(popupBlurHarness.controller.active.editor, null);
assert.equal(popupBlurPutCount, 1,
  'a stale popup focusout must not publish a second automatic direct context');

let replyTarget = {
  id: '101', authorName: '作者甲', text: '旧评论', parentId: null, rootId: null,
};
const replyIDs = [];
let replyProbeCount = 0;
const editor = { isConnected: true };
const replyHarness = retryHarness(retryContext, async message => {
  if (message.type === Protocol.MESSAGE_FOREGROUND) {
    replyProbeCount += 1;
    return { ok: true, status: 200, foreground: true };
  }
  if (message.op !== 'put') return { ok: true };
  replyIDs.push(message.payload.target.id);
  return replyIDs.length === 1
    ? { ok: false, status: 503, error: '暂不可用' }
    : { ok: true, status: 200 };
}, { bilibili: true });
replyHarness.documentLike.activeElement = editor;
replyHarness.controller.classify = currentEditor => ({
  mode: 'reply',
  editor: currentEditor,
  boundary: {},
  target: { ...replyTarget },
  semanticKey: 'reply:' + replyTarget.id,
});
await replyHarness.controller.activateEditor(editor, true);
replyTarget = {
  id: '202', authorName: '作者乙', text: '新评论', parentId: null, rootId: null,
};
replyHarness.documentLike.focused = false;
await runLatestTimeout(replyHarness);
assert.deepEqual(replyIDs, ['101'],
  'an unfocused Bilibili editor must not revive a stale exact reply target');
assert.equal(replyProbeCount, 0,
  'an exact Bilibili reply must not use the relaxed selected-page probe');
assert.equal(replyHarness.timeoutCallbacks.size, 1);
replyHarness.documentLike.focused = true;
await runLatestTimeout(replyHarness);
assert.deepEqual(replyIDs, ['101', '202'],
  'retry must re-classify the focused editor instead of replaying a stale reply target');

console.log('marine-chrome smoke: OK');
