(() => {
  if (globalThis.zeusTranslate) return;
  const documentID = typeof crypto.randomUUID === 'function' ? crypto.randomUUID() : Array.from(crypto.getRandomValues(new Uint32Array(4)), v => v.toString(16)).join('-');
  const nodes = new Map(), ids = new WeakMap(), styles = new Map();
  let serial = 0, active = false, timer, applying = false, target = 'ar', rootState = null, streamToken = null;
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
  function collect(maxCharacters = 10000, maxSegments = 64, prioritize = false, wholePage = false) {
    const result = []; let length = 0;
    const viewport = globalThis.visualViewport;
    const top = viewport?.offsetTop || 0, left = viewport?.offsetLeft || 0;
    const height = viewport?.height || innerHeight, width = viewport?.width || innerWidth;
    const candidates = []; let overflow = false;
    for (const node of textNodes(document.body || document.documentElement)) {
      if (!eligible(node)) continue;
      if (wholePage && candidates.length >= maxSegments) { overflow = true; break; }
      let id = ids.get(node), entry = id && nodes.get(id);
      if (entry && node.nodeValue === entry.translated && entry.complete !== false) continue;
      if (entry && node.nodeValue !== entry.original && node.nodeValue !== entry.translated) { nodes.delete(id); entry = null; }
      const original = entry ? entry.original : node.nodeValue;
      // Keep individual nodes intact in the DOM, but transport their sentence-sized chunks.
      if (!entry) { id = String(++serial); ids.set(node,id); entry = {node,original,translated:null}; nodes.set(id,entry); }
      if (!wholePage && original.length > 100000) continue;
      let tier = 0, distance = 0;
      if (prioritize) {
        const range = document.createRange(); range.selectNodeContents(node);
        const rects = Array.from(range.getClientRects());
        const visible = rects.some(r => r.bottom > top && r.top < top + height && r.right > left && r.left < left + width);
        const rect = range.getBoundingClientRect();
        distance = Math.max(top - rect.bottom, rect.top - top - height, 0);
        tier = visible ? 0 : distance < height * 2 ? 1 : 2;
      }
      candidates.push({id,text:original,tier,distance});
    }
    const tier = candidates.reduce((best,c) => Math.min(best,c.tier), 3);
    if (prioritize) candidates.sort((a,b) => a.tier - b.tier || a.distance - b.distance);
    const characters = prioritize && tier === 0 ? Math.max(maxCharacters,24000) : maxCharacters;
    const count = prioritize && tier === 0 ? Math.max(maxSegments,256) : maxSegments;
    let more = overflow;
    for (const entry of candidates) {
      if (prioritize && entry.tier !== tier) break;
      if ((result.length && length + entry.text.length > characters) || result.length >= count) { more = true; break; }
      if (wholePage && length + entry.text.length > characters) { more = true; break; }
      result.push({id:entry.id,text:entry.text}); length += entry.text.length;
    }
    return {documentID, segments:result, tier, more};
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
      if (!entry?.node.isConnected || typeof item.text !== 'string' ||
          (entry.node.nodeValue !== entry.original && !(entry.complete === false && entry.node.nodeValue === entry.translated))) continue;
      const whitespace = entry.original.match(/^(\s*)[\s\S]*?(\s*)$/);
      entry.translated = whitespace[1] + item.text.trim() + whitespace[2];
      entry.complete = true;
      entry.node.nodeValue = entry.translated; directional(entry.node.parentElement); count++;
    }
    if (count) document.documentElement.setAttribute('lang',target);
    observer.takeRecords(); applying = false; return count;
  }
  function stream(items, expected, token) {
    if (!active || expected !== documentID || token !== streamToken) return {applied:0,ids:[]};
    applying = true; const appliedIDs = [];
    for (const item of items) {
      const entry = nodes.get(item.id);
      if (!entry?.node.isConnected || typeof item.text !== 'string' ||
          (entry.node.nodeValue !== entry.original && entry.node.nodeValue !== entry.translated)) continue;
      const whitespace = entry.original.match(/^(\s*)[\s\S]*?(\s*)$/);
      entry.translated = whitespace[1] + item.text.trim() + whitespace[2];
      entry.complete = item.final === true;
      entry.node.nodeValue = entry.translated; directional(entry.node.parentElement); appliedIDs.push(item.id);
    }
    if (appliedIDs.length) document.documentElement.setAttribute('lang',target);
    observer.takeRecords(); applying = false; return {applied:appliedIDs.length,ids:appliedIDs};
  }
  function start(language, token = null) {
    active = true; target = language; streamToken = token;
    if (!rootState) rootState = {lang:document.documentElement.getAttribute('lang')};
  }
  function restore() {
    active = false; streamToken = null; clearTimeout(timer); applying = true;
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
  globalThis.zeusTranslate = {collect,apply,stream,start,restore,documentID};
  // WebKit may restore a translated DOM from its back/forward page cache without
  // reinjecting user scripts. Start that navigation from the original language.
  let scrollTimer;
  window.addEventListener('scroll', () => { if (!active) return; clearTimeout(scrollTimer); scrollTimer = setTimeout(() => notify('viewport'), 120); }, {passive:true});
  window.addEventListener('pageshow', event => { if (event.persisted) restore(); notify('ready'); });
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded',detect,{once:true}); else detect();
})();
