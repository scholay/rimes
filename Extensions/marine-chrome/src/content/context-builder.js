(function (root) {
  'use strict';

  if (root.MarineChromeContextBuilder) return;
  const Protocol = root.MarineChromeProtocol;
  const Extract = root.MarineChromeExtract;
  const Bilibili = root.MarineChromeBilibili;

  function platformFor(locationLike) {
    return Bilibili.isVideoPage(locationLike) ? 'bilibili' : 'web';
  }

  function targetSummary(mode, target, documentLike) {
    if (mode === 'reply' && target) {
      const snippet = Protocol.normalizeInline(target.text, 220).slice(0, 80);
      return '@' + target.authorName + (snippet ? '：「' + snippet + '」' : '');
    }
    return '当前网页 · ' + Protocol.normalizeInline(documentLike.title || '未命名页面', 600);
  }

  function chooseGenericSource(documentLike, locationLike) {
    const selection = Extract.selectedText(documentLike);
    if (selection) return { kind: 'selection', text: selection };
    return { kind: 'article', text: Extract.article(documentLike, locationLike) };
  }

  async function chooseSource(documentLike, locationLike, platform) {
    const selection = Extract.selectedText(documentLike);
    if (selection) return { kind: 'selection', text: selection };
    return platform === 'bilibili'
      ? Bilibili.bestSource(documentLike, locationLike)
      : { kind: 'article', text: Extract.article(documentLike, locationLike) };
  }

  async function build(input) {
    const documentLike = input.document;
    const locationLike = input.location;
    const platform = platformFor(locationLike);
    const source = await chooseSource(documentLike, locationLike, platform);
    return Protocol.makeContext({
      sourceId: input.sourceId,
      revision: input.revision,
      contextId: input.contextId,
      capturedAt: Protocol.nowSeconds(),
      page: {
        platform,
        url: String(locationLike.href || ''),
        title: String(documentLike.title || ''),
      },
      mode: input.mode,
      targetSummary: targetSummary(input.mode, input.target, documentLike),
      target: input.target || null,
      source,
    });
  }

  root.MarineChromeContextBuilder = Object.freeze({
    platformFor,
    targetSummary,
    chooseGenericSource,
    chooseSource,
    build,
  });
})(globalThis);
