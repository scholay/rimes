(function () {
  'use strict';

  const Protocol = globalThis.MarineChromeProtocol;
  const statusElement = document.getElementById('status');
  const targetElement = document.getElementById('target');
  const detailElement = document.getElementById('detail');
  const captureButton = document.getElementById('capture');
  const testButton = document.getElementById('test');
  const optionsButton = document.getElementById('options');

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

  async function refresh() {
    const response = await send({ type: Protocol.MESSAGE_STATUS });
    if (!response.ok) {
      statusElement.textContent = '后台不可用';
      return;
    }
    const state = response.connectionState || 'unknown';
    if (response.leaseActive) statusElement.textContent = 'RIMES 已锁定当前网页';
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
    if (response && response.ok) detail('网页上下文已交给 RIMES。', true);
    else if (response && response.retrying) detail('已读取页面；请在 RIMES 中启用并选中 marine-chrome。', false);
    else detail(response && response.error || '读取失败', false);
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
})();
