// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Fork: a picture-in-picture button over videos. Hovering a video shows
/// the picture-in-picture icon at the video's top-right corner, white on a
/// black rounded square (without the grey border ring of the extension it
/// replaces); clicking it pops the video out, or back in.
/// `ForkSettings.videoPiPButtonEnabled`, on by default.
///
/// `ForkPageScripts` adds the script to every frame of a page, embedded
/// players included. It installs itself once per document and survives
/// in-page (SPA) navigation. It runs in the page's main world, so it builds
/// its DOM without `innerHTML` (Trusted Types sites such as YouTube refuse
/// it), and finds videos inside shadow DOM through `ForkPageScripts`'s
/// shadow-root registry as well as in the document.
enum ForkVideoPiPButton {
    static let script = """
    (() => {
      const KEY = Symbol.for('phiPlus.videoPiPButton');
      if (window[KEY] || !/^https?:$/.test(location.protocol)) return;
      window[KEY] = true;
      // Added as the document starts: build the button once there is a page.
      const start = (install) => document.documentElement
        ? install() : document.addEventListener('DOMContentLoaded', install, { once: true });
      start(() => {

      const SIZE = 44, ICON = 26, INSET = 10, HIDE_AFTER = 3000;
      const SVG = 'http://www.w3.org/2000/svg';
      const svg = document.createElementNS(SVG, 'svg');
      for (const [k, v] of Object.entries({ width: ICON, height: ICON, viewBox: '0 0 24 24', fill: 'none',
        stroke: 'currentColor', 'stroke-width': 2, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' })) {
        svg.setAttribute(k, v);
      }
      const rect = (attrs) => {
        const r = document.createElementNS(SVG, 'rect');
        for (const [k, v] of Object.entries(attrs)) r.setAttribute(k, v);
        svg.appendChild(r);
      };
      rect({ x: 2, y: 3, width: 20, height: 14, rx: 2, ry: 2 });
      rect({ x: 13, y: 12, width: 8, height: 6, rx: 1, ry: 1, fill: 'currentColor' });

      const button = document.createElement('button');
      button.type = 'button';
      button.title = 'Picture in Picture';
      button.setAttribute('aria-label', 'Picture in Picture');
      button.appendChild(svg);
      button.style.cssText = [
        'all: initial', 'position: fixed', 'z-index: 2147483647', 'box-sizing: border-box',
        `width: ${SIZE}px`, `height: ${SIZE}px`, 'display: flex', 'align-items: center',
        'justify-content: center', 'margin: 0', 'padding: 0', 'border: 0', 'border-radius: 9px',
        'background: rgba(0,0,0,.88)', 'box-shadow: 0 2px 8px rgba(0,0,0,.35)',
        'color: #fff', 'cursor: pointer', 'opacity: 0', 'pointer-events: none',
        'transition: opacity .2s ease, transform .15s ease'
      ].map((d) => d + ' !important').join(';');

      let video = null, hideTimer = 0, overButton = false, frame = 0, lastX = -1, lastY = -1;

      const host = () => document.fullscreenElement || document.body || document.documentElement;
      const mount = () => { const h = host(); if (button.parentNode !== h) h.appendChild(button); };

      // The part of an element on screen: players often size their video
      // larger than the player and let the player's box cut it off.
      const visibleRect = (el) => {
        const r = el.getBoundingClientRect();
        let left = r.left, top = r.top, right = r.right, bottom = r.bottom;
        for (let p = el.parentElement; p && p !== document.body && p !== document.documentElement; p = p.parentElement) {
          const s = getComputedStyle(p);
          if (s.overflowX === 'visible' && s.overflowY === 'visible' && !/paint|strict|content/.test(s.contain)) continue;
          const q = p.getBoundingClientRect();
          left = Math.max(left, q.left); top = Math.max(top, q.top);
          right = Math.min(right, q.right); bottom = Math.min(bottom, q.bottom);
        }
        left = Math.max(left, 0); top = Math.max(top, 0);
        right = Math.min(right, innerWidth); bottom = Math.min(bottom, innerHeight);
        return { left, top, right, bottom, width: right - left, height: bottom - top };
      };

      // Where the video shows. Some players and extensions (YouTube with
      // Ambient light) move the video element itself out of view and show
      // the picture in its player; then the player's box is the place.
      const videoRect = (v) => {
        const r = visibleRect(v);
        const full = v.getBoundingClientRect();
        if (r.width > 0 && r.height > 0 && r.width * r.height >= 0.5 * full.width * full.height) return r;
        for (let p = v.parentElement, i = 0; p && i < 8; p = p.parentElement, i++) {
          const q = visibleRect(p);
          if (q.width >= 160 && q.height >= 90) return q;
        }
        return r;
      };

      const allVideos = () => {
        const found = [...document.querySelectorAll('video')];
        const shadow = window[Symbol.for('phiPlus.shadowRoots')];
        if (shadow) for (const root of shadow.roots()) found.push(...root.querySelectorAll('video'));
        return found;
      };

      const visibleVideoAt = (x, y) => {
        let best = null, bestArea = 0;
        for (const v of allVideos()) {
          const r = videoRect(v);
          if (r.width < 120 || r.height < 68) continue;
          if (x < r.left || x > r.right || y < r.top || y > r.bottom) continue;
          const area = r.width * r.height;
          if (area > bestArea) { best = v; bestArea = area; }
        }
        return best;
      };

      const place = () => {
        if (!video || !video.isConnected) return hide();
        const r = videoRect(video);
        if (r.width < SIZE || r.height < SIZE) return hide();
        const left = r.right - SIZE - INSET;
        const top = r.top + INSET;
        button.style.setProperty('left', Math.max(0, left) + 'px', 'important');
        button.style.setProperty('top', Math.max(0, top) + 'px', 'important');
      };

      const show = (v) => {
        video = v;
        mount();
        place();
        button.style.setProperty('opacity', '1', 'important');
        button.style.setProperty('pointer-events', 'auto', 'important');
        clearTimeout(hideTimer);
        hideTimer = setTimeout(() => { if (!overButton) hide(); }, HIDE_AFTER);
      };

      function hide() {
        clearTimeout(hideTimer);
        button.style.setProperty('opacity', '0', 'important');
        button.style.setProperty('pointer-events', 'none', 'important');
      }

      document.addEventListener('mousemove', (e) => {
        lastX = e.clientX; lastY = e.clientY;
        if (frame) return;
        frame = requestAnimationFrame(() => {
          frame = 0;
          if (overButton) return;
          const v = visibleVideoAt(lastX, lastY);
          if (v) show(v); else hide();
        });
      }, { capture: true, passive: true });
      // The pointer leaving the page (a capturing listener would also hear
      // every element's mouseleave, the video's included).
      document.documentElement.addEventListener('mouseleave', () => { if (!overButton) hide(); });
      addEventListener('scroll', () => { if (video && button.style.opacity === '1') place(); }, { capture: true, passive: true });
      addEventListener('resize', () => hide(), { passive: true });
      document.addEventListener('fullscreenchange', () => { hide(); mount(); }, true);

      button.addEventListener('mouseenter', () => {
        overButton = true;
        clearTimeout(hideTimer);
        button.style.setProperty('transform', 'scale(1.12)', 'important');
      });
      button.addEventListener('mouseleave', () => {
        overButton = false;
        button.style.setProperty('transform', 'scale(1)', 'important');
        hideTimer = setTimeout(hide, 600);
      });
      // Keep the player from taking the click as its own (pause, seek).
      for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'dblclick']) {
        button.addEventListener(type, (e) => e.stopPropagation(), true);
      }
      button.addEventListener('click', async (e) => {
        e.preventDefault();
        e.stopPropagation();
        try {
          if (document.pictureInPictureElement) {
            await document.exitPictureInPicture();
          } else if (video) {
            video.disablePictureInPicture = false;
            video.removeAttribute('disablepictureinpicture');
            await video.requestPictureInPicture();
          }
        } catch (_) {}
        hide();
      }, true);
      });
    })();
    """
}
