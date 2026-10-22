(() => {
  'use strict';
  if (window.__zeusDarkPage) return;
  window.__zeusDarkPage = true;
  // Direct style properties also cover documents whose CSP rejects style tags.
  document.documentElement.style.setProperty('background-color', '#101114', 'important');
  document.documentElement.style.setProperty('color', '#e5e7eb', 'important');
  document.documentElement.style.setProperty('color-scheme', 'dark', 'important');
  const css = `
    :root, html, body { color-scheme: dark !important; background-color:#101114 !important; color:#e5e7eb !important; }
    *:not(img):not(video):not(canvas):not(svg):not(svg *):not(picture):not(source) {
      background-color:#101114 !important; color:#e5e7eb !important;
      border-color:#42464e !important; text-shadow:none !important; box-shadow:none !important;
      -webkit-text-fill-color:currentColor !important;
    }
    a, a * { color:#9dc7ff !important; }
    input, textarea, select, button, [role="button"] { background-color:#24272e !important; color:#f1f3f5 !important; color-scheme:dark !important; }
    ::placeholder { color:#a6abb5 !important; opacity:1 !important; }
    *::before, *::after { background-color:#101114 !important; color:inherit !important; border-color:#42464e !important; text-shadow:none !important; }
    ::selection { background:#3c577a !important; color:white !important; }
  `;
  const roots = new WeakSet();
  function inspect(element) {
    if (!(element instanceof Element)) return;
    // CSS image gradients can otherwise cover the forced dark background.
    // Preserve photographs, SVG, canvas and video; never invert the page.
    if (!['IMG','VIDEO','CANVAS','SVG','PICTURE','SOURCE','STYLE','SCRIPT','LINK'].includes(element.tagName) && !element.closest('svg')) {
      const computed = getComputedStyle(element);
      const luminance = value => { const numbers = value.match(/[\d.]+/g)?.map(Number); return numbers && numbers.length >= 3 ? (numbers[0]*0.2126 + numbers[1]*0.7152 + numbers[2]*0.0722)/255 : 0; };
      // Inline !important and highly specific site rules can beat the stylesheet.
      if (luminance(computed.backgroundColor) > 0.18) element.style.setProperty('background-color', '#101114', 'important');
      if (luminance(computed.color) < 0.55) element.style.setProperty('color', '#e5e7eb', 'important');
      if (computed.backgroundImage.includes('gradient(') && !computed.backgroundImage.includes('url(')) element.style.setProperty('background-image', 'none', 'important');
    }
    if (element.shadowRoot) install(element.shadowRoot);
  }
  const queue = new Map(); let pending = false;
  function schedule(node, descendants = true) {
    if (node.nodeType !== 1) return;
    queue.set(node, descendants || queue.get(node) === true);
    if (pending) return;
    pending = true;
    requestAnimationFrame(() => {
      pending = false;
      for (const [node, descendants] of queue) { inspect(node); if (descendants) for (const child of node.querySelectorAll('*')) inspect(child); }
      queue.clear();
    });
  }
  function install(root) {
    if (roots.has(root)) return;
    roots.add(root);
    const style = document.createElement('style'); style.dataset.zeusDark = 'true'; style.textContent = css;
    (root === document ? document.documentElement : root).appendChild(style);
    const observer = new MutationObserver(records => {
      if (!style.parentNode) (root === document ? document.documentElement : root).appendChild(style);
      for (const record of records) {
        if (record.type === 'attributes') schedule(record.target, false);
        else for (const node of record.addedNodes) schedule(node);
      }
    });
    observer.observe(root, { childList:true, subtree:true, attributes:true, attributeFilter:['style', 'class'] });
    for (const element of root.querySelectorAll('*')) inspect(element);
  }
  install(document);
  const original = Element.prototype.attachShadow;
  Element.prototype.attachShadow = function(options) { const root = original.call(this, options); install(root); return root; };
})();
