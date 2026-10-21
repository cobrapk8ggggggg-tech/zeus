(() => {
  'use strict';
  if (window.__zeusDarkPage) return;
  window.__zeusDarkPage = true;
  const excluded = new Set(['IMG','VIDEO','CANVAS','SVG','PICTURE','SOURCE','STYLE','SCRIPT','LINK','IFRAME']);
  const roots = new WeakSet(), signatures = new WeakMap();
  const clamp = value => Math.max(0, Math.min(1, value));
  const color = value => {
    if (!value || value === 'transparent') return null;
    const match = value.match(/rgba?\(([^)]+)\)/i); if (!match) return null;
    const n = match[1].split(/[, ]+/).filter(Boolean).map(Number);
    if (n.length < 3 || (n.length > 3 && n[3] === 0)) return null;
    return {r:n[0], g:n[1], b:n[2], a:n[3] ?? 1};
  };
  const luminance = rgb => {
    if (!rgb) return null;
    const c = value => { value /= 255; return value <= .04045 ? value / 12.92 : Math.pow((value + .055) / 1.055, 2.4); };
    return .2126*c(rgb.r)+.7152*c(rgb.g)+.0722*c(rgb.b);
  };
  const contrast = (a,b) => (Math.max(a,b)+.05)/(Math.min(a,b)+.05);
  const rgbToHsl = rgb => {
    const r=rgb.r/255,g=rgb.g/255,b=rgb.b/255,max=Math.max(r,g,b),min=Math.min(r,g,b),d=max-min;
    let h=0,s=0; const l=(max+min)/2;
    if (d) { s=d/(1-Math.abs(2*l-1)); if(max===r)h=60*(((g-b)/d)%6);else if(max===g)h=60*((b-r)/d+2);else h=60*((r-g)/d+4); }
    return {h:h<0?h+360:h,s,l};
  };
  const cssColor = (h,s,l) => `hsl(${Math.round(h)} ${Math.round(clamp(s)*100)}% ${Math.round(clamp(l)*100)}%)`;
  function pageIsAlreadyDark() {
    const candidates=[document.documentElement,document.body,...document.querySelectorAll('main,article,section,header,nav,footer,div')];
    let dark=0,light=0,inspected=0;
    for(const element of candidates){
      if(!element||inspected>=120)break; const rect=element.getBoundingClientRect();
      if(rect.width<120||rect.height<40||rect.bottom<0||rect.top>innerHeight*1.5)continue;
      const value=luminance(color(getComputedStyle(element).backgroundColor)); if(value==null)continue;
      const weight=Math.min(innerWidth*innerHeight,rect.width*rect.height);
      if(value<.22)dark+=weight;else if(value>.55)light+=weight; inspected++;
    }
    const root=luminance(color(getComputedStyle(document.body||document.documentElement).backgroundColor));
    return (root!=null&&root<.18)||(dark>light*1.35&&dark>innerWidth*innerHeight*.45);
  }
  const nativeDark=pageIsAlreadyDark();
  document.documentElement.dataset.zeusDarkMode=nativeDark?'native':'converted';
  document.documentElement.style.setProperty('color-scheme','dark','important');
  if(nativeDark)return;
  function nearestBackground(element){
    for(let node=element;node;node=node.parentElement){const value=luminance(color(getComputedStyle(node).backgroundColor));if(value!=null)return value;}
    return .02;
  }
  function transform(element){
    if(!(element instanceof Element)||excluded.has(element.tagName)||element.closest('svg'))return;
    const before=`${element.className}|${element.getAttribute('style')||''}`; if(signatures.get(element)===before)return;
    const computed=getComputedStyle(element),background=color(computed.backgroundColor),foreground=color(computed.color);
    if(background){const hsl=rgbToHsl(background);if(hsl.l>.28)element.style.setProperty('background-color',cssColor(hsl.h,Math.min(hsl.s*.55,.38),.055+(1-hsl.l)*.16),'important');}
    const bgLum=nearestBackground(element);
    if(foreground){const fgLum=luminance(foreground);if(contrast(fgLum,bgLum)<4.6||fgLum<.42){const hsl=rgbToHsl(foreground);element.style.setProperty('color',cssColor(hsl.h,Math.min(hsl.s,.65),Math.max(.78,1-hsl.l*.20)),'important');element.style.setProperty('-webkit-text-fill-color','currentColor','important');}}
    const border=color(computed.borderTopColor);if(border&&luminance(border)>.32)element.style.setProperty('border-color','hsl(220 10% 30%)','important');
    if(computed.backgroundImage.includes('gradient(')&&!computed.backgroundImage.includes('url('))element.style.setProperty('background-image','none','important');
    if(element.shadowRoot)install(element.shadowRoot);
    signatures.set(element,`${element.className}|${element.getAttribute('style')||''}`);
  }
  let pending=false;const queue=new Set();
  function schedule(node){
    if(!(node instanceof Element))return;queue.add(node);if(pending)return;pending=true;
    requestAnimationFrame(()=>{pending=false;for(const element of queue){transform(element);for(const child of element.querySelectorAll('*'))transform(child);}queue.clear();});
  }
  function install(root){
    if(roots.has(root))return;roots.add(root);
    const observer=new MutationObserver(records=>{for(const record of records){if(record.type==='attributes')schedule(record.target);else for(const node of record.addedNodes)schedule(node);}});
    observer.observe(root,{childList:true,subtree:true,attributes:true,attributeFilter:['style','class']});
    for(const element of root.querySelectorAll('*'))transform(element);
  }
  install(document);
  document.documentElement.style.setProperty('background-color','#0e1014','important');
  if(document.body)document.body.style.setProperty('background-color','#0e1014','important');
  const originalAttachShadow=Element.prototype.attachShadow;
  Element.prototype.attachShadow=function(options){const root=originalAttachShadow.call(this,options);install(root);return root;};
})();
