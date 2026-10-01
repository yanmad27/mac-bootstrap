// node wordcount.js <base.html> <new.html>   (pages are served from 127.0.0.1)
// Method (same for both pages): document.body.innerText, every <details> collapsed (default), light scheme,
// reduced motion, split on whitespace. code = words in visible <pre>/<code> (nested code inside pre counted once).
// non-code = visible - code. Budget: non-code <= 334 at 1280 (docs/evidence/apple/wordcount.txt).
const { chromium } = require('playwright'); const http = require('http'), fs = require('fs');
const serve = (f, port) => new Promise(r => { const s = http.createServer((q, res) => { res.writeHead(200, {'content-type':'text/html; charset=utf-8'}); res.end(fs.readFileSync(f)); }).listen(port, '127.0.0.1', () => r(s)); });
(async () => {
  const [base, nw] = process.argv.slice(2); const s1 = await serve(base, 8881), s2 = await serve(nw, 8882);
  const br = await chromium.launch(); const out = [];
  for (const [name, port] of [['BASE', 8881], ['NEW', 8882]]) for (const [w, h] of [[1280, 800], [390, 844]]) {
    const p = await br.newPage({ viewport: { width: w, height: h }, reducedMotion: 'reduce', colorScheme: 'light' }); await p.goto(`http://127.0.0.1:${port}/`);
    const r = await p.evaluate(() => { const W = t => t.split(/\s+/).filter(Boolean).length;
      const code = [...document.querySelectorAll('pre, code')].filter(e => !(e.tagName === 'CODE' && e.closest('pre')) && e.getClientRects().length).reduce((a, e) => a + W(e.innerText), 0);
      const vis = W(document.body.innerText); return { vis, code, non: vis - code }; });
    out.push(`${name} ${w}x${h}: visible ${r.vis} code ${r.code} non-code ${r.non}` + (w === 1280 ? `  (limit 334: ${r.non <= 334 ? 'met' : 'EXCEEDED'})` : ''));
    await p.close();
  }
  console.log(out.join('\n')); await br.close(); s1.close(); s2.close();
})();
