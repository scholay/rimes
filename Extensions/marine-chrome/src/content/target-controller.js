(function (root) {
  'use strict';

  if (root.MarineChromeTargetController) return;
  const Protocol = root.MarineChromeProtocol;
  const Text = root.MarineChromeText;
  const Bilibili = root.MarineChromeBilibili;
  const Builder = root.MarineChromeContextBuilder;
  const REPLY_HANDOFF_MS = 4000;

  class Controller {
    constructor(documentLike, locationLike, sendMessage) {
      this.document = documentLike;
      this.location = locationLike;
      this.pageURL = String(locationLike && locationLike.href || '');
      this.sendMessage = sendMessage;
      this.sourceId = Protocol.randomIdentifier('page-');
      this.revision = 0;
      this.generation = 0;
      this.active = null;
      this.pendingReply = null;
      this.pendingTimer = null;
      this.heartbeatTimer = null;
      this.retryTimer = null;
      this.blurTimer = null;
      this.refreshTimer = null;
      this.positionFrame = null;
      this.transportQueue = Promise.resolve();
      this.overlay = null;
      this.started = false;
      this.removeDataListener = null;
      this.bound = {
        click: event => this.handleClick(event),
        focusin: event => this.handleFocusIn(event),
        focusout: () => this.handleFocusOut(),
        keydown: event => this.handleKeyDown(event),
        pagehide: () => { void this.clear('pagehide'); },
        visibility: () => {
          if (this.document.hidden) void this.clear('page-hidden');
        },
        focus: () => setTimeout(() => this.rearmFocusedEditor(), 0),
        position: () => this.scheduleOverlay(),
      };
    }

    start() {
      if (this.started) return;
      this.started = true;
      if (Bilibili.isVideoPage(this.location)) {
        this.document.addEventListener('click', this.bound.click, true);
        this.document.addEventListener('focusin', this.bound.focusin, true);
        this.document.addEventListener('focusout', this.bound.focusout, true);
        this.document.addEventListener('keydown', this.bound.keydown, true);
        Bilibili.prefetchSubtitle(this.location);
      }
      this.document.addEventListener('visibilitychange', this.bound.visibility, true);
      root.addEventListener('pagehide', this.bound.pagehide, true);
      root.addEventListener('focus', this.bound.focus, true);
      root.addEventListener('scroll', this.bound.position, true);
      root.addEventListener('resize', this.bound.position, false);
      this.removeDataListener = Bilibili.onDataChanged(() => this.contextDataChanged());
    }

    stop() {
      if (!this.started) return;
      this.started = false;
      this.document.removeEventListener('click', this.bound.click, true);
      this.document.removeEventListener('focusin', this.bound.focusin, true);
      this.document.removeEventListener('focusout', this.bound.focusout, true);
      this.document.removeEventListener('keydown', this.bound.keydown, true);
      this.document.removeEventListener('visibilitychange', this.bound.visibility, true);
      root.removeEventListener('pagehide', this.bound.pagehide, true);
      root.removeEventListener('focus', this.bound.focus, true);
      root.removeEventListener('scroll', this.bound.position, true);
      root.removeEventListener('resize', this.bound.position, false);
      if (this.removeDataListener) this.removeDataListener();
      this.removeDataListener = null;
      void this.clear('controller-stop');
    }

    eventPath(event) {
      try { return event.composedPath().filter(value => value && value.nodeType === 1); }
      catch (error) { return event && event.target ? [event.target] : []; }
    }

    editorFromEvent(event) {
      for (const element of this.eventPath(event)) if (Text.isEditor(element)) return element;
      const active = Text.deepActiveElement(this.document);
      return Text.isEditor(active) ? active : null;
    }

    editorBelongsTo(editor, boundary) {
      if (!editor || !boundary) return false;
      if (Text.composedContains(boundary, editor)) return true;
      const editorBoundary = Bilibili.boundaryFrom(editor);
      if (editorBoundary === boundary) return true;
      const boundaryParent = Text.composedParent(boundary);
      return !!boundaryParent && Text.composedContains(boundaryParent, editor) &&
        !editorBoundary;
    }

    classify(editor) {
      if (!Bilibili.isCommentEditor(editor, this.document)) return null;
      const label = Bilibili.editorContextLabel(editor);
      const labelAuthor = Bilibili.replyAuthor(label);
      const ownBoundary = Bilibili.boundaryFrom(editor);
      let boundary = ownBoundary;
      let target = ownBoundary ? Bilibili.resolveTarget(ownBoundary, this.document) : null;
      const pending = this.pendingReply;
      if (pending && pending.expiresAt >= Date.now()) {
        const newEditor = !pending.editorsBefore.has(editor);
        const authorMatches = !pending.target.authorName || !labelAuthor ||
          pending.target.authorName === labelAuthor;
        if (authorMatches && (this.editorBelongsTo(editor, pending.boundary) ||
            (newEditor && /^\s*回复(?:\s|@|$)/.test(label)))) {
          boundary = pending.boundary;
          target = pending.target;
          this.clearPendingReply();
        }
      } else if (pending) this.clearPendingReply();

      const replyLike = !!boundary || /^\s*回复(?:\s|@|$)/.test(label);
      if (replyLike) {
        if (!target || !Protocol.normalizeTarget(target)) return null;
        return {
          mode: 'reply',
          editor,
          boundary,
          target: Protocol.normalizeTarget(target),
          semanticKey: 'reply:' + target.id,
        };
      }
      return { mode: 'direct', editor, boundary: null, target: null, semanticKey: 'direct' };
    }

    async activateEditor(editor, force) {
      const info = this.classify(editor);
      if (!info) {
        await this.clear('unresolved-editor');
        return { ok: false, error: '无法安全识别当前评论目标' };
      }
      if (!force && this.active && this.active.semanticKey === info.semanticKey &&
          this.active.editor === info.editor && this.active.context) {
        this.scheduleOverlay();
        return { ok: true, contextId: this.active.context.contextId };
      }
      return this.publish(info);
    }

    async captureGeneric() {
      const info = {
        mode: 'direct',
        editor: null,
        boundary: null,
        target: null,
        semanticKey: 'manual:' + String(this.location.href || ''),
        manual: true,
      };
      return this.publish(info);
    }

    async publish(info) {
      this.stopRetry();
      const generation = ++this.generation;
      const previous = this.active;
      this.active = null;
      this.stopHeartbeat();
      this.renderOverlay();
      if (previous && previous.context) await this.revokeContext(previous.context);
      if (generation !== this.generation) return { ok: false, stale: true };

      const revision = ++this.revision;
      const platform = Bilibili.isVideoPage(this.location) ? 'bilibili' : 'web';
      const contextId = Protocol.makeContextId(this.sourceId, revision, platform);
      const next = Object.assign({}, info, {
        revision,
        contextId,
        context: null,
        accepted: false,
      });
      this.active = next;
      this.renderOverlay();

      let context;
      try {
        context = await Builder.build({
          document: this.document,
          location: this.location,
          sourceId: this.sourceId,
          revision,
          contextId,
          mode: info.mode,
          target: info.target,
        });
      } catch (error) { context = null; }
      if (generation !== this.generation || this.active !== next) return { ok: false, stale: true };
      if (!context) {
        this.active = null;
        this.renderOverlay();
        return { ok: false, error: '当前页面没有可用正文' };
      }
      next.context = context;
      const response = await this.enqueueTransport('put', context);
      if (generation !== this.generation || this.active !== next) {
        if (response && response.ok) await this.revokeContext(context);
        return { ok: false, stale: true };
      }
      if (!response || response.ok !== true) {
        if (response && response.status === 503) {
          this.scheduleFullPutRetry(next);
          this.renderOverlay();
          return { ok: false, retrying: true, status: 503, error: response.error };
        }
        this.active = null;
        this.renderOverlay();
        return { ok: false, error: response && response.error || 'RIMES 未接受网页上下文' };
      }
      next.accepted = true;
      this.startHeartbeat(next);
      this.renderOverlay();
      return { ok: true, contextId };
    }

    enqueueTransport(op, payload) {
      const message = {
        type: Protocol.MESSAGE_CONTEXT,
        op,
        payload,
      };
      const operation = this.transportQueue.catch(() => {}).then(async () => {
        try { return await this.sendMessage(message); }
        catch (error) { return { ok: false, error: String(error && error.message || error) }; }
      });
      this.transportQueue = operation.catch(() => {});
      return operation;
    }

    async revokeContext(context) {
      return this.enqueueTransport('delete', Protocol.makeRevocation(context));
    }

    startHeartbeat(active) {
      this.stopHeartbeat();
      this.heartbeatTimer = setInterval(async () => {
        if (this.active !== active || !active.context) return;
        const response = await this.enqueueTransport('heartbeat',
          Protocol.makeHeartbeat(active.context));
        if (this.active !== active) return;
        if (response && response.status === 503) {
          this.stopHeartbeat();
          this.scheduleFullPutRetry(active);
        } else if (!response || response.ok !== true) this.abandon('heartbeat-rejected');
      }, Protocol.HEARTBEAT_INTERVAL_MS);
    }

    stopHeartbeat() {
      if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }

    scheduleFullPutRetry(active) {
      this.stopRetry();
      this.retryTimer = setTimeout(() => {
        this.retryTimer = null;
        if (this.active !== active) return;
        const info = {
          mode: active.mode,
          editor: active.editor,
          boundary: active.boundary,
          target: active.target,
          semanticKey: active.semanticKey,
          manual: active.manual === true,
        };
        void this.publish(info);
      }, Protocol.HEARTBEAT_INTERVAL_MS);
    }

    stopRetry() {
      if (this.retryTimer) clearTimeout(this.retryTimer);
      this.retryTimer = null;
    }

    abandon() {
      ++this.generation;
      this.active = null;
      this.stopHeartbeat();
      this.stopRetry();
      this.renderOverlay();
    }

    async clear() {
      ++this.generation;
      const previous = this.active;
      this.active = null;
      this.stopHeartbeat();
      this.stopRetry();
      this.renderOverlay();
      if (previous && previous.context) await this.revokeContext(previous.context);
      return { ok: true };
    }

    beginReplyHandoff(boundary, target) {
      this.clearPendingReply();
      const editorsBefore = new WeakSet();
      for (const editor of Text.collectDeep(Bilibili.commentSearchRoot(this.document), 16000)
        .filter(Text.isEditor)) editorsBefore.add(editor);
      this.pendingReply = {
        boundary,
        target,
        editorsBefore,
        expiresAt: Date.now() + REPLY_HANDOFF_MS,
      };
      this.pendingTimer = setTimeout(() => this.clearPendingReply(), REPLY_HANDOFF_MS + 20);
    }

    clearPendingReply() {
      if (this.pendingTimer) clearTimeout(this.pendingTimer);
      this.pendingTimer = null;
      this.pendingReply = null;
    }

    tryPendingReply() {
      const pending = this.pendingReply;
      if (!pending || pending.expiresAt < Date.now()) {
        this.clearPendingReply();
        return;
      }
      const editor = Text.deepActiveElement(this.document);
      if (Text.isEditor(editor)) void this.activateEditor(editor, true);
    }

    handleClick(event) {
      const reply = Bilibili.replyControl(event);
      if (reply) {
        const boundary = Bilibili.boundaryFrom(reply.path);
        const target = boundary && Bilibili.resolveTarget(boundary, this.document);
        void this.clear('reply-handoff');
        if (!target || !Protocol.normalizeTarget(target)) {
          this.clearPendingReply();
          return;
        }
        this.beginReplyHandoff(boundary, Protocol.normalizeTarget(target));
        for (const delay of [0, 80, 200, 500, 1000]) {
          setTimeout(() => this.tryPendingReply(), delay);
        }
        return;
      }
      const editor = this.editorFromEvent(event);
      if (editor) setTimeout(() => { void this.activateEditor(editor, false); }, 0);
      else this.clearPendingReply();
    }

    handleFocusIn(event) {
      if (this.blurTimer) clearTimeout(this.blurTimer);
      this.blurTimer = null;
      const editor = this.editorFromEvent(event);
      if (editor) void this.activateEditor(editor, false);
    }

    handleFocusOut() {
      if (this.blurTimer) clearTimeout(this.blurTimer);
      this.blurTimer = setTimeout(() => {
        this.blurTimer = null;
        const editor = Text.deepActiveElement(this.document);
        if (Text.isEditor(editor) && Bilibili.isCommentEditor(editor, this.document)) {
          void this.activateEditor(editor, false);
        } else if (!this.pendingReply || this.pendingReply.expiresAt < Date.now()) {
          void this.clear('editor-blur');
        }
      }, 120);
    }

    handleKeyDown(event) {
      if (event && event.key === 'Escape') {
        this.clearPendingReply();
        void this.clear('escape');
      }
    }

    rearmFocusedEditor() {
      if (!Bilibili.isVideoPage(this.location)) return;
      const editor = Text.deepActiveElement(this.document);
      if (Text.isEditor(editor)) void this.activateEditor(editor, true);
    }

    contextDataChanged() {
      if (!this.active || !this.active.context || this.refreshTimer) return;
      this.refreshTimer = setTimeout(() => {
        this.refreshTimer = null;
        const active = this.active;
        if (!active) return;
        if (active.manual) void this.captureGeneric();
        else if (active.editor && active.editor.isConnected) void this.activateEditor(active.editor, true);
      }, 600);
    }

    async handleNavigation(nextURL) {
      const normalized = String(nextURL || this.location.href || '');
      if (normalized === this.pageURL) return;
      this.pageURL = normalized;
      await this.clear('navigation');
      this.clearPendingReply();
      this.sourceId = Protocol.randomIdentifier('page-');
      this.revision = 0;
      Bilibili.resetForNavigation();
      setTimeout(() => Bilibili.prefetchSubtitle(this.location), 0);
    }

    ensureOverlay() {
      if (this.overlay && this.overlay.box.isConnected) return this.overlay;
      const mount = this.document.documentElement || this.document.body;
      if (!mount) return null;
      const box = this.document.createElement('div');
      const badge = this.document.createElement('div');
      for (const element of [box, badge]) {
        element.setAttribute('data-marine-chrome-ui', 'true');
        Object.assign(element.style, {
          position: 'fixed',
          zIndex: '2147483647',
          pointerEvents: 'none',
          display: 'none',
          boxSizing: 'border-box',
        });
        mount.appendChild(element);
      }
      Object.assign(box.style, {
        border: '2px solid #00aeec',
        borderRadius: '8px',
        background: 'rgba(0,174,236,.045)',
        boxShadow: '0 0 0 3px rgba(0,174,236,.14)',
      });
      Object.assign(badge.style, {
        padding: '4px 8px',
        borderRadius: '6px',
        color: '#fff',
        background: '#008fc4',
        font: '600 12px/1.3 -apple-system,BlinkMacSystemFont,sans-serif',
        whiteSpace: 'nowrap',
      });
      this.overlay = { box, badge };
      return this.overlay;
    }

    scheduleOverlay() {
      if (this.positionFrame != null) return;
      this.positionFrame = requestAnimationFrame(() => {
        this.positionFrame = null;
        this.renderOverlay();
      });
    }

    renderOverlay() {
      const overlay = this.ensureOverlay();
      if (!overlay) return;
      const active = this.active;
      if (!active || !active.editor || !active.editor.isConnected || !Text.isVisible(active.editor)) {
        overlay.box.style.display = 'none';
        overlay.badge.style.display = 'none';
        return;
      }
      let rect;
      try { rect = active.editor.getBoundingClientRect(); } catch (error) { rect = null; }
      if (!rect || rect.width <= 0 || rect.height <= 0) {
        overlay.box.style.display = 'none';
        overlay.badge.style.display = 'none';
        return;
      }
      Object.assign(overlay.box.style, {
        display: 'block',
        left: Math.max(2, rect.left - 3) + 'px',
        top: Math.max(2, rect.top - 3) + 'px',
        width: Math.max(1, rect.width + 6) + 'px',
        height: Math.max(1, rect.height + 6) + 'px',
      });
      overlay.badge.textContent = active.mode === 'reply'
        ? 'marine-chrome · 回复 @' + (active.target && active.target.authorName || '作者')
        : 'marine-chrome · 直评';
      Object.assign(overlay.badge.style, {
        display: 'block',
        left: Math.max(4, rect.left) + 'px',
        top: Math.max(4, rect.top >= 30 ? rect.top - 28 : rect.bottom + 5) + 'px',
      });
    }

    status() {
      return {
        active: !!(this.active && this.active.context && this.active.accepted),
        mode: this.active && this.active.mode || null,
        targetSummary: this.active && this.active.context && this.active.context.targetSummary || null,
      };
    }
  }

  root.MarineChromeTargetController = Object.freeze({
    create(documentLike, locationLike, sendMessage) {
      return new Controller(documentLike, locationLike, sendMessage);
    },
    Controller,
  });
})(globalThis);
