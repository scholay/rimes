(function (root) {
  'use strict';

  if (root.MarineChromeExtract) return;
  const Protocol = root.MarineChromeProtocol;
  const Text = root.MarineChromeText;
  const SKIP = new Set([
    'SCRIPT', 'STYLE', 'NOSCRIPT', 'SVG', 'CANVAS', 'IFRAME', 'NAV', 'FOOTER',
    'ASIDE', 'FORM', 'BUTTON', 'INPUT', 'SELECT', 'TEXTAREA', 'TEMPLATE',
  ]);

  function selectedText(documentLike) {
    try {
      const selection = documentLike.defaultView && documentLike.defaultView.getSelection
        ? documentLike.defaultView.getSelection()
        : null;
      return Protocol.cleanText(selection && selection.toString(), Protocol.MAX_SOURCE_BYTES).trim();
    } catch (error) { return ''; }
  }

  function contentRoot(documentLike) {
    const selectors = [
      'article', 'main', '[role="main"]', '#content', '#main', '.post-content',
      '.article-content', '.markdown-body', '.post', '.article', '.content',
    ];
    let best = null;
    let bestLength = 0;
    for (const selector of selectors) {
      let candidates = [];
      try { candidates = Array.from(documentLike.querySelectorAll(selector)); } catch (error) {}
      for (const candidate of candidates) {
        const length = Text.textOf(candidate, Protocol.MAX_SOURCE_BYTES).length;
        if (length > bestLength) {
          best = candidate;
          bestLength = length;
        }
      }
    }
    return best && bestLength > 200 ? best : documentLike.body;
  }

  function hidden(element) {
    try {
      return element.hidden || element.getAttribute('aria-hidden') === 'true';
    } catch (error) { return false; }
  }

  function inline(node) {
    let output = '';
    for (const child of Array.from(node && node.childNodes || [])) {
      if (child.nodeType === 3) {
        output += String(child.nodeValue || '').replace(/\s+/g, ' ');
        continue;
      }
      if (child.nodeType !== 1 || SKIP.has(child.tagName) || hidden(child)) continue;
      const tag = child.tagName;
      if (tag === 'BR') output += '\n';
      else if (tag === 'STRONG' || tag === 'B') {
        const value = inline(child).trim();
        if (value) output += '**' + value + '**';
      } else if (tag === 'EM' || tag === 'I') {
        const value = inline(child).trim();
        if (value) output += '*' + value + '*';
      } else if (tag === 'CODE') {
        const value = Text.textOf(child, 8 * 1024);
        if (value) output += '`' + value.replace(/`/g, '\\`') + '`';
      } else if (tag === 'A') {
        const label = inline(child).trim();
        const href = Text.attribute(child, ['href']);
        output += label && /^https?:/i.test(href) ? '[' + label + '](' + href + ')' : label;
      } else output += inline(child);
    }
    return output;
  }

  function domToMarkdown(container) {
    const blocks = [];
    function walk(node, depth) {
      if (blocks.join('\n').length > Protocol.MAX_SOURCE_BYTES) return;
      for (const child of Array.from(node && node.children || [])) {
        const tag = String(child.tagName || '').toUpperCase();
        if (!tag || SKIP.has(tag) || hidden(child)) continue;
        if (/^H[1-6]$/.test(tag)) {
          const value = inline(child).trim();
          if (value) blocks.push('#'.repeat(Number(tag.slice(1))) + ' ' + value);
        } else if (tag === 'P') {
          const value = inline(child).trim();
          if (value) blocks.push(value);
        } else if (tag === 'LI') {
          const value = inline(child).trim().replace(/\n+/g, ' ');
          if (value) blocks.push('  '.repeat(Math.min(depth, 4)) + '- ' + value);
        } else if (tag === 'BLOCKQUOTE') {
          const value = inline(child).trim();
          if (value) blocks.push(value.split('\n').map(line => '> ' + line).join('\n'));
        } else if (tag === 'PRE') {
          const value = Protocol.cleanText(child.textContent, 32 * 1024).trim();
          if (value) blocks.push('```\n' + value + '\n```');
        } else walk(child, tag === 'UL' || tag === 'OL' ? depth + 1 : depth);
      }
    }
    walk(container, 0);
    return Protocol.cleanText(blocks.join('\n\n').replace(/\n{3,}/g, '\n\n'),
      Protocol.MAX_SOURCE_BYTES).trim();
  }

  function article(documentLike, locationLike) {
    const rootElement = contentRoot(documentLike);
    let body = rootElement ? domToMarkdown(rootElement) : '';
    if (!body && rootElement) body = Text.textOf(rootElement, Protocol.MAX_SOURCE_BYTES);
    const heading = (() => {
      try { return Text.textOf(documentLike.querySelector('h1'), 2 * 1024); }
      catch (error) { return ''; }
    })();
    const title = heading || Text.normalize(documentLike.title, 2 * 1024);
    const sourceURL = String(locationLike && locationLike.href || '');
    const parts = [];
    if (title) parts.push('# ' + title);
    if (sourceURL) parts.push('> 来源：' + sourceURL);
    if (body) parts.push(body);
    return Protocol.cleanText(parts.join('\n\n'), Protocol.MAX_SOURCE_BYTES).trim();
  }

  root.MarineChromeExtract = Object.freeze({
    selectedText,
    contentRoot,
    domToMarkdown,
    article,
  });
})(globalThis);
