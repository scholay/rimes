(function (root) {
  'use strict';

  if (root.MarineChromeLeaseState) return;

  function fromContext(context, sender) {
    const tab = sender && sender.tab || {};
    return {
      tabId: tab.id,
      windowId: tab.windowId,
      documentId: String(sender && sender.documentId || ''),
      sourceId: context.sourceId,
      revision: context.revision,
      contextId: context.contextId,
      capturedAt: context.capturedAt,
      url: context.page.url,
      targetId: context.target ? context.target.id : null,
    };
  }

  function exactPayload(lease, payload) {
    return !!lease && !!payload && lease.sourceId === payload.sourceId &&
      lease.revision === payload.revision && lease.contextId === payload.contextId;
  }

  function exactSender(lease, sender) {
    return !!lease && !!sender && !!sender.tab &&
      lease.tabId === sender.tab.id && lease.windowId === sender.tab.windowId &&
      typeof sender.documentId === 'string' && !!sender.documentId &&
      lease.documentId === sender.documentId;
  }

  function validStored(value) {
    return !!value && Number.isInteger(value.tabId) && Number.isInteger(value.windowId) &&
      typeof value.documentId === 'string' && !!value.documentId &&
      typeof value.sourceId === 'string' && typeof value.contextId === 'string' &&
      Number.isFinite(value.capturedAt) &&
      Number.isSafeInteger(value.revision) && value.revision > 0 &&
      typeof value.url === 'string';
  }

  root.MarineChromeLeaseState = Object.freeze({
    fromContext,
    exactPayload,
    exactSender,
    validStored,
  });
})(globalThis);
