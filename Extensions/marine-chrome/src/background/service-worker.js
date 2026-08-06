'use strict';

importScripts(
  chrome.runtime.getURL('src/shared/protocol.js'),
  chrome.runtime.getURL('src/background/lease-state.js'),
);

const Protocol = globalThis.MarineChromeProtocol;
const LeaseState = globalThis.MarineChromeLeaseState;
const CONTENT_FILES = [
  'src/shared/protocol.js',
  'src/shared/text.js',
  'src/content/extract.js',
  'src/content/bilibili.js',
  'src/content/context-builder.js',
  'src/content/target-controller.js',
  'src/content/entry.js',
];

let currentLease = null;
let authorityEpoch = 0;
let lastAuthorityTimestamp = 0;
let operationQueue = Promise.resolve();
const inFlightPutTabs = new Map();
const tabActivationSequences = new Map();
let pairingPromise = null;
let secureStorageAvailable = false;
let connectionState = 'unknown';
let connectionDetail = '';
let pairingDisplayCode = '';
const ready = initialize();

async function initialize() {
  // The bearer token lives in storage.local but content scripts never need it.
  // If either access boundary cannot be installed, do not pair, read a token,
  // or send browser context. Silently falling back would expose credentials to
  // content-script contexts.
  try {
    await chrome.storage.local.setAccessLevel({ accessLevel: 'TRUSTED_CONTEXTS' });
    await chrome.storage.session.setAccessLevel({ accessLevel: 'TRUSTED_CONTEXTS' });
    secureStorageAvailable = true;
  } catch (error) {
    setConnection('storageUnsafe', 'Chrome 无法隔离扩展凭据，marine-chrome 已停止连接');
    return;
  }
  if (!Protocol.extensionIdentityMatches(chrome.runtime.id)) {
    connectionState = 'incompatible';
    connectionDetail = Protocol.extensionIdentityMismatchDetail(chrome.runtime.id);
  }
  await restoreSession();
}

async function restoreSession() {
  try {
    const stored = await chrome.storage.session.get(Protocol.SESSION_KEY);
    const value = stored && stored[Protocol.SESSION_KEY];
    if (LeaseState.validStored(value) && Protocol.validTimestamp(value.capturedAt) &&
        leaseIsFresh(value)) {
      currentLease = value;
      lastAuthorityTimestamp = Math.max(lastAuthorityTimestamp, value.capturedAt);
    } else if (value) await chrome.storage.session.remove(Protocol.SESSION_KEY);
  } catch (error) {}
}

function leaseIsFresh(lease) {
  return !!lease && Number.isFinite(lease.capturedAt) &&
    lease.capturedAt >= Protocol.nowSeconds() - Protocol.LEASE_RESTORE_SECONDS;
}

async function persistSession() {
  try {
    if (currentLease) {
      await chrome.storage.session.set({ [Protocol.SESSION_KEY]: currentLease });
    } else await chrome.storage.session.remove(Protocol.SESSION_KEY);
  } catch (error) {}
}

function queue(operation) {
  const result = operationQueue.catch(() => {}).then(operation);
  operationQueue = result.catch(() => {});
  return result;
}

function nextAuthorityTimestamp() {
  lastAuthorityTimestamp = Protocol.nextTimestamp(lastAuthorityTimestamp);
  return lastAuthorityTimestamp;
}

function authorityPayload(payload) {
  return Object.assign({}, payload, { capturedAt: nextAuthorityTimestamp() });
}

async function configuration() {
  if (!secureStorageAvailable) return { apiBase: '', token: '' };
  try {
    const stored = await chrome.storage.local.get(Protocol.CONFIG_KEY);
    const value = stored && stored[Protocol.CONFIG_KEY] || {};
    const apiBase = Protocol.normalizeAPIBase(value.apiBase || Protocol.DEFAULT_API_BASE);
    const token = Protocol.normalizeToken(value.token);
    return { apiBase, token };
  } catch (error) {
    return { apiBase: '', token: '' };
  }
}

function secureStorageError() {
  return {
    ok: false,
    status: 0,
    error: 'Chrome 安全存储不可用，marine-chrome 已停止连接',
  };
}

function setConnection(state, detail = '', displayCode = '') {
  connectionState = state;
  connectionDetail = detail;
  pairingDisplayCode = displayCode;
}

function delay(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}

function randomClaimSecret() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function randomDisplayCode() {
  const alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  const bytes = new Uint8Array(6);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, byte => alphabet[byte & 31]).join('');
}

function validPairingSession(value) {
  return !!value && Protocol.validIdentifier(value.requestId) &&
    Protocol.normalizeToken(value.claimSecret) === value.claimSecret &&
    /^[2-9A-HJ-NP-Z]{6}$/.test(value.displayCode) &&
    Protocol.normalizeAPIBase(value.apiBase) === value.apiBase &&
    Number.isFinite(value.expiresAt) && value.expiresAt > Protocol.nowSeconds() &&
    typeof value.force === 'boolean' && typeof value.challengeSeen === 'boolean' &&
    typeof value.confirmed === 'boolean' && (!value.confirmed || value.challengeSeen);
}

async function storedPairingSession() {
  if (!secureStorageAvailable) return null;
  const stored = await chrome.storage.session.get(Protocol.PAIRING_SESSION_KEY);
  const value = stored && stored[Protocol.PAIRING_SESSION_KEY];
  if (validPairingSession(value)) return value;
  if (value) await chrome.storage.session.remove(Protocol.PAIRING_SESSION_KEY);
  return null;
}

async function pairingSession(force, apiBase) {
  const existing = await storedPairingSession();
  if (existing && existing.force === !!force &&
      existing.apiBase === apiBase) return existing;
  if (existing) await chrome.storage.session.remove(Protocol.PAIRING_SESSION_KEY);
  const value = {
    requestId: crypto.randomUUID(),
    claimSecret: randomClaimSecret(),
    displayCode: randomDisplayCode(),
    apiBase,
    expiresAt: Protocol.nowSeconds() + 75,
    force: !!force,
    challengeSeen: false,
    confirmed: false,
  };
  await chrome.storage.session.set({ [Protocol.PAIRING_SESSION_KEY]: value });
  return value;
}

function constantTimeTextEqual(left, right) {
  if (typeof left !== 'string' || typeof right !== 'string' ||
      left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

function base64URL(bytes) {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function expectedServerProof(token, nonce) {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(token),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign(
    'HMAC',
    key,
    encoder.encode(Protocol.serverProofInput(nonce)),
  );
  return base64URL(new Uint8Array(signature));
}

async function performRequest(config, path, method, body, bearerToken = '') {
  if (!config.apiBase) {
    return { ok: false, status: 0, error: 'marine-chrome 尚未连接 RIMES' };
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Protocol.REQUEST_TIMEOUT_MS);
  try {
    const headers = {};
    if (bearerToken) headers.Authorization = 'Bearer ' + bearerToken;
    const options = {
      method,
      headers,
      cache: 'no-store',
      credentials: 'omit',
      signal: controller.signal,
    };
    if (body !== undefined) {
      headers['Content-Type'] = 'application/json';
      options.body = JSON.stringify(body);
    }
    const response = await fetch(config.apiBase + path, options);
    let value = null;
    try { value = await response.json(); } catch (error) {}
    return {
      ok: response.ok,
      status: response.status,
      value,
      error: response.ok ? '' : String(value && value.error || 'HTTP ' + response.status),
      retryable: response.status === 503,
    };
  } catch (error) {
    return {
      ok: false,
      status: 0,
      error: error && error.name === 'AbortError' ? '连接 RIMES 超时' :
        String(error && error.message || error),
      retryable: true,
    };
  } finally { clearTimeout(timer); }
}

async function proveServer(config) {
  const nonce = randomClaimSecret();
  const response = await performRequest(
    config,
    '/v1/marine-chrome/prove',
    'PUT',
    { protocolVersion: Protocol.VERSION, nonce },
  );
  if (!response.ok) {
    return Object.assign({}, response, {
      error: response.status === 404
        ? '当前 RIMES 不支持安全身份验证，请更新 RIMES'
        : response.error,
      proofFailure: true,
    });
  }
  const received = Protocol.normalizeToken(response.value && response.value.proof);
  let expected = '';
  try { expected = await expectedServerProof(config.token, nonce); }
  catch (error) {
    return { ok: false, status: 0, error: '无法验证本机 RIMES 身份', proofFailure: true };
  }
  if (!response.value || response.value.protocolVersion !== Protocol.VERSION ||
      !received || !constantTimeTextEqual(received, expected)) {
    // Treat a valid endpoint proving a different token like retired credentials.
    // No bearer has been disclosed, and the normal interactive re-pair path can
    // now recover safely.
    return { ok: false, status: 401, error: '本机 RIMES 身份验证失败', proofFailure: true };
  }
  return { ok: true, status: response.status };
}

async function requestWithConfiguration(config, path, method, body,
                                        authenticated = true) {
  if (!config.apiBase || (authenticated && !config.token)) {
    return { ok: false, status: 0, error: 'marine-chrome 尚未连接 RIMES' };
  }
  if (authenticated) {
    if (!secureStorageAvailable) return secureStorageError();
    const proof = await proveServer(config);
    if (!proof.ok) return proof;
  }
  return performRequest(config, path, method, body, authenticated ? config.token : '');
}

async function requestAPI(path, method, body, authenticated = true) {
  const config = await configuration();
  const response = await requestWithConfiguration(
    config, path, method, body, authenticated,
  );
  if (authenticated && (response.status === 401 || response.status === 403)) {
    setConnection('disconnected', 'RIMES 配对已失效，请打开扩展设置重新连接');
  }
  return response;
}

async function healthCheck(config) {
  const health = await requestWithConfiguration(
    config, '/v1/marine-chrome/health', 'GET', undefined, false,
  );
  if (!health.ok) return health;
  if (!health.value || health.value.protocolVersion !== Protocol.VERSION) {
    return { ok: false, status: 0, error: 'RIMES 协议版本不兼容' };
  }
  if (health.value.extensionId &&
      health.value.extensionId !== chrome.runtime.id) {
    return {
      ok: false,
      status: 0,
      error: Protocol.extensionIdentityMismatchDetail(chrome.runtime.id),
    };
  }
  return health;
}

async function verifyConfiguration(config) {
  if (!config.apiBase || !config.token) {
    return { ok: false, status: 0, error: 'marine-chrome 尚未连接 RIMES' };
  }
  const pair = await requestWithConfiguration(config, '/v1/marine-chrome/pair', 'PUT', {
    protocolVersion: Protocol.VERSION,
  });
  if (!pair.ok) return pair;
  if (!pair.value || pair.value.paired !== true ||
      pair.value.protocolVersion !== Protocol.VERSION) {
    return { ok: false, status: pair.status, error: 'RIMES 没有确认扩展配对' };
  }
  return {
    ok: true,
    status: pair.status,
    protocolVersion: pair.value.protocolVersion,
  };
}

function pairingRequest(session) {
  return requestWithConfiguration(
    { apiBase: session.apiBase, token: '' },
    '/v1/marine-chrome/pair/request',
    'PUT',
    {
      protocolVersion: Protocol.VERSION,
      extensionId: chrome.runtime.id,
      requestId: session.requestId,
      claimSecret: session.claimSecret,
      displayCode: session.displayCode,
      force: session.force,
    },
    false,
  );
}

async function persistPairingSession(session, responseValue) {
  const value = responseValue || {};
  if (Number.isFinite(value.expiresAt) && value.expiresAt > Protocol.nowSeconds()) {
    session.expiresAt = value.expiresAt + 2;
  }
  await chrome.storage.session.set({ [Protocol.PAIRING_SESSION_KEY]: session });
}

function samePairingSession(left, right) {
  return !!left && !!right && left.requestId === right.requestId &&
    left.apiBase === right.apiBase && left.force === right.force &&
    constantTimeTextEqual(left.claimSecret, right.claimSecret);
}

async function pairingTerminalFailure(response, value) {
  if (response.status === 403 && value.state === 'denied') {
    await chrome.storage.session.remove(Protocol.PAIRING_SESSION_KEY);
    setConnection('denied', '你在 RIMES 中拒绝了连接');
    return { ok: false, status: 403, error: connectionDetail };
  }
  if (response.status === 410 && value.state === 'expired') {
    await chrome.storage.session.remove(Protocol.PAIRING_SESSION_KEY);
    setConnection('expired', '配对请求已过期，请重试');
    return { ok: false, status: 410, error: connectionDetail };
  }
  setConnection('failed', response.error || '无法完成 RIMES 配对');
  return response;
}

async function acceptPairingCredential(session, response) {
  const value = response.value || {};
  const token = Protocol.normalizeToken(value.token);
  if (value.paired !== true || value.state !== 'paired' || !token ||
      value.protocolVersion !== Protocol.VERSION) {
    setConnection('failed', 'RIMES 返回了无效的配对凭据');
    return { ok: false, status: response.status, error: connectionDetail };
  }
  const latest = await storedPairingSession();
  if (!Protocol.pairingCredentialAuthorized(latest) ||
      !samePairingSession(latest, session)) {
    // A 200 response is not authority to save a credential. Only a prior,
    // persisted click from the visible options page unlocks this branch.
    setConnection('awaitingConfirmation', '请返回扩展设置并点击“确认连接”', session.displayCode);
    return { ok: true, status: 202, pendingConfirmation: true };
  }
  const issuedConfig = { apiBase: session.apiBase, token };
  const proof = await proveServer(issuedConfig);
  if (!proof.ok) {
    setConnection('failed', proof.error || 'RIMES 无法证明新凭据');
    return proof;
  }
  await chrome.storage.local.set({ [Protocol.CONFIG_KEY]: issuedConfig });
  await chrome.storage.session.remove(Protocol.PAIRING_SESSION_KEY);
  setConnection('connected', '已安全配对');
  return { ok: true, status: response.status, protocolVersion: Protocol.VERSION };
}

async function completeInteractivePair(session) {
  if (!session.challengeSeen || !session.confirmed) {
    setConnection('awaitingConfirmation', '请在本页点击“确认连接”', session.displayCode);
    return { ok: true, status: 202, pendingConfirmation: true };
  }
  setConnection('confirming', '正在等待 RIMES 完成授权', session.displayCode);
  while (Protocol.nowSeconds() < session.expiresAt) {
    const response = await pairingRequest(session);
    const value = response.value || {};
    if (response.ok && response.status === 200) {
      return acceptPairingCredential(session, response);
    }
    if (response.status === 202 && value.state === 'pending') {
      await persistPairingSession(session, value);
      setConnection('confirming', '请先在 RIMES 弹窗中点击允许', session.displayCode);
      await delay(Protocol.PAIRING_POLL_INTERVAL_MS);
      continue;
    }
    if (response.status === 429 && value.state === 'busy') {
      setConnection('busy', 'RIMES 正在处理另一条配对请求', session.displayCode);
      await delay(Protocol.PAIRING_POLL_INTERVAL_MS);
      continue;
    }
    return pairingTerminalFailure(response, value);
  }
  await chrome.storage.session.remove(Protocol.PAIRING_SESSION_KEY);
  setConnection('expired', '配对请求已过期，请重试');
  return { ok: false, status: 0, error: connectionDetail };
}

async function interactivePair(config, force) {
  const session = await pairingSession(force, config.apiBase);
  if (session.confirmed) return completeInteractivePair(session);
  if (session.challengeSeen) {
    setConnection('awaitingConfirmation', '核对确认码后，在本页点击“确认连接”',
      session.displayCode);
    return { ok: true, status: 202, pendingConfirmation: true };
  }
  setConnection('awaitingApproval', '请在 RIMES 弹窗中点击允许', session.displayCode);
  // Give the visible options document enough time to paint the code before the
  // native RIMES alert activates. Credential acceptance still requires a later
  // explicit click in that document.
  await delay(750);

  while (Protocol.nowSeconds() < session.expiresAt) {
    const response = await pairingRequest(session);
    const value = response.value || {};
    if ((response.status === 202 && value.state === 'pending') ||
        (response.ok && response.status === 200)) {
      // Even if an already-approved broker returns 200 after a worker restart,
      // discard its credential until the options page records a real click.
      session.challengeSeen = true;
      await persistPairingSession(session, value);
      setConnection('awaitingConfirmation', '核对确认码后，在本页点击“确认连接”',
        session.displayCode);
      return { ok: true, status: 202, pendingConfirmation: true };
    }
    if (response.status === 429 && value.state === 'busy') {
      setConnection('busy', 'RIMES 正在处理另一条配对请求', session.displayCode);
      await delay(Protocol.PAIRING_POLL_INTERVAL_MS);
      continue;
    }
    return pairingTerminalFailure(response, value);
  }
  await chrome.storage.session.remove(Protocol.PAIRING_SESSION_KEY);
  setConnection('expired', '配对请求已过期，请重试');
  return { ok: false, status: 0, error: connectionDetail };
}

async function runPairing(force, apiBaseOverride = '') {
  await ready;
  if (!secureStorageAvailable) return secureStorageError();
  if (!Protocol.extensionIdentityMatches(chrome.runtime.id)) {
    setConnection('incompatible',
      Protocol.extensionIdentityMismatchDetail(chrome.runtime.id));
    return { ok: false, status: 0, error: connectionDetail };
  }
  const storedConfig = await configuration();
  const rawOverride = typeof apiBaseOverride === 'string' ? apiBaseOverride.trim() : '';
  const override = rawOverride ? Protocol.normalizeAPIBase(rawOverride) : '';
  if (rawOverride && !override) {
    setConnection('failed', 'RIMES 地址无效');
    return { ok: false, status: 0, error: connectionDetail };
  }
  const apiBase = override || storedConfig.apiBase;
  const config = {
    apiBase,
    token: apiBase === storedConfig.apiBase ? storedConfig.token : '',
  };
  if (!config.apiBase) {
    setConnection('failed', 'RIMES 地址无效');
    return { ok: false, status: 0, error: connectionDetail };
  }
  setConnection('checking', '正在查找本机 RIMES');
  const health = await healthCheck(config);
  if (!health.ok) {
    setConnection('unavailable', health.error || '找不到本机 RIMES');
    return health;
  }
  if (config.token && !force) {
    const verified = await verifyConfiguration(config);
    if (verified.ok) {
      await chrome.storage.session.remove(Protocol.PAIRING_SESSION_KEY);
      setConnection('connected', 'RIMES 连接正常');
      return verified;
    }
    if (verified.status !== 401 && verified.status !== 403) {
      setConnection('unavailable', verified.error || 'RIMES 连接失败');
      return verified;
    }
  }
  if (!health.value || health.value.pairingMode !== 'interactive-claim-v1') {
    setConnection('manualRequired', '当前 RIMES 版本不支持安全自动连接，请更新 RIMES');
    return { ok: false, status: 0, error: connectionDetail };
  }
  const paired = await interactivePair(config, force);
  if (!paired.ok && force && config.token) {
    const prior = await verifyConfiguration(config);
    if (prior.ok) {
      setConnection('connected', '重新连接已取消，原连接仍然有效');
      return { ok: true, status: prior.status, preserved: true };
    }
  }
  return paired;
}

async function exclusivePairing(key, operationFactory) {
  if (pairingPromise) {
    if (pairingPromise.key === key) return pairingPromise.operation;
    return { ok: false, status: 429, error: '另一个配对操作正在进行' };
  }
  const operation = operationFactory();
  pairingPromise = { key, operation };
  try { return await operation; }
  finally {
    if (pairingPromise && pairingPromise.operation === operation) pairingPromise = null;
  }
}

async function ensurePairing(force = false, apiBaseOverride = '') {
  const key = 'start:' + (!!force) + ':' + String(apiBaseOverride || '');
  return exclusivePairing(key, () => runPairing(!!force, apiBaseOverride));
}

async function confirmPairing() {
  await ready;
  if (!secureStorageAvailable) return secureStorageError();
  const session = await storedPairingSession();
  if (!session || !session.challengeSeen) {
    return { ok: false, status: 409, error: '没有等待确认的配对请求' };
  }
  const key = 'confirm:' + session.requestId;
  return exclusivePairing(key, async () => {
    const latest = await storedPairingSession();
    if (!latest || !samePairingSession(latest, session) || !latest.challengeSeen) {
      return { ok: false, status: 409, error: '配对请求已经变化，请重新连接' };
    }
    latest.confirmed = true;
    await chrome.storage.session.set({ [Protocol.PAIRING_SESSION_KEY]: latest });
    const result = await completeInteractivePair(latest);
    if (!result.ok && latest.force) {
      const prior = await configuration();
      if (prior.apiBase === latest.apiBase && prior.token) {
        const verified = await verifyConfiguration(prior);
        if (verified.ok) {
          setConnection('connected', '重新连接已取消，原连接仍然有效');
          return { ok: true, status: verified.status, preserved: true };
        }
      }
    }
    return result;
  });
}

async function testConnection() {
  await ready;
  if (!secureStorageAvailable) return secureStorageError();
  const config = await configuration();
  setConnection('checking', '正在检查 RIMES 连接');
  const health = await healthCheck(config);
  if (!health.ok) {
    setConnection('unavailable', health.error || '找不到本机 RIMES');
    return health;
  }
  const verified = await verifyConfiguration(config);
  if (verified.ok) {
    await chrome.storage.session.remove(Protocol.PAIRING_SESSION_KEY);
    setConnection('connected', 'RIMES 连接正常');
  }
  else setConnection('disconnected', verified.error || 'RIMES 尚未配对');
  return verified;
}

function normalizedURL(raw) {
  try { return new URL(String(raw || '')).href; } catch (error) { return ''; }
}

async function foregroundSender(sender, expectedEpoch, expectedURL) {
  const tabId = sender && sender.tab && sender.tab.id;
  const windowId = sender && sender.tab && sender.tab.windowId;
  if (!Number.isInteger(tabId) || !Number.isInteger(windowId) || sender.frameId !== 0) return false;
  if (expectedEpoch !== authorityEpoch) return false;
  try {
    // An action popup is hosted in its own focused Chrome window. While it is
    // open, chrome.windows.get(parent).focused is false even though the same
    // browser tab remains the user's selected page. Marine's proven capture
    // path binds to that selected host tab instead of treating DOM/native
    // popup focus as page authority. Require both the tab's own window and
    // Chrome's last-focused browser window to select the exact same tab.
    const [tab, activeTabs, selectedTabs] = await Promise.all([
      chrome.tabs.get(tabId),
      chrome.tabs.query({ active: true, windowId }),
      chrome.tabs.query({ active: true, lastFocusedWindow: true }),
    ]);
    const expected = normalizedURL(expectedURL);
    const current = normalizedURL(tab && tab.url);
    const pending = normalizedURL(tab && tab.pendingUrl);
    return expectedEpoch === authorityEpoch && !!tab && tab.active === true &&
      tab.windowId === windowId && !!expected && current === expected &&
      (!pending || pending === expected) &&
      !!activeTabs[0] && activeTabs[0].id === tabId &&
      !!selectedTabs[0] && selectedTabs[0].id === tabId &&
      selectedTabs[0].windowId === windowId;
  } catch (error) { return false; }
}

function senderMatchesURL(sender, rawURL) {
  if (!sender || !sender.tab) return false;
  const expected = normalizedURL(rawURL);
  const candidates = [sender.url, sender.tab.url].map(normalizedURL).filter(Boolean);
  return !!expected && candidates.includes(expected);
}

function senderMatchesPage(sender, context) {
  return !!context && !!context.page && senderMatchesURL(sender, context.page.url);
}

function retryableAuthorityFailure(error, retryReason) {
  return {
    ok: false,
    status: 409,
    error,
    retryable: true,
    retryReason,
  };
}

async function compensateContext(context) {
  return requestAPI('/v1/marine-chrome/context', 'DELETE',
    Protocol.makeRevocation(context, nextAuthorityTimestamp()));
}

async function handlePut(payload, sender) {
  if (!Protocol.validateContext(payload) || !senderMatchesPage(sender, payload)) {
    return { ok: false, status: 400, error: '无效的网页上下文' };
  }
  const context = authorityPayload(payload);
  const epoch = authorityEpoch;
  if (!await foregroundSender(sender, epoch, context.page.url)) {
    return retryableAuthorityFailure('网页已不在前台', 'page-not-foreground');
  }
  inFlightPutTabs.set(sender.tab.id, sender.tab.windowId);
  let response;
  try {
    response = await requestAPI('/v1/marine-chrome/context', 'PUT', context);
  } finally {
    inFlightPutTabs.delete(sender.tab.id);
  }
  if (!response.ok) {
    if (response.status === 409 && currentLease &&
        LeaseState.exactPayload(currentLease, context)) {
      currentLease = null;
      await persistSession();
    }
    return response;
  }
  if (epoch !== authorityEpoch ||
      !await foregroundSender(sender, epoch, context.page.url)) {
    await compensateContext(context);
    return retryableAuthorityFailure(
      '网页上下文在传输途中失焦',
      'page-lost-foreground',
    );
  }
  currentLease = LeaseState.fromContext(context, sender);
  await persistSession();
  return { ok: true, status: response.status, contextId: context.contextId };
}

async function handleForegroundProbe(payload, sender) {
  await ready;
  if (!Protocol.validateForegroundProbe(payload) || !sender || !sender.tab ||
      sender.frameId !== 0 || typeof sender.documentId !== 'string' ||
      !sender.documentId || !senderMatchesURL(sender, payload.url)) {
    return { ok: false, status: 400, error: '无效的前台探测请求' };
  }
  const epoch = authorityEpoch;
  return {
    ok: true,
    status: 200,
    foreground: await foregroundSender(sender, epoch, payload.url),
  };
}

async function handleHeartbeat(payload, sender) {
  if (!currentLease || !LeaseState.exactPayload(currentLease, payload) ||
      !LeaseState.exactSender(currentLease, sender) ||
      currentLease.url !== payload.url || currentLease.targetId !== payload.targetId) {
    return retryableAuthorityFailure('网页租约已失效', 'lease-reacquire');
  }
  const epoch = authorityEpoch;
  if (!await foregroundSender(sender, epoch, payload.url)) {
    await revokeCurrent('heartbeat-background');
    return retryableAuthorityFailure('网页已不在前台', 'page-not-foreground');
  }
  const heartbeat = authorityPayload(payload);
  const response = await requestAPI('/v1/marine-chrome/heartbeat', 'PUT', heartbeat);
  if (response.ok && currentLease && LeaseState.exactPayload(currentLease, heartbeat)) {
    currentLease = Object.assign({}, currentLease, { capturedAt: heartbeat.capturedAt });
    await persistSession();
  } else if (!response.ok) {
    currentLease = null;
    await persistSession();
  }
  if (response.ok) return { ok: true, status: response.status };
  return response.status === 409
    ? Object.assign({}, response, { retryable: true, retryReason: 'lease-reacquire' })
    : response;
}

async function handleDelete(payload, sender) {
  if (!payload || payload.protocolVersion !== Protocol.VERSION ||
      !Protocol.validIdentifier(payload.sourceId) ||
      !Number.isSafeInteger(payload.revision) || payload.revision <= 0 ||
      !Protocol.validTimestamp(payload.capturedAt) ||
      (payload.contextId !== null && !Protocol.validIdentifier(payload.contextId))) {
    return { ok: false, status: 400, error: '无效的网页租约撤销请求' };
  }
  // If the worker has no exact authority, let the RIMES-side six-second lease
  // expire. Forwarding an unbound tombstone could advance the global ordering
  // watermark on behalf of an unrelated background document.
  if (!currentLease) return { ok: true, skipped: true };
  if (!LeaseState.exactSender(currentLease, sender) ||
      !LeaseState.exactPayload(currentLease, payload)) {
    return { ok: false, status: 409, error: '不能撤销其他网页租约' };
  }
  const revocation = authorityPayload(payload);
  const response = await requestAPI('/v1/marine-chrome/context', 'DELETE', revocation);
  if (LeaseState.exactPayload(currentLease, payload)) {
    currentLease = null;
    await persistSession();
  }
  return response.ok || response.status === 409
    ? { ok: true, status: response.status }
    : response;
}

async function handleContentOperation(message, sender) {
  await ready;
  if (!secureStorageAvailable) return secureStorageError();
  if (!message || !message.payload || !sender || !sender.tab || sender.frameId !== 0 ||
      typeof sender.documentId !== 'string' || !sender.documentId) {
    return { ok: false, status: 400, error: '无效的扩展消息来源' };
  }
  if (message.op === 'put') return handlePut(message.payload, sender);
  if (message.op === 'heartbeat') return handleHeartbeat(message.payload, sender);
  if (message.op === 'delete') return handleDelete(message.payload, sender);
  return { ok: false, status: 400, error: '未知的网页租约操作' };
}

async function revokeCurrent() {
  await ready;
  if (!secureStorageAvailable) return secureStorageError();
  const lease = currentLease;
  if (!lease) return { ok: true, skipped: true };
  currentLease = null;
  await persistSession();
  const response = await requestAPI('/v1/marine-chrome/context', 'DELETE',
    Protocol.makeRevocation(lease, nextAuthorityTimestamp()));
  return response.ok || response.status === 409 ? { ok: true } : response;
}

async function queryActiveHTTPPageTab() {
  const tabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  const tab = tabs && tabs[0];
  if (!tab || !Number.isInteger(tab.id) || !/^https?:/i.test(String(tab.url || ''))) {
    return null;
  }
  return tab;
}

async function sendToActivePage(message) {
  const tab = await queryActiveHTTPPageTab();
  if (!tab) return { ok: false, error: '当前标签页不允许读取' };
  try {
    return await chrome.tabs.sendMessage(tab.id, message);
  } catch (firstError) {
    try {
      await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        files: CONTENT_FILES,
        world: 'ISOLATED',
      });
      return await chrome.tabs.sendMessage(tab.id, message);
    } catch (error) {
      return { ok: false, error: String(error && error.message || error) };
    }
  }
}

async function queryActivePage(tab, message) {
  if (!tab || !Number.isInteger(tab.id)) return null;
  try { return await chrome.tabs.sendMessage(tab.id, message); }
  catch (error) { return null; }
}

async function captureActivePage() {
  return sendToActivePage({ type: Protocol.MESSAGE_CAPTURE_PAGE });
}

async function status() {
  await ready;
  if (!secureStorageAvailable) {
    return {
      ok: true,
      configured: false,
      connectionState: 'storageUnsafe',
      connectionDetail,
      pairingDisplayCode: '',
      pairingAPIBase: '',
      pairingForce: false,
      pairingNeedsConfirmation: false,
      pairingInFlight: false,
      leaseActive: false,
      pageActive: false,
      pageRetrying: false,
      pageRetryDetail: '',
      pageRetryReason: '',
      mode: null,
      targetSummary: null,
    };
  }
  const activeTab = await queryActiveHTTPPageTab();
  const config = await configuration();
  const pendingPairing = secureStorageAvailable ? await storedPairingSession() : null;
  let page = null;
  try { page = await queryActivePage(activeTab, { type: Protocol.MESSAGE_STATUS }); }
  catch (error) {}
  // Status polling must serialize with PUT/heartbeat. Otherwise a slow but
  // successful heartbeat can race a stale-lease prune and leave the worker
  // forgetting a lease that RIMES has just renewed.
  const leaseActive = await queue(async () => {
    if (currentLease && !leaseIsFresh(currentLease)) {
      currentLease = null;
      await persistSession();
    }
    if (!currentLease || !activeTab || !page || page.active !== true) return false;
    return currentLease.tabId === activeTab.id &&
      currentLease.windowId === activeTab.windowId &&
      normalizedURL(currentLease.url) === normalizedURL(activeTab.url) &&
      LeaseState.exactPayload(currentLease, page);
  });
  let effectiveState = connectionState;
  if (effectiveState === 'unknown' && pendingPairing) {
    if (pendingPairing.confirmed) effectiveState = 'confirming';
    else if (pendingPairing.challengeSeen) effectiveState = 'awaitingConfirmation';
    else effectiveState = 'checking';
  }
  if (!pendingPairing && ['awaitingApproval', 'awaitingConfirmation', 'confirming', 'busy']
    .includes(effectiveState)) {
    effectiveState = 'expired';
  }
  return {
    ok: true,
    configured: !!config.apiBase && !!config.token,
    connectionState: effectiveState === 'unknown'
      ? (config.token ? 'stored' : 'disconnected')
      : effectiveState,
    connectionDetail,
    pairingDisplayCode: pendingPairing &&
      (pairingDisplayCode || pendingPairing.displayCode) || '',
    pairingAPIBase: pendingPairing && pendingPairing.apiBase || '',
    pairingForce: !!(pendingPairing && pendingPairing.force),
    pairingNeedsConfirmation: !!(pendingPairing && pendingPairing.challengeSeen &&
      !pendingPairing.confirmed),
    pairingInFlight: !!pairingPromise,
    leaseActive,
    pageActive: !!(page && page.active),
    pageRetrying: !!(page && page.retrying),
    pageRetryDetail: page && page.retryDetail || '',
    pageRetryReason: page && page.retryReason || '',
    mode: page && page.mode || null,
    targetSummary: page && page.targetSummary || null,
  };
}

function trustedExtensionPage(sender) {
  return !!sender && sender.id === chrome.runtime.id &&
    Protocol.trustedExtensionPageURL(sender.url, chrome.runtime.id);
}

function trustedOptionsPage(sender) {
  return !!sender && sender.id === chrome.runtime.id &&
    Protocol.trustedOptionsPageURL(sender.url, chrome.runtime.id);
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || typeof message !== 'object') return false;
  let operation = null;
  if (message.type === Protocol.MESSAGE_CONTEXT) {
    operation = queue(() => handleContentOperation(message, sender));
  } else if (message.type === Protocol.MESSAGE_FOREGROUND) {
    // A probe is read-only and intentionally bypasses the network operation
    // queue. Suspended pages must be able to notice focus recovery even while
    // another lease operation is waiting on loopback I/O.
    operation = handleForegroundProbe(message.payload, sender);
  } else if (message.type === Protocol.MESSAGE_CAPTURE) {
    operation = trustedExtensionPage(sender)
      ? captureActivePage()
      : Promise.resolve({ ok: false, status: 403, error: '不允许的网页读取来源' });
  } else if (message.type === Protocol.MESSAGE_STATUS) {
    operation = trustedExtensionPage(sender)
      ? status()
      : Promise.resolve({ ok: false, status: 403, error: '不允许的状态查询来源' });
  } else if (message.type === Protocol.MESSAGE_TEST) {
    operation = trustedExtensionPage(sender)
      ? testConnection()
      : Promise.resolve({ ok: false, status: 403, error: '不允许的连接检查来源' });
  } else if (message.type === Protocol.MESSAGE_PAIR) {
    operation = trustedExtensionPage(sender)
      ? ensurePairing(message.force === true, message.apiBase)
      : Promise.resolve({ ok: false, status: 403, error: '不允许的配对来源' });
  } else if (message.type === Protocol.MESSAGE_CONFIRM_PAIR) {
    operation = trustedOptionsPage(sender)
      ? confirmPairing()
      : Promise.resolve({ ok: false, status: 403, error: '只能在连接设置页确认配对' });
  }
  if (!operation) return false;
  Promise.resolve(operation).then(sendResponse).catch(error => {
    sendResponse({ ok: false, status: 0, error: String(error && error.message || error) });
  });
  return true;
});

chrome.runtime.onInstalled.addListener(details => {
  if (details.reason === 'install') void chrome.runtime.openOptionsPage();
});

chrome.tabs.onActivated.addListener(({ tabId, windowId }) => {
  const sequence = (tabActivationSequences.get(windowId) || 0) + 1;
  tabActivationSequences.set(windowId, sequence);
  void ready.then(async () => {
    // The activation event itself is an authority break. Check it before the
    // asynchronous "what is active now?" query: in a rapid A -> B -> A
    // sequence, the older B query is intentionally stale, but B still ended
    // A's lease when the event happened.
    const displacedAtEvent = currentLease && currentLease.windowId === windowId &&
      currentLease.tabId !== tabId ? currentLease : null;
    const interruptedPut = Array.from(inFlightPutTabs.entries()).some(
      ([putTabId, putWindowId]) => putWindowId === windowId && putTabId !== tabId,
    );
    if (displacedAtEvent || interruptedPut) {
      authorityEpoch += 1;
      if (!displacedAtEvent) return null;
      return queue(() => {
        if (!currentLease || currentLease.sourceId !== displacedAtEvent.sourceId ||
            currentLease.revision !== displacedAtEvent.revision ||
            currentLease.contextId !== displacedAtEvent.contextId ||
            currentLease.tabId !== displacedAtEvent.tabId ||
            currentLease.windowId !== displacedAtEvent.windowId ||
            currentLease.documentId !== displacedAtEvent.documentId) return null;
        return revokeCurrent('tab-activated');
      });
    }
    let focused = false;
    let activeTabId = null;
    try {
      const [windowValue, activeTabs] = await Promise.all([
        chrome.windows.get(windowId),
        chrome.tabs.query({ active: true, windowId }),
      ]);
      focused = windowValue.focused === true;
      activeTabId = activeTabs && activeTabs[0] && activeTabs[0].id;
    }
    catch (error) {}
    if (tabActivationSequences.get(windowId) !== sequence || activeTabId !== tabId) {
      return null;
    }
    const affectsLease = !!currentLease &&
      (focused || currentLease.windowId === windowId);
    // A tab activation in another, unfocused Chrome window is not an
    // authority change for the page currently leased by RIMES.
    if (!focused && !affectsLease) return null;
    authorityEpoch += 1;
    const displacedLease = currentLease && currentLease.tabId !== tabId
      ? currentLease : null;
    if (displacedLease) {
      return queue(() => {
        if (!currentLease || currentLease.sourceId !== displacedLease.sourceId ||
            currentLease.revision !== displacedLease.revision ||
            currentLease.contextId !== displacedLease.contextId ||
            currentLease.tabId !== displacedLease.tabId ||
            currentLease.windowId !== displacedLease.windowId ||
            currentLease.documentId !== displacedLease.documentId) return null;
        return revokeCurrent('tab-activated');
      });
    }
    return null;
  });
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status !== 'loading' && !changeInfo.url) return;
  if ((currentLease && currentLease.tabId === tabId) || inFlightPutTabs.has(tabId)) {
    authorityEpoch += 1;
  }
  void ready.then(() => {
    if (!currentLease || currentLease.tabId !== tabId) return null;
    return queue(() => revokeCurrent('tab-navigation'));
  });
});

chrome.tabs.onRemoved.addListener(tabId => {
  if ((currentLease && currentLease.tabId === tabId) || inFlightPutTabs.has(tabId)) {
    authorityEpoch += 1;
  }
  void ready.then(() => {
    if (!currentLease || currentLease.tabId !== tabId) return null;
    return queue(() => revokeCurrent('tab-removed'));
  });
});

chrome.windows.onFocusChanged.addListener(windowId => {
  // WINDOW_ID_NONE is also emitted while an extension action popup owns
  // native focus. It is therefore not proof that the selected host page has
  // changed. A concrete different Chrome window is still an authority break.
  if (windowId === chrome.windows.WINDOW_ID_NONE) return;
  authorityEpoch += 1;
  void ready.then(() => {
    if (currentLease && currentLease.windowId !== windowId) {
      return queue(() => revokeCurrent('window-focus'));
    }
    return null;
  });
});

if (chrome.runtime.onStartup) {
  chrome.runtime.onStartup.addListener(() => {
    authorityEpoch += 1;
    void queue(() => revokeCurrent('browser-startup'));
  });
}

chrome.storage.onChanged.addListener((changes, areaName) => {
  if (areaName === 'local' && changes[Protocol.CONFIG_KEY]) authorityEpoch += 1;
  void ready.then(() => {
    if (areaName === 'local' && changes[Protocol.CONFIG_KEY] && currentLease) {
      return queue(() => revokeCurrent('configuration-changed'));
    }
    return null;
  });
});
