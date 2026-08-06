(function (root) {
  'use strict';

  if (root.MarineChromeBilibili) return;
  const Protocol = root.MarineChromeProtocol;
  const Text = root.MarineChromeText;
  const records = new Map();
  const listeners = new Set();
  const MAX_RECORDS = 1500;
  const POSITIVE_ID = /^[1-9]\d*$/;
  const SUBTITLE_RETRY_DELAYS_MS = [2000, 5000, 10000, 30000];
  let subtitleText = '';
  let subtitlePromise = null;
  let subtitleKey = '';
  let subtitleGeneration = 0;
  let subtitleRetryTimer = null;
  let subtitleRetryAttempt = 0;
  let subtitleRetryEnabled = false;

  function isVideoPage(locationLike) {
    const hostname = String(locationLike && locationLike.hostname || '').toLowerCase();
    return (hostname === 'bilibili.com' || hostname.endsWith('.bilibili.com')) &&
      /\/video\/BV[0-9A-Za-z]+/.test(String(locationLike && locationLike.pathname || ''));
  }

  function exactId(stringValue, numericValue, allowZero) {
    if (typeof stringValue === 'string') {
      const value = stringValue.trim();
      if (/^\d+$/.test(value) && (allowZero || !/^0+$/.test(value))) return value;
    }
    if (typeof numericValue === 'number' && Number.isSafeInteger(numericValue) &&
        numericValue >= (allowZero ? 0 : 1)) return String(numericValue);
    return '';
  }

  function normalizeRecord(raw) {
    const value = raw || {};
    const member = value.member || {};
    const id = exactId(value.rpid_str, value.rpid, false);
    const parent = exactId(value.parent_str, value.parent, true);
    const rootId = exactId(value.root_str, value.root, true);
    return {
      id,
      parentId: parent && !/^0+$/.test(parent) ? parent : null,
      rootId: rootId && !/^0+$/.test(rootId) ? rootId : null,
      authorName: Protocol.normalizeInline(member.uname || '', 256),
      text: Protocol.cleanText(value.content && value.content.message, 28 * 1024).trim(),
      likeCount: Number(value.like) || 0,
    };
  }

  function remember(raw) {
    const record = normalizeRecord(raw);
    if (!POSITIVE_ID.test(record.id) || !record.authorName || !record.text) return;
    const previous = records.get(record.id);
    records.set(record.id, previous ? Object.assign({}, previous, record) : record);
    while (records.size > MAX_RECORDS) records.delete(records.keys().next().value);
    for (const nested of Array.isArray(raw && raw.replies) ? raw.replies : []) remember(nested);
  }

  function ingestCommentPayload(body) {
    let parsed;
    try { parsed = JSON.parse(String(body || '')); } catch (error) { return 0; }
    const data = parsed && parsed.data;
    if (!data) return 0;
    const before = records.size;
    const list = []
      .concat(Array.isArray(data.top_replies) ? data.top_replies : [])
      .concat(Array.isArray(data.replies) ? data.replies : [])
      .concat(Array.isArray(data.reply) ? data.reply : data.reply ? [data.reply] : []);
    for (const item of list) remember(item);
    if (records.size !== before) notifyChanged();
    return records.size - before;
  }

  function notifyChanged() {
    for (const listener of listeners) {
      try { listener(); } catch (error) {}
    }
  }

  function onDataChanged(listener) {
    listeners.add(listener);
    return () => listeners.delete(listener);
  }

  function commentSearchRoot(documentLike) {
    try {
      // querySelector() resolves a selector list by document order, not by the
      // order of selectors in the list. Bilibili can leave a legacy comment
      // container before the active <bili-comments> tree, so probe each known
      // root explicitly and keep the modern component as the first choice.
      for (const selector of [
        'bili-comments',
        '#commentapp',
        '.comment-container',
        '.comment-list',
        '.reply-warp',
      ]) {
        const candidate = documentLike.querySelector(selector);
        if (candidate) return candidate;
      }
      return documentLike;
    } catch (error) { return documentLike; }
  }

  function isBoundary(element) {
    if (!element || !element.tagName) return false;
    const tag = String(element.tagName).toLowerCase();
    if (/^bili-comment-(?:reply-)?renderer$/.test(tag) ||
        tag === 'bili-comment-card' || tag === 'bili-comment-thread-renderer') return true;
    let className = '';
    try { className = typeof element.className === 'string' ? element.className : ''; }
    catch (error) {}
    return /(^|\s)(root-reply(?:-container)?|sub-reply-item|reply-item|comment-item|comment-renderer|comment-card)(\s|$)/i
      .test(className);
  }

  function boundaryFrom(value) {
    const path = Array.isArray(value) ? value : null;
    if (path) return path.find(isBoundary) || null;
    for (let current = value, depth = 0; current && depth < 24;
      current = Text.composedParent(current), depth += 1) {
      if (isBoundary(current)) return current;
    }
    return null;
  }

  function boundaryOwner(element) {
    return boundaryFrom(element);
  }

  function ownedElements(boundary, maximum) {
    return Text.collectDeep(boundary, maximum || 5000).filter(element =>
      element === boundary || boundaryOwner(element) === boundary);
  }

  function commentId(boundary) {
    const ids = new Set();
    const add = value => {
      if (typeof value === 'number') {
        if (Number.isSafeInteger(value) && value > 0) ids.add(String(value));
        return;
      }
      if (typeof value !== 'string') return;
      const normalized = value.trim();
      if (POSITIVE_ID.test(normalized)) ids.add(normalized);
    };
    for (const element of ownedElements(boundary, 3500)) {
      for (const name of ['data-rpid', 'data-reply-id', 'reply-id', 'rpid']) {
        try { add(element.getAttribute(name)); } catch (error) {}
      }
      for (const containerName of ['data', 'reply', 'comment', 'item', '_data', '__data']) {
        let container;
        try { container = element[containerName]; } catch (error) { container = null; }
        if (!container || typeof container !== 'object') continue;
        for (const name of ['rpid_str', 'rpid', 'reply_id_str', 'reply_id', 'replyId']) {
          try { add(container[name]); } catch (error) {}
        }
      }
    }
    return ids.size === 1 ? ids.values().next().value : '';
  }

  function domIdentity(boundary) {
    const elements = ownedElements(boundary, 5000);
    const authors = [];
    const bodies = [];
    for (const element of elements) {
      if (Text.isEditor(element)) continue;
      const tag = String(element.tagName || '').toLowerCase();
      let className = '';
      try { className = typeof element.className === 'string' ? element.className : ''; }
      catch (error) {}
      const href = Text.attribute(element, ['href']);
      const value = Text.textOf(element, 28 * 1024);
      if (!value) continue;
      if (/(^|[\s_-])(user-name|sub-user-name|nickname|author|name)([\s_-]|$)/i.test(className) ||
          href.includes('space.bilibili.com') || Text.attribute(element, ['id']) === 'user-name') {
        if (value.length <= 120 && !/^(?:回复|举报|点赞)/.test(value)) authors.push(value);
      }
      if (/(^|[\s_-])(reply-content|sub-reply-content|comment-content|message|content|rich-text)([\s_-]|$)/i
          .test(className) || Text.attribute(element, ['id']) === 'content' ||
          /^bili-(?:comment-)?rich-text$/.test(tag)) {
        if (!/^(?:回复|举报|分享)$/.test(value)) bodies.push(value);
      }
    }
    authors.sort((left, right) => left.length - right.length);
    bodies.sort((left, right) => left.length - right.length);
    return {
      authorName: Protocol.normalizeInline(authors[0] || '', 256),
      text: Protocol.cleanText(bodies[0] || '', 28 * 1024).trim(),
    };
  }

  function renderedBoundaries(documentLike) {
    const searchRoot = commentSearchRoot(documentLike);
    return Array.from(new Set(Text.collectDeep(searchRoot, 20000).filter(isBoundary)));
  }

  function resolveTarget(boundary, documentLike) {
    if (!boundary) return null;
    const id = commentId(boundary);
    if (id) {
      const captured = records.get(id);
      if (captured) return Object.assign({}, captured);
      const identity = domIdentity(boundary);
      if (identity.authorName && identity.text) {
        return { id, authorName: identity.authorName, text: identity.text, parentId: null, rootId: null };
      }
      return null;
    }

    const identity = domIdentity(boundary);
    if (!identity.authorName || !identity.text) return null;
    const candidates = Array.from(records.values()).filter(record =>
      record.authorName === identity.authorName && record.text === identity.text);
    if (candidates.length !== 1) return null;
    let renderedMatches = 0;
    for (const candidateBoundary of renderedBoundaries(documentLike)) {
      const candidate = domIdentity(candidateBoundary);
      if (candidate.authorName === identity.authorName && candidate.text === identity.text) {
        renderedMatches += 1;
        if (renderedMatches > 1) return null;
      }
    }
    return renderedMatches === 1 ? Object.assign({}, candidates[0]) : null;
  }

  function isCommentEditor(editor, documentLike) {
    if (!Text.isEditor(editor) || !isVideoPage(documentLike.location || root.location)) return false;
    const searchRoot = commentSearchRoot(documentLike);
    if (searchRoot !== documentLike && Text.composedContains(searchRoot, editor)) return true;
    if (boundaryFrom(editor)) return true;
    return /(?:评论|回复|友善|发一条)/.test(editorContextLabel(editor));
  }

  function editorContextLabel(editor) {
    const attributed = Text.editorLabel(editor);
    if (/^\s*回复(?:\s|@|$)/.test(attributed)) return attributed;
    for (let scope = editor, depth = 0; scope && depth < 7;
      scope = Text.composedParent(scope), depth += 1) {
      const elements = Text.collectDeep(scope, 300);
      const editors = elements.filter(Text.isEditor);
      if (editors.length !== 1 || editors[0] !== editor) continue;
      const labels = elements.filter(element => element !== editor && !Text.isEditor(element))
        .map(element => Text.textOf(element, 300))
        .map(value => (value.match(/^\s*(回复\s*@?\s*[^\s：:]+\s*[：:]?)/) || [])[1] || '')
        .filter(Boolean);
      const unique = Array.from(new Set(labels.map(value => Protocol.normalizeInline(value, 300))));
      if (unique.length === 1) return unique[0];
    }
    return attributed;
  }

  function replyAuthor(label) {
    const match = String(label || '').match(/^\s*回复\s*@?\s*(.+?)\s*(?:[：:]\s*)?$/);
    return match ? Protocol.normalizeInline(match[1], 256) : '';
  }

  function replyControl(event) {
    let path = [];
    try { path = event.composedPath().filter(value => value && value.nodeType === 1); }
    catch (error) { if (event.target) path = [event.target]; }
    for (const element of path) {
      if (Text.isEditor(element)) return null;
      const label = Text.textOf(element, 80);
      let className = '';
      try { className = typeof element.className === 'string' ? element.className : ''; }
      catch (error) {}
      const interactive = element.matches && element.matches('button,a,[role="button"]');
      if ((interactive || /(^|[-_\s])reply([-_\s]|$)/i.test(className)) &&
          /^回复(?:\s*\d+)?$/.test(label)) return { element, path };
    }
    return null;
  }

  function commentsSource() {
    const values = Array.from(records.values());
    values.sort((left, right) => right.likeCount - left.likeCount);
    const lines = values.map(record => {
      const metadata = ['id=' + record.id];
      if (record.likeCount) metadata.push(record.likeCount + '赞');
      return '· [' + metadata.join(' ') + '] ' + record.authorName + '：' +
        record.text.replace(/\s+/g, ' ');
    });
    return Protocol.cleanText(lines.join('\n'), Protocol.MAX_SOURCE_BYTES).trim();
  }

  function articleSnapshot(documentLike, locationLike) {
    let title = '';
    let description = '';
    try {
      title = Text.textOf(documentLike.querySelector('h1.video-title,h1'), 2 * 1024);
    } catch (error) {}
    if (!title) title = Text.normalize(documentLike && documentLike.title, 2 * 1024);
    try {
      const descriptionElement = documentLike.querySelector(
        '.video-desc-container,.desc-info-text,[data-vue-meta="true"][name="description"]',
      );
      description = descriptionElement && descriptionElement.tagName === 'META'
        ? Text.attribute(descriptionElement, ['content'])
        : Text.textOf(descriptionElement, Protocol.MAX_SOURCE_BYTES);
    } catch (error) {}
    // Bilibili's generic <body> is mostly player/navigation chrome while the
    // video application is still hydrating. Only the platform's explicit
    // description counts as article body; generic title/URL remain metadata
    // and must not stop the subtitle/comment readiness retry loop.
    const body = description;
    const sourceURL = String(locationLike && locationLike.href || '');
    const parts = [];
    if (title) parts.push('# ' + title);
    if (sourceURL) parts.push('> 来源：' + sourceURL);
    if (body) parts.push(body);
    const text = Protocol.cleanText(parts.join('\n\n'), Protocol.MAX_SOURCE_BYTES).trim();
    const quality = body ? 'article' : title ? 'metadata' : sourceURL ? 'locator' : 'empty';
    return {
      ready: quality === 'article',
      quality,
      text,
      body,
      title,
      url: sourceURL,
    };
  }

  function articleSource(documentLike, locationLike) {
    return articleSnapshot(documentLike, locationLike).text;
  }

  function withTimeout(promise, milliseconds) {
    return Promise.race([
      promise,
      new Promise(resolve => setTimeout(() => resolve(''), milliseconds)),
    ]);
  }

  async function fetchJSON(url, timeoutMilliseconds) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMilliseconds || 4500);
    try {
      const response = await fetch(url, {
        credentials: 'include',
        cache: 'no-store',
        signal: controller.signal,
      });
      if (!response.ok) return null;
      return await response.json();
    } catch (error) { return null; }
    finally { clearTimeout(timer); }
  }

  function subtitleRequest(locationLike) {
    const match = String(locationLike && locationLike.pathname || '').match(/\/video\/(BV[0-9A-Za-z]+)/);
    if (!match) return null;
    const bvid = match[1];
    const part = Math.max(1, Number(new URLSearchParams(locationLike.search || '').get('p')) || 1);
    return { bvid, part, key: bvid + ':p' + part };
  }

  async function loadSubtitle(locationLike) {
    const request = subtitleRequest(locationLike);
    if (!request) return '';
    const { bvid, part } = request;
    const view = await fetchJSON(
      'https://api.bilibili.com/x/web-interface/view?bvid=' + encodeURIComponent(bvid), 4500,
    );
    if (!view || view.code !== 0 || !view.data) return '';
    const pages = Array.isArray(view.data.pages) ? view.data.pages : [];
    const cid = pages[part - 1] && pages[part - 1].cid || view.data.cid;
    const aid = view.data.aid;
    if (!aid || !cid) return '';
    const player = await fetchJSON(
      'https://api.bilibili.com/x/player/wbi/v2?aid=' + encodeURIComponent(aid) +
        '&cid=' + encodeURIComponent(cid), 4500,
    );
    const tracks = player && player.code === 0 && player.data && player.data.subtitle &&
      player.data.subtitle.subtitles;
    const track = Array.isArray(tracks) && tracks.find(item => item && item.subtitle_url);
    if (!track) return '';
    let subtitleURL = String(track.subtitle_url || '');
    if (subtitleURL.startsWith('//')) subtitleURL = 'https:' + subtitleURL;
    if (subtitleURL.startsWith('http://')) subtitleURL = 'https://' + subtitleURL.slice(7);
    const data = await fetchJSON(subtitleURL, 4500);
    const cues = data && Array.isArray(data.body) ? data.body : [];
    return Protocol.cleanText(cues.map(item => String(item && item.content || '').trim())
      .filter(Boolean).join('\n'), Protocol.MAX_SOURCE_BYTES).trim();
  }

  function stopSubtitleRetry() {
    if (subtitleRetryTimer) clearTimeout(subtitleRetryTimer);
    subtitleRetryTimer = null;
    subtitleRetryAttempt = 0;
  }

  function scheduleSubtitleRetry(locationLike, generation, key) {
    if (!subtitleRetryEnabled || subtitleRetryTimer || subtitleText ||
        generation !== subtitleGeneration || key !== subtitleKey) return;
    const delay = SUBTITLE_RETRY_DELAYS_MS[Math.min(
      subtitleRetryAttempt,
      SUBTITLE_RETRY_DELAYS_MS.length - 1,
    )];
    subtitleRetryAttempt += 1;
    subtitleRetryTimer = setTimeout(() => {
      subtitleRetryTimer = null;
      if (!subtitleRetryEnabled || subtitleText ||
          generation !== subtitleGeneration || key !== subtitleKey) return;
      if (root.document && root.document.hidden) {
        scheduleSubtitleRetry(locationLike, generation, key);
        return;
      }
      void prefetchSubtitle(locationLike, true);
    }, delay);
  }

  function prefetchSubtitle(locationLike, retryUntilReady) {
    const request = subtitleRequest(locationLike);
    if (!request) return Promise.resolve('');
    if (request.key !== subtitleKey) {
      stopSubtitleRetry();
      subtitleGeneration += 1;
      subtitleKey = request.key;
      subtitleText = '';
      subtitlePromise = null;
      subtitleRetryEnabled = retryUntilReady === true;
    } else if (retryUntilReady === true) {
      subtitleRetryEnabled = true;
    }
    if (subtitleText) return Promise.resolve(subtitleText);
    if (subtitlePromise) return subtitlePromise;

    const generation = subtitleGeneration;
    let pending;
    pending = loadSubtitle(locationLike).then(value => {
      if (generation !== subtitleGeneration || request.key !== subtitleKey) return '';
      if (value && value !== subtitleText) {
        subtitleText = value;
        subtitleRetryEnabled = false;
        stopSubtitleRetry();
        notifyChanged();
      }
      return subtitleText;
    }).catch(() => '').finally(() => {
      // An empty response can mean the player API or subtitle track has not
      // appeared yet. Do not memoize that absence: a later controller retry
      // must be allowed to perform the complete request again. A successful
      // subtitle remains cached for this exact BV/part until navigation.
      if (generation === subtitleGeneration && request.key === subtitleKey &&
          subtitlePromise === pending && !subtitleText) {
        subtitlePromise = null;
        scheduleSubtitleRetry(locationLike, generation, request.key);
      }
    });
    subtitlePromise = pending;
    return subtitlePromise;
  }

  async function bestSource(documentLike, locationLike) {
    if (!subtitleText) await withTimeout(prefetchSubtitle(locationLike, true), 900);
    if (subtitleText) return { kind: 'subtitle', text: subtitleText };
    const comments = commentsSource();
    if (comments) return { kind: 'comments', text: comments };
    const article = articleSnapshot(documentLike, locationLike);
    return article.ready ? { kind: 'article', text: article.text } : null;
  }

  function resetForNavigation() {
    records.clear();
    stopSubtitleRetry();
    subtitleRetryEnabled = false;
    subtitleGeneration += 1;
    subtitleKey = '';
    subtitleText = '';
    subtitlePromise = null;
    notifyChanged();
  }

  root.MarineChromeBilibili = Object.freeze({
    isVideoPage,
    exactId,
    normalizeRecord,
    ingestCommentPayload,
    onDataChanged,
    commentSearchRoot,
    isBoundary,
    boundaryFrom,
    commentId,
    domIdentity,
    resolveTarget,
    isCommentEditor,
    editorContextLabel,
    replyAuthor,
    replyControl,
    commentsSource,
    articleSnapshot,
    articleSource,
    subtitleRequest,
    prefetchSubtitle,
    bestSource,
    resetForNavigation,
    _records: records,
  });
})(globalThis);
