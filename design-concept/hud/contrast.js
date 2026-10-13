// Text contrast of the HUD mockup, as rendered: open index.html in a browser
// and paste this into its console. For every text run on the HUD, the strip
// and the window, in both themes, it composites the text's colour (with every
// ancestor's opacity) over the nearest opaque background and reports the
// WCAG ratio. Text needs 4.5:1, or 3:1 from 24px (18.66px bold).
(() => {
  const parse = (c) => { const p = c.match(/rgba?\(([^)]+)\)/)[1].split(/[ ,/]+/).filter(Boolean).map(Number); return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1]; };
  const over = (fg, bg) => [0, 1, 2].map((i) => fg[i] * fg[3] + bg[i] * (1 - fg[3]));
  const lum = (c) => { const f = (x) => { x /= 255; return x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4; }; return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]); };
  const ratio = (a, b) => { const [h, l] = [lum(a), lum(b)].sort((x, y) => y - x); return (h + 0.05) / (l + 0.05); };
  const background = (el) => { for (let e = el; e; e = e.parentElement) { const c = parse(getComputedStyle(e).backgroundColor); if (c[3] >= 0.99) return c; } return [255, 255, 255, 1]; };
  const opacity = (el) => { let o = 1; for (let e = el; e; e = e.parentElement) o *= Number(getComputedStyle(e).opacity); return o; };
  const rows = [];
  for (const surface of document.querySelectorAll('.hud, .strip, .window')) {
    const theme = surface.closest('.light') ? 'light' : 'dark';
    const walker = document.createTreeWalker(surface, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      const text = n.textContent.trim();
      if (!text || text === '\u00a0') continue;
      const el = n.parentElement, cs = getComputedStyle(el);
      if (cs.visibility === 'hidden' || cs.display === 'none' || (el.offsetParent === null && cs.position !== 'fixed')) continue;
      const bg = background(el), fg = parse(cs.color);
      fg[3] *= opacity(el);
      const size = parseFloat(cs.fontSize), bold = Number(cs.fontWeight) >= 700;
      rows.push({ theme, surface: surface.className.split(' ')[0], text: text.slice(0, 32), ratio: +ratio(over(fg, bg), bg).toFixed(2), need: size >= 24 || (size >= 18.66 && bold) ? 3 : 4.5 });
    }
  }
  const failing = rows.filter((r) => r.ratio < r.need);
  console.table(failing.length ? failing : [{ checked: rows.length, failing: 0, lowest: Math.min(...rows.map((r) => r.ratio)) }]);
  return failing;
})();
