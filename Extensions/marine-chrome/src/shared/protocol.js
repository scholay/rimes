(function (root) {
  'use strict';

  if (root.MarineChromeProtocol) return;

  const VERSION = 1;
  const DEFAULT_API_BASE = 'http://127.0.0.1:47700';
  const EXPECTED_EXTENSION_ID = 'gpieknckmapliabifhgcedcjoigdjaah';
  const CONFIG_KEY = 'marineChromeConfigV1';
  const SESSION_KEY = 'marineChromeLeaseV1';
  const PAIRING_SESSION_KEY = 'marineChromePairingV1';
  const MESSAGE_CONTEXT = 'marine-chrome/context-v1';
  const MESSAGE_CAPTURE = 'marine-chrome/capture-active-tab-v1';
  const MESSAGE_CAPTURE_PAGE = 'marine-chrome/capture-page-v1';
  const MESSAGE_FOREGROUND = 'marine-chrome/foreground-probe-v1';
  const MESSAGE_STATUS = 'marine-chrome/status-v1';
  const MESSAGE_TEST = 'marine-chrome/test-v1';
  const MESSAGE_PAIR = 'marine-chrome/pair-interactive-v1';
  const MESSAGE_CONFIRM_PAIR = 'marine-chrome/confirm-pair-v1';
  const MAX_CONTEXT_BYTES = 240 * 1024;
  const MAX_SOURCE_BYTES = 170 * 1024;
  const MAX_TARGET_TEXT_BYTES = 28 * 1024;
  const MAX_TARGET_SUMMARY_BYTES = 1800;
  const MAX_TITLE_BYTES = 2 * 1024;
  const MAX_PLATFORM_BYTES = 128;
  const MAX_CAPTURE_AGE_SECONDS = 5 * 60;
  const MAX_FUTURE_SKEW_SECONDS = 60;
  const HEARTBEAT_INTERVAL_MS = 2000;
  const LEASE_RESTORE_SECONDS = 6;
  const REQUEST_TIMEOUT_MS = 4000;
  const PAIRING_POLL_INTERVAL_MS = 1000;
  const SERVER_PROOF_PREFIX = 'marine-chrome-server-v1\n';
  const EXTENSION_REINSTALL_GUIDANCE =
    '请打开 chrome://extensions，移除此扩展，然后从当前 Extensions/marine-chrome 目录重新“加载已解压的扩展程序”；点击“重新加载”不能修复旧扩展 ID。';
  const IDENTIFIER_RE = /^[A-Za-z0-9_.:-]{1,256}(?![\s\S])/;
  const SOURCE_KINDS = new Set(['selection', 'article', 'subtitle', 'comments']);
  const DISALLOWED_CONTROL_RE = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/;

  function nowSeconds() {
    return Date.now() / 1000;
  }

  function nextTimestamp(previous, candidate) {
    const now = Number.isFinite(candidate) ? candidate : nowSeconds();
    return Number.isFinite(previous) && previous >= now ? previous + 0.000001 : now;
  }

  function utf8Bytes(value) {
    return new TextEncoder().encode(String(value == null ? '' : value)).length;
  }

  function truncateUtf8(value, maximumBytes) {
    const text = String(value == null ? '' : value);
    const budget = Math.max(0, Number(maximumBytes) || 0);
    if (utf8Bytes(text) <= budget) return text;
    let low = 0;
    let high = text.length;
    while (low < high) {
      const middle = Math.ceil((low + high) / 2);
      if (utf8Bytes(text.slice(0, middle)) <= budget) low = middle;
      else high = middle - 1;
    }
    let end = low;
    if (end > 0 && /[\uD800-\uDBFF]/.test(text.charAt(end - 1))) end -= 1;
    return text.slice(0, end);
  }

  function cleanText(value, maximumBytes) {
    const text = String(value == null ? '' : value)
      .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, ' ')
      .replace(/\r\n?/g, '\n');
    return truncateUtf8(text, maximumBytes);
  }

  function normalizeInline(value, maximumBytes) {
    return cleanText(value, maximumBytes)
      .replace(/[\s\u00a0]+/g, ' ')
      .trim();
  }

  function boundedText(value, maximumBytes) {
    return typeof value === 'string' && utf8Bytes(value) <= maximumBytes &&
      !DISALLOWED_CONTROL_RE.test(value);
  }

  function validIdentifier(value) {
    return typeof value === 'string' && IDENTIFIER_RE.test(value) &&
      utf8Bytes(value) <= 256;
  }

  function validTimestamp(value, referenceSeconds) {
    const reference = Number.isFinite(referenceSeconds) ? referenceSeconds : nowSeconds();
    return Number.isFinite(value) && value >= reference - MAX_CAPTURE_AGE_SECONDS &&
      value <= reference + MAX_FUTURE_SKEW_SECONDS;
  }

  function randomIdentifier(prefix) {
    let value = '';
    try { value = crypto.randomUUID(); }
    catch (error) {
      value = Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
    }
    return String(prefix || '') + value;
  }

  function normalizeAPIBase(raw) {
    const candidate = String(raw || DEFAULT_API_BASE).trim().replace(/\/+$/, '');
    let parsed;
    try { parsed = new URL(candidate); } catch (error) { return ''; }
    if (parsed.protocol !== 'http:' || parsed.hostname !== '127.0.0.1') return '';
    if (parsed.username || parsed.password || parsed.search || parsed.hash) return '';
    if (parsed.pathname && parsed.pathname !== '/') return '';
    if (!parsed.port || Number(parsed.port) < 1 || Number(parsed.port) > 65535) return '';
    return parsed.origin;
  }

  function normalizeToken(raw) {
    const token = typeof raw === 'string' ? raw.trim() : '';
    return /^[A-Za-z0-9_-]{43}$/.test(token) ? token : '';
  }

  function extensionIdentityMatches(runtimeId) {
    return runtimeId === EXPECTED_EXTENSION_ID;
  }

  function extensionIdentityMismatchDetail(runtimeId) {
    const actual = typeof runtimeId === 'string' && runtimeId ? runtimeId : '未知';
    return '扩展身份与 RIMES 不匹配。当前 ID：' + actual +
      '；预期 ID：' + EXPECTED_EXTENSION_ID + '。' + EXTENSION_REINSTALL_GUIDANCE;
  }

  function trustedExtensionPageURL(raw, runtimeId) {
    if (!extensionIdentityMatches(runtimeId)) return false;
    let parsed;
    try { parsed = new URL(String(raw || '')); } catch (error) { return false; }
    return parsed.protocol === 'chrome-extension:' && parsed.hostname === runtimeId &&
      !parsed.port && !parsed.username && !parsed.password && !parsed.search && !parsed.hash &&
      (parsed.pathname === '/options/options.html' || parsed.pathname === '/popup/popup.html');
  }

  function trustedOptionsPageURL(raw, runtimeId) {
    if (!trustedExtensionPageURL(raw, runtimeId)) return false;
    try { return new URL(String(raw || '')).pathname === '/options/options.html'; }
    catch (error) { return false; }
  }

  function serverProofInput(nonce) {
    return SERVER_PROOF_PREFIX + String(nonce || '');
  }

  function pairingCredentialAuthorized(session) {
    return !!session && session.challengeSeen === true && session.confirmed === true;
  }

  function validPageURL(raw) {
    if (!boundedText(raw, 8 * 1024)) return false;
    try {
      const parsed = new URL(raw);
      return (parsed.protocol === 'http:' || parsed.protocol === 'https:') &&
        !!parsed.hostname && !parsed.username && !parsed.password;
    } catch (error) { return false; }
  }

  function makeForegroundProbe(rawURL) {
    const url = String(rawURL || '');
    return validPageURL(url) ? { protocolVersion: VERSION, url } : null;
  }

  function validateForegroundProbe(payload) {
    if (!payload || payload.protocolVersion !== VERSION || !validPageURL(payload.url)) {
      return false;
    }
    const keys = Object.keys(payload).sort();
    return keys.length === 2 && keys[0] === 'protocolVersion' && keys[1] === 'url';
  }

  function makeContextId(sourceId, revision, platform) {
    const compactPlatform = normalizeInline(platform || 'web', 64)
      .toLowerCase().replace(/[^a-z0-9_.-]+/g, '-') || 'web';
    return ['marine-chrome', compactPlatform, sourceId, String(revision)].join(':');
  }

  function normalizeTarget(target) {
    if (!target) return null;
    const id = normalizeInline(target.id, 256);
    const authorName = normalizeInline(target.authorName, 256);
    const text = cleanText(target.text, MAX_TARGET_TEXT_BYTES).trim();
    const parentId = target.parentId == null || target.parentId === ''
      ? null : normalizeInline(target.parentId, 256);
    const rootId = target.rootId == null || target.rootId === ''
      ? null : normalizeInline(target.rootId, 256);
    if (!validIdentifier(id) || !authorName || !text) return null;
    if (parentId !== null && !validIdentifier(parentId)) return null;
    if (rootId !== null && !validIdentifier(rootId)) return null;
    return { id, authorName, text, parentId, rootId };
  }

  function validTarget(target) {
    return !!target && validIdentifier(target.id) &&
      boundedText(target.authorName, 256) && !!target.authorName.trim() &&
      boundedText(target.text, 32 * 1024) && !!target.text.trim() &&
      (target.parentId == null || validIdentifier(target.parentId)) &&
      (target.rootId == null || validIdentifier(target.rootId));
  }

  function makeContext(input) {
    const mode = input && input.mode === 'reply' ? 'reply' : 'direct';
    const target = mode === 'reply' ? normalizeTarget(input.target) : null;
    if (mode === 'reply' && !target) return null;
    const kind = String(input && input.source && input.source.kind || '');
    const sourceText = cleanText(input && input.source && input.source.text, MAX_SOURCE_BYTES).trim();
    if (!SOURCE_KINDS.has(kind) || !sourceText) return null;
    const payload = {
      protocolVersion: VERSION,
      sourceId: String(input.sourceId || ''),
      revision: Number(input.revision) || 0,
      contextId: String(input.contextId || ''),
      capturedAt: Number(input.capturedAt) || nowSeconds(),
      page: {
        platform: normalizeInline(input.page && input.page.platform, 128),
        url: String(input.page && input.page.url || ''),
        title: normalizeInline(input.page && input.page.title, 2 * 1024),
      },
      mode,
      targetSummary: normalizeInline(input.targetSummary, MAX_TARGET_SUMMARY_BYTES),
      target,
      source: { kind, text: sourceText },
    };
    return validateContext(payload) ? payload : null;
  }

  function validateContext(payload) {
    if (!payload || payload.protocolVersion !== VERSION) return false;
    if (!validIdentifier(payload.sourceId) || !validIdentifier(payload.contextId) ||
        !Number.isSafeInteger(payload.revision) || payload.revision <= 0) return false;
    if (!validTimestamp(payload.capturedAt) || !payload.page ||
        !boundedText(payload.page.platform, MAX_PLATFORM_BYTES) ||
        !payload.page.platform.trim() || !validPageURL(payload.page.url) ||
        !boundedText(payload.page.title, MAX_TITLE_BYTES) ||
        !boundedText(payload.targetSummary, MAX_TARGET_SUMMARY_BYTES)) return false;
    if (payload.mode !== 'direct' && payload.mode !== 'reply') return false;
    if (payload.mode === 'direct' && payload.target !== null) return false;
    if (payload.mode === 'reply' && !validTarget(payload.target)) return false;
    if (!payload.source || !SOURCE_KINDS.has(payload.source.kind) ||
        !boundedText(payload.source.text, MAX_SOURCE_BYTES) ||
        !payload.source.text.trim()) return false;
    return utf8Bytes(JSON.stringify(payload)) <= MAX_CONTEXT_BYTES;
  }

  function makeHeartbeat(context) {
    return {
      protocolVersion: VERSION,
      sourceId: context.sourceId,
      revision: context.revision,
      contextId: context.contextId,
      capturedAt: nowSeconds(),
      url: context.page.url,
      targetId: context.target ? context.target.id : null,
    };
  }

  function makeRevocation(lease, capturedAt) {
    return {
      protocolVersion: VERSION,
      sourceId: lease.sourceId,
      revision: lease.revision,
      capturedAt: Number(capturedAt) || nowSeconds(),
      contextId: lease.contextId || null,
    };
  }

  root.MarineChromeProtocol = Object.freeze({
    VERSION,
    DEFAULT_API_BASE,
    EXPECTED_EXTENSION_ID,
    CONFIG_KEY,
    SESSION_KEY,
    PAIRING_SESSION_KEY,
    MESSAGE_CONTEXT,
    MESSAGE_CAPTURE,
    MESSAGE_CAPTURE_PAGE,
    MESSAGE_FOREGROUND,
    MESSAGE_STATUS,
    MESSAGE_TEST,
    MESSAGE_PAIR,
    MESSAGE_CONFIRM_PAIR,
    MAX_CONTEXT_BYTES,
    MAX_SOURCE_BYTES,
    MAX_TARGET_TEXT_BYTES,
    MAX_CAPTURE_AGE_SECONDS,
    MAX_FUTURE_SKEW_SECONDS,
    HEARTBEAT_INTERVAL_MS,
    LEASE_RESTORE_SECONDS,
    REQUEST_TIMEOUT_MS,
    PAIRING_POLL_INTERVAL_MS,
    SERVER_PROOF_PREFIX,
    EXTENSION_REINSTALL_GUIDANCE,
    IDENTIFIER_RE,
    nowSeconds,
    nextTimestamp,
    utf8Bytes,
    truncateUtf8,
    cleanText,
    normalizeInline,
    boundedText,
    validIdentifier,
    validTimestamp,
    randomIdentifier,
    normalizeAPIBase,
    normalizeToken,
    extensionIdentityMatches,
    extensionIdentityMismatchDetail,
    trustedExtensionPageURL,
    trustedOptionsPageURL,
    serverProofInput,
    pairingCredentialAuthorized,
    validPageURL,
    makeForegroundProbe,
    validateForegroundProbe,
    makeContextId,
    normalizeTarget,
    validTarget,
    makeContext,
    validateContext,
    makeHeartbeat,
    makeRevocation,
  });
})(globalThis);
