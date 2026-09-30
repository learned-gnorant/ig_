// Tests de ReelsBlocker/Resources/blocker.js sobre jsdom.
// Ejecutar: cd tools/js-tests && npm install && npm test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM, VirtualConsole } from 'jsdom';

const RES = new URL('../../ReelsBlocker/Resources/', import.meta.url);
const SOURCE = readFileSync(new URL('blocker.js', RES), 'utf8');
const RULES = JSON.parse(readFileSync(new URL('rules.json', RES), 'utf8'));

const NAV = `
  <nav>
    <div class="item"><span><a href="/">Inicio</a></span></div>
    <div class="item"><span><a href="/explore/"><svg aria-label="Explorar"></svg></a></span></div>
    <div class="item"><span><a href="/reels/"><svg aria-label="Reels"></svg></a></span></div>
    <div class="item"><span><a href="/direct/inbox/">DMs</a></span></div>
  </nav>`;

function setup({ path = '/', body = NAV, rules = RULES, enabled = true } = {}) {
  const virtualConsole = new VirtualConsole(); // silencia "Not implemented: navigation"
  const dom = new JSDOM(`<!doctype html><html><head></head><body>${body}</body></html>`, {
    url: `https://www.instagram.com${path}`,
    runScripts: 'outside-only',
    pretendToBeVisual: true,
    virtualConsole,
  });
  const { window } = dom;
  const messages = [];
  window.webkit = { messageHandlers: { rb: { postMessage: (m) => messages.push(JSON.parse(JSON.stringify(m))) } } };
  window.__RB_CONFIG = { enabled, rules: structuredClone(rules) };
  window.eval(SOURCE);
  window.__rb.start();
  window.__rb.ready();
  return { window, document: window.document, messages, rb: window.__rb };
}

const wait = (ms = 150) => new Promise((r) => setTimeout(r, ms));
const isHidden = (el) => el.closest('[data-rb-hidden]') !== null;

test('oculta el ítem de Reels y Explorar sin tocar la barra entera', () => {
  const { document } = setup();
  const reels = document.querySelector('a[href="/reels/"]');
  const explore = document.querySelector('a[href="/explore/"]');
  assert.ok(isHidden(reels));
  assert.ok(isHidden(explore));
  // Sube hasta el wrapper del ítem, nunca hasta <nav>.
  assert.equal(reels.closest('.item').getAttribute('data-rb-hidden') !== null, true);
  assert.equal(document.querySelector('nav').hasAttribute('data-rb-hidden'), false);
  assert.ok(!isHidden(document.querySelector('a[href="/"]')));
  assert.ok(!isHidden(document.querySelector('a[href="/direct/inbox/"]')));
});

test('un svg con ancestors alto no engloba varios enlaces', () => {
  const body = `<div id="bar"><a href="/x/"><div><svg aria-label="Reels"></svg></div></a><a href="/y/">y</a></div>`;
  const { document } = setup({ body });
  assert.ok(isHidden(document.querySelector('a[href="/x/"]')));
  assert.equal(document.getElementById('bar').hasAttribute('data-rb-hidden'), false);
  assert.ok(!isHidden(document.querySelector('a[href="/y/"]')));
});

test('no oculta nada dentro de un reel compartido por DM', () => {
  const body = `<div class="msg"><a href="/reel/ABC123/"><div><svg aria-label="Reels"></svg></div></a></div>`;
  const { document } = setup({ path: '/direct/t/1/', body });
  assert.equal(document.querySelectorAll('[data-rb-hidden]').length, 0);
});

test('pushState a una ruta prohibida se cancela y avisa a Swift', () => {
  const { window, messages } = setup();
  window.history.pushState({}, '', '/reels/');
  assert.equal(window.location.pathname, '/');
  assert.ok(messages.some((m) => m.type === 'blocked' && m.path === '/reels/'));
  assert.ok(window.document.documentElement.classList.contains('rb-blocked-route'));
});

test('rutas permitidas y bloqueadas', () => {
  const { rb } = setup();
  assert.equal(rb.isBlockedPath('/explore/'), true);
  assert.equal(rb.isBlockedPath('/explore/tags/gatos/'), true);
  assert.equal(rb.isBlockedPath('/explore/search/'), false);
  assert.equal(rb.isBlockedPath('/reels'), true);
  assert.equal(rb.isBlockedPath('/reels/audio/123/'), true);
  assert.equal(rb.isBlockedPath('/reel/ABC123/'), false, 'reel individual: se permite, con scroll bloqueado');
  assert.equal(rb.isBlockedPath('/reels/ABC123/'), false);
  assert.equal(rb.isBlockedPath('/direct/inbox/'), false);
  assert.equal(rb.isBlockedPath('/usuario/reels/'), false);
});

test('sin lockScrollOnReelView el reel individual también se bloquea', () => {
  const { rb } = setup({ rules: { ...RULES, lockScrollOnReelView: false } });
  assert.equal(rb.isBlockedPath('/reel/ABC123/'), true);
});

test('reel individual: activa el bloqueo e impide pasar al siguiente', () => {
  const { window, messages } = setup({ path: '/reel/ABC123/', body: '<div id="v"><video></video></div>' });
  assert.ok(window.document.documentElement.classList.contains('rb-reel-lock'));
  window.history.pushState({}, '', '/reels/OTRO999/');
  assert.equal(window.location.pathname, '/reel/ABC123/');
  assert.ok(messages.some((m) => m.type === 'reelSwipeBlocked'));
  // Normalizar /reel/ID → /reels/ID (mismo reel) sí se permite.
  window.history.replaceState({}, '', '/reels/ABC123/');
  assert.equal(window.location.pathname, '/reels/ABC123/');
  // Salir del reel quita el bloqueo.
  window.history.pushState({}, '', '/direct/inbox/');
  assert.equal(window.document.documentElement.classList.contains('rb-reel-lock'), false);
});

test('bloquea touchmove fuera de scrolls libres durante el reel', () => {
  const body = `<div id="scroller" style="overflow-y:auto"><video></video></div>`;
  const { window, document } = setup({ path: '/reel/ABC123/', body });
  const ev = new window.Event('touchmove', { bubbles: true, cancelable: true });
  document.querySelector('video').dispatchEvent(ev);
  assert.equal(ev.defaultPrevented, true);
});

test('oculta publicaciones patrocinadas', () => {
  const body = `
    <article id="ad"><header><span>marca</span><span>Publicidad</span></header></article>
    <article id="post"><header><span>amiga</span></header><p>Publicidad engañosa</p></article>`;
  const { document } = setup({ body });
  assert.ok(document.getElementById('ad').hasAttribute('data-rb-hidden'));
  assert.equal(document.getElementById('post').hasAttribute('data-rb-hidden'), false);
});

test('reaplica las reglas cuando cambia el DOM (MutationObserver)', async () => {
  const { document } = setup({ body: '<div id="root"></div>' });
  document.getElementById('root').innerHTML = NAV;
  await wait();
  assert.ok(isHidden(document.querySelector('a[href="/reels/"]')));
});

test('update() con enabled=false desoculta todo y deja navegar', () => {
  const { window, document, rb } = setup();
  assert.ok(document.querySelectorAll('[data-rb-hidden]').length > 0);
  rb.update({ enabled: false, rules: RULES });
  assert.equal(document.querySelectorAll('[data-rb-hidden]').length, 0);
  window.history.pushState({}, '', '/explore/');
  assert.equal(window.location.pathname, '/explore/');
});

test('un selector inválido no rompe el resto', () => {
  const rules = { ...RULES, hideSelectors: ['a[href=', ...RULES.hideSelectors] };
  const { document } = setup({ rules });
  assert.ok(isHidden(document.querySelector('a[href="/reels/"]')));
});

test('test() cuenta coincidencias e informa de errores', () => {
  const { rb } = setup();
  assert.deepEqual({ ...rb.test('nav a') }, { ok: true, count: 4 });
  assert.equal(rb.test('a[href=').ok, false);
});

test('informa a Swift de la ruta y las estadísticas', () => {
  const { messages } = setup();
  assert.ok(messages.some((m) => m.type === 'route' && m.path === '/'));
  const stats = messages.filter((m) => m.type === 'stats').pop();
  assert.ok(stats && stats.hidden >= 2);
});

test('cargar el script dos veces no duplica nada', () => {
  const { window, messages } = setup();
  const before = messages.length;
  window.eval(SOURCE);
  window.__rb.start();
  window.__rb.ready();
  assert.equal(messages.length, before);
});
