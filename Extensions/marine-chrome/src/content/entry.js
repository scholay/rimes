(function (root) {
  'use strict';

  const Protocol = root.MarineChromeProtocol;
  if (!Protocol || root.__marineChromeContentEntryV1) return;
  root.__marineChromeContentEntryV1 = true;

  const sendMessage = message => new Promise(resolve => {
    try {
      chrome.runtime.sendMessage(message, response => {
        const error = chrome.runtime.lastError;
        if (error) resolve({ ok: false, error: error.message });
        else resolve(response || { ok: false, error: '扩展后台没有响应' });
      });
    } catch (error) {
      resolve({ ok: false, error: String(error && error.message || error) });
    }
  });

  const controller = root.MarineChromeTargetController.create(document, location, sendMessage);
  root.__marineChromeControllerV1 = controller;
  controller.start();

  root.addEventListener('message', event => {
    if (event.source !== root || event.origin !== location.origin) return;
    const data = event.data;
    if (!data || typeof data !== 'object') return;
    if (data.__marineChrome === 'comment-capture-v1') {
      let parsed;
      try { parsed = new URL(String(data.url || '')); } catch (error) { return; }
      if (!/(^|\.)bilibili\.com$/i.test(parsed.hostname) ||
          !/^\/x\/v2\/reply(?:\/(?:wbi\/)?main|\/reply)?$/i.test(parsed.pathname)) return;
      root.MarineChromeBilibili.ingestCommentPayload(data.body);
    } else if (data.__marineChrome === 'navigation-v1') {
      void controller.handleNavigation(data.url);
    }
  }, false);

  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (!message || typeof message !== 'object') return false;
    if (message.type === Protocol.MESSAGE_CAPTURE_PAGE) {
      void controller.captureGeneric().then(sendResponse).catch(error => {
        sendResponse({ ok: false, error: String(error && error.message || error) });
      });
      return true;
    }
    if (message.type === Protocol.MESSAGE_STATUS) {
      sendResponse(Object.assign({ ok: true }, controller.status()));
      return false;
    }
    return false;
  });
})(globalThis);
