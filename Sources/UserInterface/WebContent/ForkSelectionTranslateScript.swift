// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Fork: the page half of selection translate (`ForkSelectionTranslate`).
///
/// When a selection settles, its text goes to the app (through a DevTools
/// binding) to have its language recognised on this Mac. Text that isn't
/// English gets a small "English" chip just under the end of the selection.
/// Clicking the chip asks the app to translate the text (DeepL) and the chip
/// opens into a card sized to the translation, with Copy and Replace icons in
/// its top-right corner. Escape or a click elsewhere closes it.
///
/// Built without `innerHTML` (Trusted Types sites refuse it), in a closed
/// shadow root with a constructed style sheet (which a page's CSP doesn't
/// block), so pages can't restyle it and it can't restyle them.
enum ForkSelectionTranslateScript {
    static let bindingName = "__phiPlusTranslate"

    static let source = #"""
    (() => {
      const KEY = Symbol.for('phiPlus.translate');
      const BIND = '__phiPlusTranslate';
      // Run again after the app re-attaches: pick up the new binding.
      if (window[KEY]) { window[KEY].rebind(); return; }
      if (!/^(https?|file):$/.test(location.protocol)) return;

      let bound = null;
      const rebind = () => {
        const f = window[BIND];
        if (typeof f !== 'function') return;
        bound = f;
        try { delete window[BIND]; } catch (_) {}
      };
      rebind();
      // On a new page the binding can arrive after this script: look again.
      const send = (m) => {
        if (!bound) rebind();
        if (bound) { try { bound(JSON.stringify(m)); } catch (_) {} }
      };
      let receive = () => {};
      window[KEY] = { rebind, deliver: (m) => receive(m) };

      const start = (f) => document.documentElement
        ? f() : document.addEventListener('DOMContentLoaded', f, { once: true });
      start(() => {

      const MAX_W = 360, MIN_W = 196, GAP = 6, EDGE = 8;
      const EASE = 'cubic-bezier(.2,.85,.2,1)';
      const CSS = `
        :host { all: initial; }
        .box { position: fixed; box-sizing: border-box; overflow: hidden; color: #fff;
          background: rgba(26,26,28,.88); border: .5px solid rgba(255,255,255,.14);
          -webkit-backdrop-filter: blur(24px) saturate(1.8); backdrop-filter: blur(24px) saturate(1.8);
          box-shadow: 0 10px 30px rgba(0,0,0,.26), 0 1px 3px rgba(0,0,0,.22);
          font: 400 12.5px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
          -webkit-font-smoothing: antialiased; border-radius: 13px; opacity: 0;
          transform: translateY(-3px) scale(.9); transform-origin: 100% 0;
          transition: opacity .14s ease, transform .22s cubic-bezier(.2,.9,.25,1.3),
            width .26s ${EASE}, height .26s ${EASE}, border-radius .26s ${EASE}, background-color .15s ease;
          user-select: none; -webkit-user-select: none; cursor: default; }
        .box.on { opacity: 1; transform: none; }
        .box.out { opacity: 0; transform: scale(.96); transition: opacity .12s ease, transform .12s ease; }
        .box.chip { cursor: pointer; }
        .box.chip:hover { background-color: rgba(44,44,48,.92); }
        .box.chip:active { transform: scale(.95); }
        .box.card { border-radius: 12px; }
        .pane { position: absolute; top: 0; right: 0; box-sizing: border-box; transition: opacity .16s ease; }
        .chipv { height: 26px; display: flex; align-items: center; gap: 5px; padding: 0 10px 0 8px;
          white-space: nowrap; font-weight: 500; font-size: 12px; }
        .chipv svg { opacity: .9; }
        .cardv { width: max-content; min-width: ${MIN_W}px; max-width: ${MAX_W}px; padding: 8px 8px 11px 12px; opacity: 0; }
        .head { display: flex; align-items: center; gap: 8px; height: 22px; }
        .lang { flex: 1; min-width: 0; font-size: 11px; color: rgba(255,255,255,.55); white-space: nowrap;
          overflow: hidden; text-overflow: ellipsis; }
        .icon { all: unset; width: 22px; height: 22px; display: grid; place-items: center; border-radius: 6px;
          color: rgba(255,255,255,.58); cursor: pointer; transition: color .12s ease, transform .12s ease; }
        .icon:hover { color: #fff; }
        .icon:active { transform: scale(.88); }
        .icon:focus-visible { outline: 1.5px solid rgba(255,255,255,.5); }
        .body { margin: 2px 4px 0 0; font-size: 13px; line-height: 1.5; color: rgba(255,255,255,.95);
          white-space: pre-wrap; overflow-wrap: anywhere; max-height: 300px; overflow-y: auto;
          user-select: text; -webkit-user-select: text; cursor: text; scrollbar-width: thin; }
        .body.err { color: rgba(255,255,255,.75); font-size: 12.5px; cursor: default; }
        .link { all: unset; color: #8ec5ff; cursor: pointer; }
        .link:hover { text-decoration: underline; }
        .shim { height: 8px; border-radius: 4px; background: rgba(255,255,255,.16); margin: 7px 0 2px;
          animation: pulse 1s ease-in-out infinite; }
        .shim + .shim { margin-top: 6px; animation-delay: .15s; }
        @keyframes pulse { 50% { opacity: .45; } }
        @media (prefers-reduced-motion: reduce) { .box, .pane { transition: opacity .12s ease !important; } }
      `;

      const SVG = 'http://www.w3.org/2000/svg';
      const PATHS = {
        languages: ['m5 8 6 6', 'm4 14 6-6 2-3', 'M2 5h12', 'M7 2h1', 'm22 22-5-10-5 10', 'M14 18h6'],
        copy: [{ x: 8, y: 8, width: 14, height: 14, rx: 2 }, 'M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2'],
        check: ['M20 6 9 17l-5-5'],
        replace: ['M14 4a2 2 0 0 1 2-2', 'M16 10a2 2 0 0 1-2-2', 'M20 2a2 2 0 0 1 2 2', 'M22 8a2 2 0 0 1-2 2',
          'm3 7 3 3 3-3', 'M6 10V5a3 3 0 0 1 3-3h1', { x: 2, y: 14, width: 8, height: 8, rx: 2 }]
      };
      const icon = (name, size) => {
        const s = document.createElementNS(SVG, 'svg');
        for (const [k, v] of Object.entries({ width: size, height: size, viewBox: '0 0 24 24', fill: 'none',
          stroke: 'currentColor', 'stroke-width': 2, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' })) {
          s.setAttribute(k, v);
        }
        for (const p of PATHS[name]) {
          const el = document.createElementNS(SVG, typeof p === 'string' ? 'path' : 'rect');
          if (typeof p === 'string') el.setAttribute('d', p);
          else for (const [k, v] of Object.entries(p)) el.setAttribute(k, v);
          s.appendChild(el);
        }
        return s;
      };
      const el = (tag, cls, text) => {
        const e = document.createElement(tag);
        if (cls) e.className = cls;
        if (text != null) e.textContent = text;
        return e;
      };

      const host = document.createElement('phi-plus-translate');
      host.style.setProperty('all', 'initial', 'important');
      host.style.setProperty('position', 'fixed', 'important');
      host.style.setProperty('inset', '0 auto auto 0', 'important');
      host.style.setProperty('z-index', '2147483647', 'important');
      const root = host.attachShadow({ mode: 'closed' });
      try {
        const sheet = new CSSStyleSheet();
        sheet.replaceSync(CSS);
        root.adoptedStyleSheets = [sheet];
      } catch (_) {
        root.appendChild(el('style', null, CSS));
      }
      const mount = () => {
        const parent = document.fullscreenElement || document.documentElement;
        if (host.parentNode !== parent) parent.appendChild(host);
      };

      // The selection being offered: { id, text, range | input+a+b, box, … }.
      let cur = null, seq = 0, settle = 0, pointerDown = false, frame = 0;

      const inside = (e) => e.composedPath().includes(host);

      const readSelection = () => {
        const ae = document.activeElement;
        if (ae && (ae.tagName === 'TEXTAREA' ||
            (ae.tagName === 'INPUT' && /^(text|search|url|email|)$/i.test(ae.type)))) {
          const a = ae.selectionStart, b = ae.selectionEnd;
          if (a == null || b <= a) return null;
          return { text: ae.value.slice(a, b), input: ae, a, b };
        }
        const sel = getSelection();
        if (!sel || sel.isCollapsed || !sel.rangeCount) return null;
        const node = sel.anchorNode;
        if (!node || node === host || host.contains(node)) return null;
        return { text: sel.toString(), range: sel.getRangeAt(0).cloneRange() };
      };

      const check = () => {
        if (pointerDown) return;
        const s = readSelection();
        const text = s ? s.text.trim() : '';
        if (text.length < 2 || text.length > 5000 || !/\p{L}/u.test(text)) {
          if (cur && cur.state !== 'card') dismiss();
          return;
        }
        if (cur && cur.text === text) return;
        if (cur && cur.state === 'card') return;
        dismiss();
        cur = Object.assign(s, { id: ++seq, text, state: 'pending' });
        send({ op: 'detect', id: cur.id, text: text.slice(0, 400) });
      };
      const schedule = () => { clearTimeout(settle); settle = setTimeout(check, 160); };

      // Where the selection is now: its first line and the end of its last.
      const anchor = () => {
        if (cur.input) {
          const r = cur.input.getBoundingClientRect();
          return { first: r, last: r };
        }
        const rs = cur.range.getClientRects();
        if (!rs.length) { const r = cur.range.getBoundingClientRect(); return { first: r, last: r }; }
        let last = rs[rs.length - 1];
        for (let i = rs.length - 1; i >= 0; i--) { if (rs[i].width > 1) { last = rs[i]; break; } }
        return { first: rs[0], last };
      };

      // Pinned by its right edge under the end of the selection, so the
      // chip opens leftwards and downwards into the card; above the
      // selection when there's no room below.
      const place = (w, h) => {
        if (!cur || !cur.box) return;
        const { first, last } = anchor();
        const box = cur.box.style;
        const gone = (last.width === 0 && last.height === 0) || last.bottom < 0 || first.top > innerHeight;
        box.visibility = gone ? 'hidden' : 'visible';
        let right = Math.max(EDGE, innerWidth - last.right);
        if (innerWidth - right - w < EDGE) right = Math.max(EDGE, innerWidth - w - EDGE);
        box.right = right + 'px';
        const below = last.bottom + GAP;
        if (below + h > innerHeight - EDGE && first.top - GAP - h > EDGE) {
          box.top = 'auto';
          box.bottom = (innerHeight - first.top + GAP) + 'px';
          box.transformOrigin = '100% 100%';
        } else {
          box.bottom = 'auto';
          box.top = below + 'px';
          box.transformOrigin = '100% 0';
        }
        cur.w = w; cur.h = h;
      };
      const size = (w, h) => {
        w += 1; h += 1;  // the box's hairline border
        cur.box.style.width = w + 'px';
        cur.box.style.height = h + 'px';
        place(w, h);
      };

      const dismiss = () => {
        if (!cur) return;
        const box = cur.box;
        cur = null;
        if (!box) return;
        box.classList.add('out');
        setTimeout(() => box.remove(), 140);
      };

      const showChip = (m) => {
        mount();
        const box = el('div', 'box chip');
        const chip = el('div', 'pane chipv');
        chip.appendChild(icon('languages', 14));
        chip.appendChild(el('span', null, 'English'));
        box.appendChild(chip);
        box.title = m.name ? `Translate from ${m.name} to English` : 'Translate to English';
        box.style.visibility = 'hidden';
        root.appendChild(box);
        cur.box = box; cur.chip = chip; cur.from = m.name || ''; cur.state = 'chip';
        size(chip.offsetWidth, 26);
        box.addEventListener('mousedown', (e) => e.preventDefault());
        box.addEventListener('click', () => { if (cur && cur.box === box && cur.state === 'chip') translate(); });
        requestAnimationFrame(() => requestAnimationFrame(() => box.classList.add('on')));
      };

      // The card's content; the box grows (or shrinks) to fit it.
      const fill = (build) => {
        const card = el('div', 'pane cardv');
        build(card);
        const old = cur.card;
        cur.box.appendChild(card);
        cur.card = card;
        const w = Math.ceil(card.offsetWidth), h = Math.ceil(card.offsetHeight);
        size(w, h);
        if (cur.chip) { cur.chip.style.opacity = '0'; const c = cur.chip; cur.chip = null; setTimeout(() => c.remove(), 180); }
        requestAnimationFrame(() => { card.style.opacity = '1'; });
        if (old) { old.style.opacity = '0'; setTimeout(() => old.remove(), 180); }
      };

      const head = (card, label, actions) => {
        const row = el('div', 'head');
        row.appendChild(el('span', 'lang', label));
        for (const a of actions || []) row.appendChild(a);
        card.appendChild(row);
      };
      const iconButton = (name, label, action) => {
        const b = el('button', 'icon');
        b.type = 'button';
        b.title = label;
        b.setAttribute('aria-label', label);
        b.appendChild(icon(name, 14));
        b.addEventListener('mousedown', (e) => e.preventDefault());
        b.addEventListener('click', (e) => { e.stopPropagation(); action(b); });
        return b;
      };

      const translate = () => {
        cur.state = 'card';
        cur.box.classList.remove('chip');
        cur.box.classList.add('card');
        cur.box.removeAttribute('title');
        fill((card) => {
          card.style.width = '240px';
          head(card, cur.from ? `${cur.from} → English` : 'Translating…');
          card.appendChild(el('div', 'shim'));
          const s2 = el('div', 'shim');
          s2.style.width = '62%';
          card.appendChild(s2);
        });
        send({ op: 'translate', id: cur.id, text: cur.text });
      };

      const showResult = (m) => {
        cur.translation = m.text;
        const from = m.name || cur.from;
        fill((card) => {
          head(card, from ? `${from} → English` : 'English', [
            iconButton('copy', 'Copy', (b) => {
              send({ op: 'copy', id: cur.id, text: cur.translation });
              b.replaceChildren(icon('check', 14));
              setTimeout(() => b.replaceChildren(icon('copy', 14)), 1200);
            }),
            iconButton('replace', 'Replace on page', () => replace())
          ]);
          card.appendChild(el('div', 'body', m.text));
        });
      };

      const showError = (m) => {
        fill((card) => {
          head(card, cur.from ? `${cur.from} → English` : 'Translate');
          const body = el('div', 'body err', m.message + (m.settings ? ' ' : ''));
          if (m.settings) {
            const link = el('button', 'link', 'Open Settings');
            link.type = 'button';
            link.addEventListener('mousedown', (e) => e.preventDefault());
            link.addEventListener('click', () => { send({ op: 'settings', id: cur.id }); dismiss(); });
            body.appendChild(link);
          }
          card.appendChild(body);
        });
      };

      const replace = () => {
        const t = cur.translation;
        try {
          if (cur.input) {
            const input = cur.input;
            input.focus();
            input.setSelectionRange(cur.a, cur.b);
            if (!document.execCommand('insertText', false, t)) {
              input.setRangeText(t, cur.a, cur.b, 'end');
              input.dispatchEvent(new Event('input', { bubbles: true }));
            }
          } else {
            const r = cur.range;
            const start = r.startContainer.nodeType === 1 ? r.startContainer : r.startContainer.parentElement;
            if (start && start.isContentEditable) {
              const sel = getSelection();
              sel.removeAllRanges();
              sel.addRange(r);
              document.execCommand('insertText', false, t);
            } else {
              r.deleteContents();
              r.insertNode(document.createTextNode(t));
              getSelection().removeAllRanges();
            }
          }
        } catch (_) {}
        dismiss();
      };

      receive = (m) => {
        if (!cur || m.id !== cur.id) return;
        if (m.op === 'offer' && cur.state === 'pending') showChip(m);
        else if (m.op === 'result' && cur.state === 'card') showResult(m);
        else if (m.op === 'error' && cur.state === 'card') showError(m);
      };

      document.addEventListener('pointerdown', (e) => {
        if (inside(e)) return;
        pointerDown = true;
        clearTimeout(settle);
        dismiss();
      }, true);
      document.addEventListener('pointerup', (e) => {
        pointerDown = false;
        if (!inside(e)) schedule();
      }, true);
      document.addEventListener('selectionchange', () => { if (!pointerDown) schedule(); });
      document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && cur && cur.box) { dismiss(); e.stopPropagation(); }
      }, true);
      const follow = () => {
        if (frame || !cur || !cur.box) return;
        frame = requestAnimationFrame(() => { frame = 0; if (cur && cur.box) place(cur.w, cur.h); });
      };
      addEventListener('scroll', follow, { capture: true, passive: true });
      addEventListener('resize', follow, { passive: true });
      document.addEventListener('fullscreenchange', () => { dismiss(); mount(); }, true);
      });
    })();
    """#
}
