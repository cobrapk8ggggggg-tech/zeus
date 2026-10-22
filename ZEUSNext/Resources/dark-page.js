(() => {
  'use strict';
  if (window.__zeusDarkPage || !window.DarkReader) return;
  window.__zeusDarkPage = true;
  const root = document.documentElement;
  let enabled = false, timer;
  function isNativeDark() {
    const samples = [document.body, root, ...Array.from(document.querySelectorAll('main,article,[role="main"],section,div')).slice(0,100)];
    let dark=0, light=0;
    for(const el of samples) {
      if(!el)continue;
      const r=el.getBoundingClientRect();
      if(r.width<innerWidth*.35 || r.height<60 || r.top>innerHeight || r.bottom<0)continue;
      const c=getComputedStyle(el).backgroundColor.match(/[\d.]+/g)?.map(Number);
      if(!c || c.length<3 || c[3]===0)continue;
      const lum=(c[0]*.2126+c[1]*.7152+c[2]*.0722)/255;
      const weight=Math.min(r.width*r.height,innerWidth*innerHeight);
      if(lum<.32)dark+=weight;else if(lum>.65)light+=weight;
    }
    return dark>0 && dark>light*1.2;
  }
  const settings = {brightness:100, contrast:100, sepia:0, mode:1, darkSchemeBackgroundColor:'#141414', darkSchemeTextColor:'#e6e6e6'};
  // Inline !important declarations beat generated stylesheets. Repair only
  // measured contrast failures after Dark Reader, without inverting media.
  const repairQueue = new Set(); let repairPending = false;
  const rgb = value => {const n=value.match(/[\d.]+/g)?.map(Number);return n&&n.length>=3&&n[3]!==0?n:null;};
  const lum = value => {const c=value.slice(0,3).map(x=>{x/=255;return x<=.04045?x/12.92:Math.pow((x+.055)/1.055,2.4)});return c[0]*.2126+c[1]*.7152+c[2]*.0722;};
  function repair(element) {
    if(!enabled || !(element instanceof Element)||element.closest('svg,picture,video,canvas')||['IMG','STYLE','SCRIPT','LINK','IFRAME'].includes(element.tagName))return;
    let css=getComputedStyle(element),bg=rgb(css.backgroundColor);
    if(bg&&lum(bg)>.55) {
      const mapped=bg.slice(0,3).map(x=>Math.round(20+(255-x)*.1));
      element.style.setProperty('background-color',`rgb(${mapped.join(',')})`,'important');
    }
    let background=null;
    for(let parent=element;parent;parent=parent.parentElement){background=rgb(getComputedStyle(parent).backgroundColor);if(background)break;}
    background=background||[20,20,20];
    const textStyle=getComputedStyle(element),fg=rgb(textStyle.webkitTextFillColor)||rgb(textStyle.color);if(!fg)return;
    const a=lum(fg),b=lum(background),ratio=(Math.max(a,b)+.05)/(Math.min(a,b)+.05);
    if(b<.25&&ratio<4.5) {
      const mapped=fg.slice(0,3).map(x=>Math.round(205+x*.19));
      element.style.setProperty('color',`rgb(${mapped.join(',')})`,'important');
      element.style.setProperty('-webkit-text-fill-color','currentColor','important');
    }
    if(element.shadowRoot){watchRepair(element.shadowRoot);for(const child of element.shadowRoot.querySelectorAll('*'))repair(child);}
  }
  function scheduleRepair(node) {
    if(!(node instanceof Element))return;repairQueue.add(node);if(repairPending)return;repairPending=true;
    requestAnimationFrame(()=>{repairPending=false;for(const e of repairQueue){repair(e);for(const child of e.querySelectorAll('*'))repair(child);}repairQueue.clear();});
  }
  const repairRoots=new WeakSet();
  function watchRepair(target){if(repairRoots.has(target))return;repairRoots.add(target);new MutationObserver(records=>{for(const record of records){if(record.type==='attributes')scheduleRepair(record.target);else for(const node of record.addedNodes)scheduleRepair(node);}}).observe(target,{childList:true,subtree:true,attributes:true,attributeFilter:['style','class']});}
  // Keep CSS/media requests within the current page; no remote translation/proxy service.
  DarkReader.setFetchMethod((url)=>fetch(url,{credentials:'same-origin'}));
  function apply() {
    if(enabled){DarkReader.disable();enabled=false;}
    if(isNativeDark()){root.dataset.zeusDarkMode='native';return;}
    root.dataset.zeusDarkMode='converted';
    DarkReader.enable(settings);enabled=true;
    watchRepair(document);scheduleRepair(root);setTimeout(()=>scheduleRepair(root),250);
  }
  apply();
  const observer=new MutationObserver(records=>{
    if(records.some(r=>r.attributeName==='class'||r.attributeName==='data-theme'||r.attributeName==='data-color-mode')) {
      clearTimeout(timer);timer=setTimeout(apply,180);
    }
  });
  observer.observe(root,{attributes:true,attributeFilter:['class','data-theme','data-color-mode']});
  if(document.body)observer.observe(document.body,{attributes:true,attributeFilter:['class','data-theme','data-color-mode']});
  window.addEventListener('pagehide',()=>{observer.disconnect();clearTimeout(timer);},{once:true});
})();
