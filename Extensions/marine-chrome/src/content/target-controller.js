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
      this.contextDataDirty = false;
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
        Bilibili.prefetchSubtitle(this.location);
      }
      this.document.addEventListener('keydown', this.bound.keydown, true);
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
          this.active.editor === info.editor) {
        if (this.active.accepted && this.active.context && !this.contextDataDirty) {
          this.scheduleOverlay();
          return { ok: true, contextId: this.active.context.contextId };
        }
        if (this.active.retrying) {
          this.scheduleFullPutRetry(this.active, 0);
          return {
            ok: false,
            retrying: true,
            retryReason: this.active.retryReason,
            error: this.active.retryDetail,
          };
        }
      }
      return this.publish(info);
    }

    async captureGeneric(intentURL) {
      // Opening the action popup fires focusout on a Bilibili editor before
      // the popup's explicit manual capture message arrives. Cancel that
      // delayed editor reclassification so it cannot overwrite the newer
      // manual intent after capture has already started.
      if (this.blurTimer) clearTimeout(this.blurTimer);
      this.blurTimer = null;
      this.clearPendingReply();
      const currentURL = String(this.location.href || '');
      const expectedURL = typeof intentURL === 'string' && intentURL
        ? intentURL : currentURL;
      if (currentURL !== expectedURL) {
        await this.clear('manual-url-changed');
        return { ok: false, stale: true, error: '网页已变化，请重新读取' };
      }
      const info = {
        mode: 'direct',
        editor: null,
        boundary: null,
        target: null,
        semanticKey: 'manual:' + expectedURL,
        manual: true,
        intentURL: expectedURL,
      };
      return this.publish(info);
    }

    async publish(info) {
      this.stopRetry();
      this.stopRefresh();
      // Every publish performs a fresh extraction, so it consumes all data
      // changes observed before this generation began. A later change will set
      // the flag again and schedule another refresh.
      this.contextDataDirty = false;
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
        retrying: false,
        retryDetail: '',
        retryReason: '',
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
      if (info.manual === true &&
          (String(this.location.href || '') !== info.intentURL ||
           (context && String(context.page && context.page.url || '') !== info.intentURL))) {
        await this.clear('manual-url-changed');
        return { ok: false, stale: true, error: '网页已变化，请重新读取' };
      }
      if (!context) {
        this.suspendForRetry(
          next,
          '当前页面暂时没有可用正文',
          'content-not-ready',
        );
        this.renderOverlay();
        return {
          ok: false,
          retrying: true,
          retryReason: next.retryReason,
          error: next.retryDetail,
        };
      }
      next.context = context;
      const response = await this.enqueueTransport('put', context);
      if (generation !== this.generation || this.active !== next) {
        if (response && response.ok) await this.revokeContext(context);
        return { ok: false, stale: true };
      }
      if (!response || response.ok !== true) {
        if (response && (response.retryable === true || response.status === 503)) {
          this.suspendForRetry(
            next,
            response.error || 'RIMES 暂时未接受网页上下文',
            response.retryReason || 'rimes-unavailable',
          );
          this.renderOverlay();
          return {
            ok: false,
            retrying: true,
            status: response.status,
            retryReason: next.retryReason,
            error: next.retryDetail,
          };
        }
        this.active = null;
        this.renderOverlay();
        return { ok: false, error: response && response.error || 'RIMES 未接受网页上下文' };
      }
      next.accepted = true;
      next.retrying = false;
      next.retryDetail = '';
      next.retryReason = '';
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
      // setInterval may fire again while the proof + heartbeat round trip is
      // still pending. Keep the guard local to this interval generation so an
      // old completion cannot unlock a newer heartbeat loop.
      let inFlight = false;
      this.heartbeatTimer = setInterval(async () => {
        if (inFlight || this.active !== active || !active.context) return;
        inFlight = true;
        try {
          const response = await this.enqueueTransport('heartbeat',
            Protocol.makeHeartbeat(active.context));
          if (this.active !== active) return;
          if (response && (response.retryable === true || response.status === 503)) {
            this.suspendForRetry(
              active,
              response.error || '网页上下文租约暂时中断',
              response.retryReason || 'rimes-unavailable',
            );
            this.renderOverlay();
          } else if (!response || response.ok !== true) this.abandon('heartbeat-rejected');
        } finally { inFlight = false; }
      }, Protocol.HEARTBEAT_INTERVAL_MS);
    }

    stopHeartbeat() {
      if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }

    suspendForRetry(active, detail, reason) {
      if (this.active !== active) return;
      active.context = null;
      active.accepted = false;
      active.retrying = true;
      active.retryDetail = String(detail || '正在等待网页可读取');
      active.retryReason = String(reason || 'retry');
      this.stopHeartbeat();
      this.scheduleFullPutRetry(active);
    }

    scheduleFullPutRetry(active, delayMilliseconds) {
      this.stopRetry();
      const delay = Number.isFinite(delayMilliseconds)
        ? Math.max(0, delayMilliseconds)
        : Protocol.HEARTBEAT_INTERVAL_MS;
      this.retryTimer = setTimeout(() => {
        this.retryTimer = null;
        void this.retrySuspendedIntent(active);
      }, delay);
    }

    async retrySuspendedIntent(active) {
      if (this.active !== active || active.retrying !== true) return;
      if (this.document.hidden) {
        this.scheduleFullPutRetry(active);
        return;
      }
      if (active.manual === true) {
        if (String(this.location.href || '') !== active.intentURL) {
          await this.clear('manual-url-changed');
          return;
        }
      } else if (!this.retryIntentIsCurrent(active)) {
        await this.clear('retry-target-lost');
        return;
      }

      // An action popup takes DOM focus away from the page even though the
      // same Chrome window and tab remain authoritative. Ask the worker for a
      // read-only foreground verdict instead of treating document.hasFocus()
      // as authority. The subsequent PUT still repeats the full pre/post
      // foreground checks, so this probe can never grant a lease by itself.
      if (!this.pageCanRetry()) {
        // Like Marine's GRAB_ALL path, manual page capture and a non-targeted
        // direct editor are bound to the selected host tab rather than to
        // document.hasFocus(). Exact replies remain strict: relaxing them
        // could revive a stale comment target after popup focusout.
        const mayProbeSelectedPage = active.manual === true ||
          (active.mode === 'direct' && !active.target);
        if (!mayProbeSelectedPage) {
          this.scheduleFullPutRetry(active);
          return;
        }
        const probeURL = active.manual === true
          ? active.intentURL
          : String(this.location.href || '');
        const payload = Protocol.makeForegroundProbe(probeURL);
        if (!payload) {
          await this.clear('retry-url-invalid');
          return;
        }
        let response;
        try {
          response = await this.sendMessage({
            type: Protocol.MESSAGE_FOREGROUND,
            payload,
          });
        } catch (error) {
          response = { ok: false, error: String(error && error.message || error) };
        }
        if (this.active !== active || active.retrying !== true) return;
        if (!response || response.ok !== true) {
          const status = response && response.status;
          const terminal = status === 400 || status === 403;
          if (terminal) {
            this.abandon('foreground-probe-rejected');
            return;
          }
          active.retryDetail = response && response.error || '前台状态暂时不可用';
          active.retryReason = response && response.retryReason || 'foreground-unavailable';
          this.renderOverlay();
          this.scheduleFullPutRetry(active);
          return;
        }
        if (response.foreground !== true) {
          active.retryDetail = '网页已不在前台';
          active.retryReason = 'page-not-foreground';
          this.renderOverlay();
          this.scheduleFullPutRetry(active);
          return;
        }
      }

      if (this.active !== active || active.retrying !== true) return;
      if (active.manual === true) {
        void this.captureGeneric(active.intentURL);
      } else if (this.retryIntentIsCurrent(active)) {
        // Re-classify the live editor instead of replaying a stale reply ID.
        void this.activateEditor(active.editor, true);
      } else void this.clear('retry-target-lost');
    }

    retryIntentIsCurrent(active) {
      if (!active || !active.editor || !active.editor.isConnected ||
          !Text.isVisible(active.editor)) return false;
      return Text.deepActiveElement(this.document) === active.editor;
    }

    pageCanRetry() {
      if (this.document.hidden) return false;
      if (typeof this.document.hasFocus !== 'function') return true;
      try { return this.document.hasFocus() === true; }
      catch (error) { return false; }
    }

    stopRetry() {
      if (this.retryTimer) clearTimeout(this.retryTimer);
      this.retryTimer = null;
    }

    stopRefresh() {
      if (this.refreshTimer) clearTimeout(this.refreshTimer);
      this.refreshTimer = null;
    }

    abandon() {
      ++this.generation;
      this.active = null;
      this.contextDataDirty = false;
      this.stopHeartbeat();
      this.stopRetry();
      this.stopRefresh();
      this.renderOverlay();
    }

    async clear() {
      ++this.generation;
      const previous = this.active;
      this.active = null;
      this.contextDataDirty = false;
      this.stopHeartbeat();
      this.stopRetry();
      this.stopRefresh();
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
      const active = this.active;
      if (active && active.retrying) {
        const targetStillValid = active.manual === true || this.retryIntentIsCurrent(active);
        if (targetStillValid) this.scheduleFullPutRetry(active, 0);
        return;
      }
      if (active && this.contextDataDirty && this.pageCanRetry()) {
        if (active.manual) {
          void this.captureGeneric(active.intentURL);
          return;
        }
        if (active.editor && this.retryIntentIsCurrent(active)) {
          void this.activateEditor(active.editor, true);
          return;
        }
      }
      if (!Bilibili.isVideoPage(this.location)) return;
      const editor = Text.deepActiveElement(this.document);
      if (Text.isEditor(editor)) void this.activateEditor(editor, true);
    }

    contextDataChanged() {
      if (!this.active) return;
      this.contextDataDirty = true;
      if (this.refreshTimer) return;
      this.refreshTimer = setTimeout(() => {
        this.refreshTimer = null;
        const active = this.active;
        if (!active || !this.contextDataDirty) return;
        if (!this.pageCanRetry()) {
          if (active.retrying) this.scheduleFullPutRetry(active);
          return;
        }
        if (active.manual) void this.captureGeneric(active.intentURL);
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
      const active = this.active;
      return {
        active: !!(active && active.context && active.accepted),
        retrying: !!(active && active.retrying),
        retryDetail: active && active.retryDetail || '',
        retryReason: active && active.retryReason || '',
        mode: active && active.mode || null,
        targetSummary: active && active.context && active.context.targetSummary || null,
        sourceId: active && active.sourceId || this.sourceId,
        revision: active && active.revision || 0,
        contextId: active && active.contextId || null,
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
