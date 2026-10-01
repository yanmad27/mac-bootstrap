const { chromium } = require('playwright');
const http = require('http'), fs = require('fs'), path = require('path');
const OUT = process.argv[2];
const ROOT = '/Users/yanmad27/.paseo/worktrees/2xk4fwlh/unified-page/public';
function serve(root, port) {
  return new Promise(r => { const s = http.createServer((q, res) => {
    let f = path.join(root, q.url.split('?')[0] === '/' ? 'index.html' : q.url.split('?')[0]);
    fs.readFile(f, (e, d) => { if (e) { res.writeHead(404); res.end(); } else { res.writeHead(200, {'content-type': f.endsWith('.html') ? 'text/html; charset=utf-8' : 'text/plain; charset=utf-8'}); res.end(d); } });
  }).listen(port, '127.0.0.1', () => r(s)); });
}
const log = []; const L = (...a) => { const t = a.join(' '); log.push(t); console.log(t); };
const lum = h => { const c = [1,3,5].map(i => parseInt(h.slice(i,i+2),16)/255).map(v => v<=.03928 ? v/12.92 : Math.pow((v+.055)/1.055,2.4)); return .2126*c[0]+.7152*c[1]+.0722*c[2]; };
const ratio = (a,b) => { const x = lum(a), y = lum(b); return (Math.max(x,y)+.05)/(Math.min(x,y)+.05); };
(async () => {
  const s1 = await serve(ROOT, 8878), s2 = await serve('/tmp/pw/old', 8879);
  const br = await chromium.launch();
  const URL = 'http://127.0.0.1:8878/', OLD = 'http://127.0.0.1:8879/';
  const mk = async (o) => { const c = await br.newContext(o); return c; };

  // ---- screenshots
  for (const [w,h] of [[1280,800],[390,844]]) for (const cs of ['light','dark']) {
    const c = await mk({ viewport:{width:w,height:h}, colorScheme:cs, reducedMotion:'reduce' });
    const p = await c.newPage(); await p.goto(URL);
    await p.screenshot({ path:`${OUT}/after-${w}-${cs}.png`, fullPage:true });
    await p.screenshot({ path:`${OUT}/after-first-${w}x${h}-${cs}.png` });
    await c.close();
  }
  { const c = await mk({ viewport:{width:1280,height:800}, javaScriptEnabled:false });
    const p = await c.newPage(); await p.goto(URL); await p.screenshot({ path:`${OUT}/after-1280-light-nojs.png`, fullPage:true });
    // ---- nojs commands
    const r = await p.evaluate(() => ({
      noscript: !!document.querySelector('noscript') , hasNoJs: document.documentElement.classList.contains('no-js'),
      cmds: [...document.querySelectorAll('code[id^="c-"]')].map(e => [e.id, e.textContent]),
      btnVisible: [...document.querySelectorAll('button[data-copy]')].filter(b => b.offsetParent).length,
      hidden: [...document.querySelectorAll('main *')].filter(e => getComputedStyle(e).opacity==='0'||getComputedStyle(e).visibility==='hidden').length,
      noscriptText: document.querySelector('header noscript') ? document.querySelector('header noscript').textContent : ''}));
    L('== JS disabled =='); L('html no-js class:', r.hasNoJs, '| visible Copy buttons:', r.btnVisible, '| opacity0/hidden elements:', r.hidden);
    const nj = r.cmds.filter(([id,t]) => /install\.sh|iterm2-client\.sh/.test(t));
    nj.forEach(([id,t]) => L(' ', id + ':', t.split('\n')[0]));
    L('every origin-built command shows <your-site>:', nj.every(([id,t]) => t.includes('<your-site>')), `(${nj.length} checked)`);
    L('noscript note in source:', /<noscript><p class="note">JavaScript is off/.test(fs.readFileSync(ROOT+'/index.html','utf8')));
    await c.close(); }
  // noscript is not rendered by playwright text with JS disabled? check visible
  { const c = await mk({ viewport:{width:1280,height:800}, javaScriptEnabled:false }); const p = await c.newPage(); await p.goto(URL);
    const t = await p.evaluate(() => document.body.innerText.includes('JavaScript is off, so commands show the literal placeholder'));
    L('noscript note visible with JS off:', t); await c.close(); }

  // ---- JS on: commands, copy, external requests
  { const c = await mk({ viewport:{width:1280,height:800}, permissions:['clipboard-read','clipboard-write'] });
    const p = await c.newPage(); const reqs = [], errs = [];
    p.on('request', q => { if (!q.url().startsWith('http://127.0.0.1:8878')) reqs.push(q.url()); });
    p.on('console', m => { if (m.type()==='error') errs.push(m.text()); }); p.on('pageerror', e => errs.push(String(e)));
    await p.goto(URL);
    const all = await p.evaluate(() => [...document.querySelectorAll('code[id]')].map(e => [e.id, e.textContent]));
    const built = all.filter(([id,t]) => /\/(install|iterm2-client)\.sh/.test(t));
    L('== JS enabled ==');
    L('commands containing install.sh/iterm2-client.sh:', built.length, '| all contain origin', URL.slice(0,-1)+':', built.every(([i,t]) => t.includes('http://127.0.0.1:8878/')), '| any leftover <your-site>:', built.some(([i,t]) => t.includes('<your-site>')));
    built.forEach(([id,t]) => L(' ', id + ':', t));
    L('static commands (no origin by design):', all.filter(([id,t]) => !built.find(b=>b[0]===id)).map(a=>a[0]).join(', '));
    L('--origin argument equals serving origin:', (built.find(b=>b[0]==='c-client')[1].includes('--origin "http://127.0.0.1:8878"')));
    const btns = await p.$$('button[data-copy]'); let bad = [], labels = new Set(), n = 0;
    for (const b of btns) {
      const id = await b.getAttribute('data-copy'); const al = await b.getAttribute('aria-label');
      await b.evaluate(e => e.closest('details') && (e.closest('details').open = true));
      await b.scrollIntoViewIfNeeded(); await b.click();
      const clip = await p.evaluate(() => navigator.clipboard.readText());
      const shown = await p.evaluate(i => document.getElementById(i).textContent, id);
      const st = await p.textContent('#copy-status');
      n++; labels.add(al); if (clip !== shown || !/^Copy /.test(al) || !st.startsWith('Copied')) bad.push(id);
      if (['c-client','c-run','c-dry','c-hero','c-bundle','c-policy','c-secret'].includes(id)) L(`  copied [${id}] aria="${al}" -> ${JSON.stringify(clip.split('\n')[0])}${clip.includes('\n')?' (+more lines)':''}`);
    }
    L(`copy buttons: ${n}, clipboard==displayed text for all: ${bad.length===0} mismatches: ${bad.join(',')||'none'}; aria-labels unique ${labels.size} of ${n}`);
    const noLabel = await p.$$eval('button[data-copy]', bs => bs.filter(b => !b.getAttribute('aria-label')).length);
    L('buttons without aria-label:', noLabel);
    L('external requests:', reqs.length, reqs.join(' ')); L('console/page errors:', errs.length, errs.join(' | '));
    L('external URLs loaded by src/href-less tags (img/link/script src/iframe):', await p.evaluate(() => document.querySelectorAll('img,iframe,link[href],script[src],source,video,audio').length));
    // overflow + overlaps
    for (const w of [1280,390]) { await p.setViewportSize({width:w,height:800});
      await p.evaluate(() => document.querySelectorAll('details').forEach(d => d.open = true));
      const o = await p.evaluate(() => ({sw: document.documentElement.scrollWidth, ov: [...document.querySelectorAll('.cmd')].filter(c => { const pre=c.querySelector('pre'), b=c.querySelector('button'); if(!pre||!b) return false; const r=pre.getBoundingClientRect(), q=b.getBoundingClientRect(); return !(q.left>=r.right-1||q.right<=r.left+1||q.top>=r.bottom||q.bottom<=r.top);}).length}));
      L(`${w}px (all details open): scrollWidth=${o.sw} (<=${w}: ${o.sw<=w}); Copy button overlapping its command text: ${o.ov}`); }
    await c.close(); }

  // ---- reduced motion
  for (const rm of ['reduce','no-preference']) {
    const c = await mk({ viewport:{width:1280,height:800}, reducedMotion:rm }); const p = await c.newPage(); await p.goto(URL);
    const r = await p.evaluate(() => ({ rv: document.querySelectorAll('.rv').length, anim: getComputedStyle(document.querySelector('.tube2')).animationName, sb: getComputedStyle(document.documentElement).scrollBehavior }));
    if (rm==='reduce') L('reduced motion: .rv count='+r.rv, 'tube2 animation-name='+r.anim, 'scroll-behavior='+r.sb);
    else { const before = r.rv; await p.evaluate(async () => { for (let y=0;y<document.body.scrollHeight;y+=200){ window.scrollTo(0,y); await new Promise(r=>setTimeout(r,200)); } await new Promise(r=>setTimeout(r,500)); });
      const after = await p.evaluate(() => ({ rv: document.querySelectorAll('.rv').length, inn: document.querySelectorAll('.rv.in').length, hidden: [...document.querySelectorAll('.rv')].filter(e => getComputedStyle(e).opacity==='0').length }));
      L('motion enabled: .rv below fold at load='+before, 'after scrolling .rv.in='+after.inn+' of '+after.rv, 'still opacity 0:', after.hidden, 'tube2 animation='+r.anim); }
    await c.close(); }

  // ---- word count
  const wc = async (u, w, h) => { const c = await mk({ viewport:{width:w,height:h}, reducedMotion:'reduce', colorScheme:'light' }); const p = await c.newPage(); await p.goto(u);
    const r = await p.evaluate(() => { const code = [...document.querySelectorAll('pre, code')].filter(e => !(e.tagName==='CODE' && e.closest('pre')) && e.getClientRects().length>0).reduce((a,e) => a + (e.innerText||'').split(/\s+/).filter(Boolean).length, 0);
      const vis = document.body.innerText.split(/\s+/).filter(Boolean).length; return {vis, code}; }); await c.close(); return r; };
  L('== word count (document.body.innerText, <details> collapsed, light, reduced motion) ==');
  for (const [w,h] of [[1280,800],[390,844]]) { const o = await wc(OLD,w,h), n = await wc(URL,w,h);
    L(`${w}x${h}: OLD(33d3e07) visible ${o.vis} code ${o.code} non-code ${o.vis-o.code} | NEW visible ${n.vis} code ${n.code} non-code ${n.vis-n.code}`); }

  // ---- contrast
  const c = await mk({}); const p0 = await c.newPage(); await p0.goto(URL); await c.close();
  for (const cs of ['light','dark']) {
    const c2 = await mk({ colorScheme:cs }); const p = await c2.newPage(); await p.goto(URL);
    const v = await p.evaluate(() => { const g = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim(); const o = {}; ['bg','fg','muted','card','soft','accent','accent-fg','code-bg','code-fg','btn-bg','btn-fg','warn','warn-bg','t1','t2','t3','t4','t5','g1','g2','g3','g4','g5','b1','b2','b3'].forEach(k => o[k] = g('--'+k)); return o; });
    const P = [['body text','fg','bg',4.5],['body on card','fg','card',4.5],['body on soft','fg','soft',4.5],['muted on bg','muted','bg',4.5],['muted on card','muted','card',4.5],['muted on soft','muted','soft',4.5],
      ['muted on hero b1','muted','b1',4.5],['muted on hero b2','muted','b2',4.5],['muted on hero b3','muted','b3',4.5],['fg on hero b1','fg','b1',4.5],['fg on hero b2','fg','b2',4.5],['fg on hero b3','fg','b3',4.5],
      ['command text','code-fg','code-bg',4.5],['copy button text','btn-fg','btn-bg',4.5],['links on bg','accent','bg',4.5],['links on card','accent','card',4.5],['links on soft','accent','soft',4.5],['links on t1 (.fork)','accent','t1',4.5],
      ['fg on t1 (GitHub token note, .fork)','fg','t1',4.5],['code text on t1','fg','soft',4.5],['h1 em on b1 (large)','accent','b1',3],['h1 em on b3 (large)','accent','b3',3],['accent-fg on accent','accent-fg','accent',4.5],['warn on warn-bg','warn','warn-bg',4.5],
      ['muted on t3','muted','t3',4.5],['glyph g1 on t1','g1','t1',3],['glyph g2 on t2','g2','t2',3],['glyph g3 on t3','g3','t3',3],['glyph g4 on t4','g4','t4',3],['glyph g5 on t5','g5','t5',3]];
    L(`== contrast ${cs} (resolved CSS custom properties; same pair list as docs/evidence/apple/contrast.txt plus .fork text) ==`); let f = 0;
    P.forEach(([n,a,b,m]) => { const r = ratio(v[a].length===4?'#'+[...v[a].slice(1)].map(x=>x+x).join(''):v[a], v[b].length===4?'#'+[...v[b].slice(1)].map(x=>x+x).join(''):v[b]); if (!(r>=m)) f++; L(`${r.toFixed(2).padStart(5)}  (min ${m})  ${n}  [${v[a]} on ${v[b]}]${r>=m?'':'  FAIL'}`); });
    L('failures:', f);
    await c2.close(); }
  await br.close(); s1.close(); s2.close();
  fs.writeFileSync(OUT + '/checks-raw.txt', log.join('\n') + '\n');
})();
