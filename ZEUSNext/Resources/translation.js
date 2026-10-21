(() => {
  if (globalThis.zeusTranslate) return;
  const documentID = typeof crypto.randomUUID === 'function' ? crypto.randomUUID() : Array.from(crypto.getRandomValues(new Uint32Array(4)), v => v.toString(16)).join('-');
  const nodes = new Map(), ids = new WeakMap(), styles = new Map();
  let serial = 0, active = false, timer, applying = false, target = 'ar', rootState = null;
  const skip = 'script,style,noscript,pre,code,kbd,samp,svg,math,textarea,input,select,option,[contenteditable]:not([contenteditable="false"]),[translate="no"],.notranslate,[aria-hidden="true"],[hidden]';
  function eligible(node) {
    const parent = node.parentElement;
    if (!parent || parent.closest(skip) || !node.nodeValue.trim() || /^(https?:\/\/|www\.)\S+$/i.test(node.nodeValue.trim()) || !/\p{L}/u.test(node.nodeValue)) return false;
    const style = getComputedStyle(parent);
    return style.display !== 'none' && style.visibility !== 'hidden' && parent.getClientRects().length > 0;
  }
  const observedRoots = new WeakSet();
  function* textNodes(root) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    let node;
    while (node = walker.nextNode()) {
      if (node.nodeType === Node.TEXT_NODE) yield node;
      else if (node.shadowRoot) {
        if (!observedRoots.has(node.shadowRoot)) { observer.observe(node.shadowRoot,{childList:true,subtree:true,characterData:true}); observedRoots.add(node.shadowRoot); }
        yield* textNodes(node.shadowRoot);
      }
    }
  }
  function notify(kind) {
    let sample = '';
    for (const node of textNodes(document.body || document.documentElement)) { if (eligible(node)) sample += node.nodeValue + ' '; if (sample.length >= 3500) break; }
    try { webkit.messageHandlers.zeusTranslation.postMessage({kind, documentID, lang: document.documentElement.lang || '', sample: sample.slice(0,3500)}); } catch (_) {}
  }
  function detect() { notify('ready'); }
  function collect() {
    const result = []; let length = 0;
    for (const node of textNodes(document.body || document.documentElement)) {
      if (!eligible(node)) continue;
      let id = ids.get(node), entry = id && nodes.get(id);
      if (entry && node.nodeValue === entry.translated) continue;
      if (entry && node.nodeValue !== entry.original) { nodes.delete(id); entry = null; }
      const original = node.nodeValue;
      // Keep individual nodes intact in the DOM, but transport their sentence-sized chunks.
      if (!entry) { id = String(++serial); ids.set(node,id); entry = {node,original,translated:null}; nodes.set(id,entry); }
      if (result.length && (length + original.length > 5500 || result.length >= 32)) break;
      if (original.length > 100000) continue; // One hostile/huge node must not exhaust memory.
      result.push({id,text:original}); length += original.length;
    }
    return {documentID, segments:result};
  }
  function directional(element) {
    if (!element || element.closest(skip)) return;
    // Only text containers get direction; tables, navigation and flex/grid geometry are preserved.
    const block = element.closest('p,h1,h2,h3,h4,h5,h6,li,blockquote,figcaption,td,th,dd,dt,article,section,div') || element;
    if (!styles.has(block)) styles.set(block, {dir:block.getAttribute('dir'), align:block.style.getPropertyValue('text-align'), ap:block.style.getPropertyPriority('text-align'), direction:block.style.getPropertyValue('direction'), dp:block.style.getPropertyPriority('direction')});
    const rtl = /^(ar|fa|he|ur|ps|yi)(-|$)/.test(target);
    block.setAttribute('dir',rtl?'rtl':'ltr'); block.style.setProperty('direction',rtl?'rtl':'ltr','important');
    block.style.setProperty('text-align',rtl?'right':'left','important');
  }
  function apply(items, expected) {
    if (expected !== documentID) return 0;
    applying = true; let count = 0;
    for (const item of items) {
      const entry = nodes.get(item.id);
      if (!entry?.node.isConnected || entry.node.nodeValue !== entry.original || typeof item.text !== 'string') continue;
      const whitespace = entry.original.match(/^(\s*)[\s\S]*?(\s*)$/);
      entry.translated = whitespace[1] + item.text.trim() + whitespace[2];
      entry.node.nodeValue = entry.translated; directional(entry.node.parentElement); count++;
    }
    observer.takeRecords(); applying = false; return count;
  }
  function start(language) {
    active = true; target = language;
    if (!rootState) rootState = {lang:document.documentElement.getAttribute('lang')};
    document.documentElement.setAttribute('lang',language);
  }
  function restore() {
    active = false; clearTimeout(timer); applying = true;
    for (const entry of nodes.values()) { if (entry.node.isConnected && entry.node.nodeValue === entry.translated) entry.node.nodeValue = entry.original; }
    for (const [element,old] of styles) {
      if (old.dir === null) element.removeAttribute('dir'); else element.setAttribute('dir',old.dir);
      if (old.align) element.style.setProperty('text-align',old.align,old.ap); else element.style.removeProperty('text-align');
      if (old.direction) element.style.setProperty('direction',old.direction,old.dp); else element.style.removeProperty('direction');
    }
    if (rootState) { if (rootState.lang === null) document.documentElement.removeAttribute('lang'); else document.documentElement.setAttribute('lang',rootState.lang); }
    rootState = null; styles.clear(); nodes.clear(); observer.takeRecords(); applying = false;
  }
  const observer = new MutationObserver(records => {
    if (applying || !records.some(r => r.type === 'childList' || r.type === 'characterData')) return;
    clearTimeout(timer); timer = setTimeout(() => notify(active?'changed':'ready'), 800);
    // Prune detached DOM nodes on long running SPAs.
    for (const [id,entry] of nodes) if (!entry.node.isConnected) nodes.delete(id);
    for (const el of styles.keys()) if (!el.isConnected) styles.delete(el);
  });
  observer.observe(document.documentElement,{childList:true,subtree:true,characterData:true});
  globalThis.zeusTranslate = {collect,apply,start,restore,documentID};
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded',detect,{once:true}); else detect();
})();
