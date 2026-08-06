(function () {
  'use strict';

  const STATE_KEY = '__marineChromeNetworkCaptureV1';
  try {
    if (window[STATE_KEY]) return;
    Object.defineProperty(window, STATE_KEY, {
      value: true,
      configurable: false,
      enumerable: false,
      writable: false,
    });
  } catch (error) { return; }

  const nativeFetch = window.fetch;
  const xhrOpen = XMLHttpRequest.prototype.open;
  const xhrSend = XMLHttpRequest.prototype.send;
  const requests = new WeakMap();
  const MAX_CAPTURE_CHARS = 1_000_000;
  const COMMENT_PATH = /^\/x\/v2\/reply(?:\/(?:wbi\/)?main|\/reply)?$/i;

  function capturedURL(raw) {
    try {
      const parsed = new URL(String(raw || ''), location.href);
      if (!/(^|\.)bilibili\.com$/i.test(parsed.hostname) ||
          !COMMENT_PATH.test(parsed.pathname)) return '';
      return parsed.origin + parsed.pathname;
    } catch (error) { return ''; }
  }

  function postCapture(url, body) {
    if (!url || typeof body !== 'string' || !body || body.length > MAX_CAPTURE_CHARS) return;
    try {
      window.postMessage({
        __marineChrome: 'comment-capture-v1',
        url,
        body,
      }, location.origin);
    } catch (error) {}
  }

  if (typeof nativeFetch === 'function') {
    window.fetch = function () {
      const promise = Reflect.apply(nativeFetch, this, arguments);
      Promise.resolve(promise).then(response => {
        const url = capturedURL(response && response.url);
        if (!url || !response || !response.ok) return;
        try {
          response.clone().text().then(body => postCapture(url, body)).catch(() => {});
        } catch (error) {}
      }).catch(() => {});
      return promise;
    };
  }

  XMLHttpRequest.prototype.open = function (method, url) {
    try { requests.set(this, { url: String(url || ''), method: String(method || 'GET') }); }
    catch (error) {}
    return Reflect.apply(xhrOpen, this, arguments);
  };

  XMLHttpRequest.prototype.send = function () {
    const xhr = this;
    const request = requests.get(xhr) || {};
    const requestURL = capturedURL(request.url);
    if (requestURL) {
      xhr.addEventListener('load', function () {
        if (xhr.status < 200 || xhr.status >= 300) return;
        let body = '';
        try {
          if (!xhr.responseType || xhr.responseType === 'text') body = xhr.responseText || '';
          else if (xhr.responseType === 'json') body = JSON.stringify(xhr.response || null);
        } catch (error) { body = ''; }
        postCapture(capturedURL(xhr.responseURL) || requestURL, body);
      }, false);
    }
    return Reflect.apply(xhrSend, this, arguments);
  };

  function postNavigation(kind) {
    try {
      window.postMessage({
        __marineChrome: 'navigation-v1',
        kind,
        url: location.href,
      }, location.origin);
    } catch (error) {}
  }

  for (const name of ['pushState', 'replaceState']) {
    const original = history[name];
    if (typeof original !== 'function') continue;
    history[name] = function () {
      const result = Reflect.apply(original, this, arguments);
      postNavigation(name);
      return result;
    };
  }
  window.addEventListener('popstate', () => postNavigation('popstate'));
  window.addEventListener('hashchange', () => postNavigation('hashchange'));
})();
