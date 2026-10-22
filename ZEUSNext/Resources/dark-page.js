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
  // Keep CSS/media requests within the current page; no remote translation/proxy service.
  DarkReader.setFetchMethod((url)=>fetch(url,{credentials:'same-origin'}));
  function apply() {
    if(enabled){DarkReader.disable();enabled=false;}
    if(isNativeDark()){root.dataset.zeusDarkMode='native';return;}
    root.dataset.zeusDarkMode='converted';
    DarkReader.enable(settings);enabled=true;
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
