(function () {
  'use strict';

  const Protocol = globalThis.MarineChromeProtocol;
  const apiBaseInput = document.getElementById('api-base');
  const connectButton = document.getElementById('connect');
  const confirmButton = document.getElementById('confirm');
  const useAddressButton = document.getElementById('use-address');
  const resetAddressButton = document.getElementById('reset-address');
  const reauthorizeButton = document.getElementById('reauthorize');
  const statusDot = document.getElementById('status-dot');
  const statusTitle = document.getElementById('status-title');
  const statusDetail = document.getElementById('status-detail');
  document.getElementById('extension-id').textContent = chrome.runtime.id;
  const extensionIdentityMatches = Protocol.extensionIdentityMatches(chrome.runtime.id);

  let statusTimer = null;
  let statusRefreshPending = false;

  function send(message) {
    return new Promise(resolve => {
      chrome.runtime.sendMessage(message, response => {
        const error = chrome.runtime.lastError;
        resolve(error ? { ok: false, error: error.message } : response || { ok: false });
      });
    });
  }

  function showStatus(kind, title, detail) {
    statusDot.className = 'dot' + (kind ? ' ' + kind : '');
    statusTitle.textContent = title;
    statusDetail.textContent = detail || '';
  }

  function setBusy(busy) {
    const disabled = busy || !extensionIdentityMatches;
    for (const button of [connectButton, confirmButton, useAddressButton,
      resetAddressButton, reauthorizeButton]) button.disabled = disabled;
    apiBaseInput.disabled = disabled;
  }

  function requireExpectedExtensionIdentity() {
    if (extensionIdentityMatches) return true;
    stopStatusWatch();
    confirmButton.hidden = true;
    connectButton.hidden = false;
    setBusy(false);
    showStatus('error', '需要重新安装 marine-chrome',
      Protocol.extensionIdentityMismatchDetail(chrome.runtime.id));
    return false;
  }

  async function storedConfig() {
    const stored = await chrome.storage.local.get(Protocol.CONFIG_KEY);
    return stored && stored[Protocol.CONFIG_KEY] || {};
  }

  async function currentAPIBase() {
    const config = await storedConfig();
    return Protocol.normalizeAPIBase(config.apiBase) || Protocol.DEFAULT_API_BASE;
  }

  async function prepareLocalNetwork(apiBase) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), Protocol.REQUEST_TIMEOUT_MS);
    try {
      const response = await fetch(apiBase + '/v1/marine-chrome/health', {
        method: 'GET',
        cache: 'no-store',
        credentials: 'omit',
        signal: controller.signal,
      });
      let value = null;
      try { value = await response.json(); } catch (error) {}
      if (!response.ok) throw new Error(String(value && value.error || 'HTTP ' + response.status));
      if (!value || value.protocolVersion !== Protocol.VERSION) {
        throw new Error('RIMES 协议版本不兼容');
      }
      if (value.extensionId && value.extensionId !== chrome.runtime.id) {
        throw new Error('扩展身份与 RIMES 不匹配');
      }
      return value;
    } catch (error) {
      if (error && error.name === 'AbortError') throw new Error('连接 RIMES 超时');
      throw error;
    } finally { clearTimeout(timer); }
  }

  function renderConnection(response) {
    if (!requireExpectedExtensionIdentity()) return;
    if (!response || !response.ok) {
      showStatus('error', '连接状态不可用', response && response.error || '扩展后台未响应');
      return;
    }
    const state = response.connectionState || 'unknown';
    const detail = response.connectionDetail || '';
    const code = response.pairingDisplayCode;
    const codeText = code ? '确认码：' + code + '。' : '';
    const states = {
      connected: ['ok', '已连接 RIMES', detail || '无需再配置'],
      stored: ['', '正在验证已保存的连接…', detail],
      checking: ['', '正在查找 RIMES…', detail],
      awaitingApproval: ['', '请先在 RIMES 中点“允许”', codeText + (detail || '')],
      awaitingConfirmation: ['', '请在本页确认连接',
        codeText + '确认它与 RIMES 弹窗一致，然后点击“确认连接”。'],
      confirming: ['', '正在完成安全连接…', codeText + (detail || '')],
      busy: ['', '正在等待 RIMES…', detail],
      denied: ['error', '连接已拒绝', detail],
      expired: ['error', '连接请求已过期', detail],
      unavailable: ['error', '找不到本机 RIMES', detail],
      incompatible: ['error', '版本或扩展身份不兼容', detail],
      manualRequired: ['error', '请更新 RIMES', detail],
      storageUnsafe: ['error', 'Chrome 安全存储不可用', detail],
      failed: ['error', '连接失败', detail],
      disconnected: ['', '尚未连接 RIMES', detail || '点击“连接 RIMES”开始'],
      unknown: ['', '正在检查…', detail],
    };
    const presentation = states[state] || states.unknown;
    showStatus(presentation[0], presentation[1], presentation[2]);
    const needsConfirmation = response.pairingNeedsConfirmation === true ||
      state === 'awaitingConfirmation';
    confirmButton.hidden = !needsConfirmation;
    connectButton.hidden = needsConfirmation;
    connectButton.textContent = state === 'connected' ? '检查连接' : '连接 RIMES';
    if (['connected', 'denied', 'expired', 'unavailable', 'incompatible',
      'manualRequired', 'storageUnsafe', 'failed', 'disconnected'].includes(state)) {
      stopStatusWatch();
    }
  }

  async function refreshStatus() {
    if (!requireExpectedExtensionIdentity()) return null;
    if (statusRefreshPending) return null;
    statusRefreshPending = true;
    try {
      const response = await send({ type: Protocol.MESSAGE_STATUS });
      renderConnection(response);
      return response;
    } finally { statusRefreshPending = false; }
  }

  function startStatusWatch() {
    if (!requireExpectedExtensionIdentity()) return;
    if (statusTimer) return;
    statusTimer = setInterval(() => { void refreshStatus(); }, 500);
  }

  function stopStatusWatch() {
    if (statusTimer) clearInterval(statusTimer);
    statusTimer = null;
  }

  async function connect(force = false, apiBaseOverride = '') {
    if (!requireExpectedExtensionIdentity()) return;
    setBusy(true);
    showStatus('', '正在查找本机 RIMES…', '若 Chrome 询问本地网络访问，请选择允许。');
    try {
      const apiBase = Protocol.normalizeAPIBase(apiBaseOverride) || await currentAPIBase();
      if (!apiBase) throw new Error('RIMES 地址必须是带端口的 http://127.0.0.1 地址');
      apiBaseInput.value = apiBase;
      await prepareLocalNetwork(apiBase);
      startStatusWatch();
      const result = await send({
        type: Protocol.MESSAGE_PAIR,
        force: !!force,
        apiBase,
      });
      const status = await refreshStatus();
      if (!result.ok && (!status || !['denied', 'expired', 'storageUnsafe']
        .includes(status.connectionState))) {
        showStatus('error', '连接失败', result.error || 'RIMES 未完成配对');
      }
    } catch (error) {
      stopStatusWatch();
      showStatus('error', '连接失败', String(error && error.message || error));
    } finally { setBusy(false); }
  }

  async function confirmConnection(event) {
    if (!requireExpectedExtensionIdentity()) return;
    if (!event || event.isTrusted !== true) return;
    setBusy(true);
    showStatus('', '正在完成安全连接…', '正在向 RIMES 确认本次连接。');
    startStatusWatch();
    try {
      const result = await send({ type: Protocol.MESSAGE_CONFIRM_PAIR });
      const status = await refreshStatus();
      if (!result.ok && (!status || !['denied', 'expired', 'storageUnsafe']
        .includes(status.connectionState))) {
        showStatus('error', '确认失败', result.error || 'RIMES 未完成配对');
      }
    } finally { setBusy(false); }
  }

  connectButton.addEventListener('click', () => { void connect(false); });
  confirmButton.addEventListener('click', event => { void confirmConnection(event); });

  useAddressButton.addEventListener('click', () => {
    const apiBase = Protocol.normalizeAPIBase(apiBaseInput.value);
    if (!apiBase) {
      showStatus('error', '地址无效', '请输入带端口的 http://127.0.0.1 地址');
      return;
    }
    void connect(false, apiBase);
  });

  resetAddressButton.addEventListener('click', () => {
    apiBaseInput.value = Protocol.DEFAULT_API_BASE;
    void connect(false, Protocol.DEFAULT_API_BASE);
  });

  reauthorizeButton.addEventListener('click', () => { void connect(true, apiBaseInput.value); });

  async function initializeOptions() {
    if (!requireExpectedExtensionIdentity()) return;
    const [config, status] = await Promise.all([
      storedConfig(),
      send({ type: Protocol.MESSAGE_STATUS }),
    ]);
    const apiBase = Protocol.normalizeAPIBase(status && status.pairingAPIBase) ||
      Protocol.normalizeAPIBase(config.apiBase) || Protocol.DEFAULT_API_BASE;
    apiBaseInput.value = apiBase;
    renderConnection(status);
    if (!status || !status.ok || status.connectionState === 'storageUnsafe' ||
        status.pairingNeedsConfirmation) return null;
    if (status.pairingInFlight) {
      startStatusWatch();
      return;
    }
    await connect(status.pairingForce === true, apiBase);
  }

  void initializeOptions();
})();
