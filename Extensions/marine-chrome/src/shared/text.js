(function (root) {
  'use strict';

  if (root.MarineChromeText) return;
  const Protocol = root.MarineChromeProtocol;

  function normalize(value, maximumBytes) {
    return Protocol.normalizeInline(value, maximumBytes || 16 * 1024);
  }

  function composedParent(element) {
    if (!element) return null;
    const parent = element.parentElement || element.parentNode;
    if (parent && parent.nodeType === 11 && parent.host) return parent.host;
    return parent && parent.nodeType === 1 ? parent : null;
  }

  function shadowRootOf(element) {
    try {
      if (!element) return null;
      if (element.shadowRoot) return element.shadowRoot;
      if (typeof chrome !== 'undefined' && chrome.dom && chrome.dom.openOrClosedShadowRoot) {
        return chrome.dom.openOrClosedShadowRoot(element);
      }
    } catch (error) {}
    return null;
  }

  function collectDeep(searchRoot, maximum) {
    const output = [];
    const seen = new Set();
    const budget = Math.max(1, Number(maximum) || 12000);
    function visit(node) {
      if (!node || output.length >= budget || seen.has(node)) return;
      seen.add(node);
      if (node.nodeType === 1) {
        output.push(node);
        const shadow = shadowRootOf(node);
        if (shadow) visit(shadow);
      }
      let children = [];
      try { children = Array.from(node.children || []); } catch (error) {}
      for (const child of children) visit(child);
    }
    visit(searchRoot);
    return output;
  }

  function isVisible(element) {
    if (!element || !element.isConnected) return false;
    try {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
        style.visibility !== 'hidden' && style.visibility !== 'collapse';
    } catch (error) { return false; }
  }

  function isEditor(element) {
    if (!element || !isVisible(element)) return false;
    const tag = String(element.tagName || '').toLowerCase();
    if (tag === 'textarea') return !element.disabled && !element.readOnly;
    if (tag === 'input') {
      return /^(?:text|search)?$/.test(String(element.type || 'text')) &&
        !element.disabled && !element.readOnly;
    }
    const editable = String(element.getAttribute && element.getAttribute('contenteditable') || '');
    return element.isContentEditable || editable === 'true' || editable === 'plaintext-only';
  }

  function deepActiveElement(documentLike) {
    let active = documentLike && documentLike.activeElement;
    let shadow = shadowRootOf(active);
    while (shadow && shadow.activeElement) {
      active = shadow.activeElement;
      shadow = shadowRootOf(active);
    }
    return active;
  }

  function textOf(element, maximumBytes) {
    if (!element) return '';
    try {
      return normalize(element.innerText || element.textContent || '', maximumBytes || 16 * 1024);
    } catch (error) { return ''; }
  }

  function attribute(element, names) {
    for (const name of names || []) {
      try {
        const value = element && element.getAttribute && element.getAttribute(name);
        if (value != null && String(value).trim()) return String(value).trim();
      } catch (error) {}
    }
    return '';
  }

  function editorLabel(editor) {
    const values = [];
    for (let current = editor, depth = 0; current && depth < 5;
      current = composedParent(current), depth += 1) {
      const value = attribute(current, ['placeholder', 'aria-label', 'data-placeholder']);
      if (value) values.push(value);
    }
    return normalize(values.join(' '), 512);
  }

  function composedContains(container, element) {
    for (let current = element, depth = 0; current && depth < 40;
      current = composedParent(current), depth += 1) {
      if (current === container) return true;
    }
    return false;
  }

  root.MarineChromeText = Object.freeze({
    normalize,
    composedParent,
    shadowRootOf,
    collectDeep,
    isVisible,
    isEditor,
    deepActiveElement,
    textOf,
    attribute,
    editorLabel,
    composedContains,
  });
})(globalThis);
