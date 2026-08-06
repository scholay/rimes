(function () {
  'use strict';

  const Protocol = globalThis.MarineChromeProtocol;
  const statusElement = document.getElementById('status');
  const targetElement = document.getElementById('target');
  const detailElement = document.getElementById('detail');
  const captureButton = document.getElementById('capture');
  const testButton = document.getElementById('test');
  const optionsButton = document.getElementById('options');
  let refreshPending = false;
  let retryDetailVisible = false;

  function send(message) {
    return new Promise(resolve => {
      chrome.runtime.sendMessage(message, response => {
        const error = chrome.runtime.lastError;
        resolve(error ? { ok: false, error: error.message } : response || { ok: false });
      });
    });
  }

  function detail(message, ok) {
    detailElement.textContent = message || '';
    detailElement.className = 'detail' + (ok ? ' ok' : '');
  }

  function retryMessage(message, reason) {
    const suffix = reason === 'page-not-foreground' || reason === 'page-lost-foreground'
      ? '；已自动等待，回到该网页后会继续读取。'
      : '；已自动轮询，内容就绪后会继续读取。';
    return (message || '网页暂时不可读取') + suffix;
  }

  async function refresh() {
    if (refreshPending) return;
    refreshPending = true;
    try {
      const response = await send({ type: Protocol.MESSAGE_STATUS });
      if (!response.ok) {
        statusElement.textContent = '后台不可用';
        return;
      }
      const state = response.connectionState || 'unknown';
      if (response.pageRetrying) {
        statusElement.textContent = response.pageRetryReason === 'page-not-foreground' ||
          response.pageRetryReason === 'page-lost-foreground'
          ? '正在等待网页回到前台…'
          : '正在等待网页可读取…';
      }
      else if (response.leaseActive) statusElement.textContent = 'RIMES 已锁定当前网页';
      else if (state === 'connected') statusElement.textContent = '已连接 · 等待网页目标';
      else if (state === 'checking' || state === 'stored') statusElement.textContent = '正在检查 RIMES…';
      else if (state === 'awaitingApproval') statusElement.textContent = '等待 RIMES 确认';
      else if (state === 'awaitingConfirmation') statusElement.textContent = '请到连接设置页确认';
      else if (state === 'confirming') statusElement.textContent = '正在完成安全连接…';
      else if (state === 'storageUnsafe') statusElement.textContent = 'Chrome 安全存储不可用';
      else if (response.configured) statusElement.textContent = '连接需要检查';
      else statusElement.textContent = '尚未连接 RIMES';
      captureButton.textContent = response.configured ? '读取当前网页' : '连接 RIMES';
      if (response.targetSummary) {
        targetElement.hidden = false;
        targetElement.textContent = response.targetSummary;
      } else targetElement.hidden = true;
      if (response.pageRetrying) {
        retryDetailVisible = true;
        detail(
          retryMessage(response.pageRetryDetail, response.pageRetryReason),
          false,
        );
      } else if (retryDetailVisible) {
        retryDetailVisible = false;
        detail(response.leaseActive ? '网页上下文已交给 RIMES。' : '自动读取已停止，请重试。',
          response.leaseActive);
      }
    } finally { refreshPending = false; }
  }

  captureButton.addEventListener('click', async () => {
    const status = await send({ type: Protocol.MESSAGE_STATUS });
    if (!status || !status.configured) {
      chrome.runtime.openOptionsPage();
      return;
    }
    captureButton.disabled = true;
    detail('正在读取当前网页…', false);
    const response = await send({ type: Protocol.MESSAGE_CAPTURE });
    captureButton.disabled = false;
    if (response && response.ok) {
      retryDetailVisible = false;
      detail('网页上下文已交给 RIMES。', true);
    } else if (response && response.retrying) {
      retryDetailVisible = true;
      detail(
        retryMessage(response.error, response.retryReason),
        false,
      );
    } else {
      retryDetailVisible = false;
      detail(response && response.error || '读取失败', false);
    }
    await refresh();
  });

  testButton.addEventListener('click', async () => {
    testButton.disabled = true;
    const response = await send({ type: Protocol.MESSAGE_TEST });
    testButton.disabled = false;
    if (response && response.ok) detail('RIMES 连接正常。', true);
    else detail((response && response.error || '连接失败') + '；请打开设置自动重新连接。', false);
    await refresh();
  });

  optionsButton.addEventListener('click', () => chrome.runtime.openOptionsPage());
  void refresh().then(async () => {
    const status = await send({ type: Protocol.MESSAGE_STATUS });
    if (status && status.configured && status.connectionState !== 'connected') {
      await send({ type: Protocol.MESSAGE_TEST });
      await refresh();
    }
  });
  setInterval(() => { void refresh(); }, 1000);
})();
