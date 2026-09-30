// ReelsBlocker — script inyectado en instagram.com mediante WKUserScript.
//
// ScriptBuilder.swift lo inyecta dos veces:
//   - .atDocumentStart: define window.__RB_CONFIG y llama a __rb.start()
//     (hoja de estilo + parche de history + guardia de rutas, sin flash).
//   - .atDocumentEnd: llama a __rb.ready() (MutationObserver + ocultación por JS).
// Todo es idempotente: evaluarlo varias veces no instala nada dos veces.
//
// Mensajes a Swift (window.webkit.messageHandlers.rb):
//   { type: 'route',   path, href }           cambio de ruta (SPA o carga)
//   { type: 'blocked', path }                 ruta prohibida, se vuelve a '/'
//   { type: 'reelSwipeBlocked', path }        intento de pasar al siguiente reel
//   { type: 'stats',   hidden, reelLock, path }
(function () {
  'use strict';
  if (window.__rb) { return; }

  var DEBOUNCE_MS = 100;
  var HIDDEN_ATTR = 'data-rb-hidden';
  var LOCK_ATTR = 'data-rb-locked';
  // Nunca se oculta uno de estos al subir por los ancestros.
  var BARRIER = 'html,body,main,nav,article,[role="main"],[role="navigation"],[role="dialog"],[role="feed"]';
  var INTERACTIVE = 'a[href],button,[role="link"],[role="button"],[role="tab"]';

  var cfg = window.__RB_CONFIG || { enabled: false, rules: {} };
  var root = document.documentElement;
  var sheet = null;
  var styleEl = null;
  var started = false;
  var readyDone = false;
  var timer = null;
  var lastPath = null;
  var lastStats = '';
  var redirecting = false;
  var reelLockOn = false;

  // ---------------------------------------------------------------- utilidades

  function post(msg) {
    try { window.webkit.messageHandlers.rb.postMessage(msg); } catch (e) { /* fuera de la app */ }
  }

  function rules() { return (cfg && cfg.rules) || {}; }
  function list(x) { return Array.isArray(x) ? x : []; }

  function selectorOf(rule) {
    if (typeof rule === 'string') { return rule; }
    return rule && typeof rule.selector === 'string' ? rule.selector : null;
  }

  function ancestorsOf(rule, fallback) {
    if (rule && typeof rule === 'object' && typeof rule.ancestors === 'number') { return rule.ancestors; }
    return fallback;
  }

  function isValidSelector(sel) {
    try { document.createDocumentFragment().querySelector(sel); return true; } catch (e) { return false; }
  }

  // --------------------------------------------------------------------- rutas

  function pathOf(url) {
    try { return new URL(String(url), location.href).pathname; } catch (e) { return null; }
  }

  function matchesPrefix(path, prefix) {
    if (!prefix) { return false; }
    if (path.indexOf(prefix) === 0) { return true; }
    // "/reels/" también cubre "/reels".
    return prefix.charAt(prefix.length - 1) === '/' && path === prefix.slice(0, -1);
  }

  function isSingleReel(path) {
    var r = rules();
    if (!r.lockScrollOnReelView || !r.singleReelPathPattern) { return false; }
    try { return new RegExp(r.singleReelPathPattern).test(path); } catch (e) { return false; }
  }

  function reelId(path) {
    var m = /^\/reels?\/([^\/]+)/.exec(path);
    return m ? m[1] : null;
  }

  // Misma lógica que PathPolicy en WebViewCoordinator.swift.
  function isBlockedPath(path) {
    if (!cfg.enabled || !path) { return false; }
    var r = rules();
    if (list(r.allowedPathPrefixes).some(function (p) { return matchesPrefix(path, p); })) { return false; }
    if (isSingleReel(path)) { return false; }
    return list(r.blockedPathPrefixes).some(function (p) { return matchesPrefix(path, p); });
  }

  // Pasar de un reel individual a otro distinto = deslizar al siguiente.
  function isReelSwipe(from, to) {
    if (!cfg.enabled || !isSingleReel(from) || !isSingleReel(to)) { return false; }
    var a = reelId(from);
    var b = reelId(to);
    return !!a && !!b && a !== b;
  }

  function goHome(path) {
    if (redirecting) { return; }
    redirecting = true;
    root.classList.add('rb-blocked-route');
    post({ type: 'blocked', path: path });
    location.replace('/');
  }

  function onRouteChange() {
    var path = location.pathname;
    if (path === lastPath) { return; }
    lastPath = path;
    post({ type: 'route', path: path, href: location.href });
    if (isBlockedPath(path)) { goHome(path); return; }
    updateReelLock();
    schedule();
  }

  function patchHistory() {
    ['pushState', 'replaceState'].forEach(function (name) {
      var proto = window.History && History.prototype;
      var orig = proto && proto[name];
      if (typeof orig !== 'function' || orig.__rb) { return; }
      var wrapped = function (state, title, url) {
        if (url !== undefined && url !== null) {
          var to = pathOf(url);
          if (to && isBlockedPath(to)) { goHome(to); return; }
          if (to && isReelSwipe(location.pathname, to)) {
            post({ type: 'reelSwipeBlocked', path: to });
            return;
          }
        }
        var result = orig.apply(this, arguments);
        onRouteChange();
        return result;
      };
      wrapped.__rb = true;
      proto[name] = wrapped;
    });
    window.addEventListener('popstate', onRouteChange);
  }

  // ------------------------------------------------------------------- estilos

  function buildCSS() {
    if (!cfg.enabled) { return ''; }
    var r = rules();
    var out = ['html.rb-blocked-route body{visibility:hidden!important}'];
    list(r.hideSelectors).forEach(function (rule) {
      var sel = selectorOf(rule);
      // Una regla por selector: uno inválido no tumba al resto.
      if (sel && isValidSelector(sel)) { out.push(sel + '{display:none!important}'); }
    });
    if (r.lockScrollOnReelView) {
      out.push('html.rb-reel-lock,html.rb-reel-lock body{overflow:hidden!important;overscroll-behavior:none!important}');
      list(r.reelViewHideSelectors).forEach(function (sel) {
        if (sel && isValidSelector(sel)) { out.push('html.rb-reel-lock :is(' + sel + '){display:none!important}'); }
      });
    }
    return out.join('\n');
  }

  function ensureStyleAttached() {
    if (sheet) {
      if (document.adoptedStyleSheets.indexOf(sheet) < 0) {
        document.adoptedStyleSheets = document.adoptedStyleSheets.concat([sheet]);
      }
      return;
    }
    if (styleEl && !styleEl.isConnected) {
      (document.head || document.documentElement).appendChild(styleEl);
    }
  }

  function installStyles() {
    var css = buildCSS();
    // Hoja construible: no depende de <head> ni de la CSP de estilos inline.
    try {
      if (!sheet) { sheet = new CSSStyleSheet(); }
      sheet.replaceSync(css);
      ensureStyleAttached();
      return;
    } catch (e) {
      sheet = null;
    }
    if (!styleEl) {
      styleEl = document.createElement('style');
      styleEl.id = 'rb-style';
    }
    styleEl.textContent = css;
    ensureStyleAttached();
  }

  // ----------------------------------------------------------------- ocultación

  function isProtected(el) {
    var never = list(rules().neverHideInside);
    for (var i = 0; i < never.length; i++) {
      try { if (el.closest(never[i])) { return true; } } catch (e) { /* selector inválido */ }
    }
    return false;
  }

  function isBarrier(el) {
    try { if (el.matches(BARRIER)) { return true; } } catch (e) { return true; }
    return !!el.querySelector('main,nav,[role="main"],[role="navigation"]');
  }

  // Sube `levels` padres, sin cruzar barreras ni englobar más de un elemento
  // interactivo (así no se come la barra de navegación entera).
  function pickTarget(el, levels) {
    var target = el;
    for (var i = 0; i < levels; i++) {
      var p = target.parentElement;
      if (!p || isBarrier(p)) { break; }
      if (p.querySelectorAll(INTERACTIVE).length > 1) { break; }
      target = p;
    }
    return target;
  }

  function hide(el, tag) {
    if (el.hasAttribute(HIDDEN_ATTR)) { return; }
    el.setAttribute(HIDDEN_ATTR, tag);
    el.style.setProperty('display', 'none', 'important');
  }

  function unhideAll() {
    var nodes = document.querySelectorAll('[' + HIDDEN_ATTR + ']');
    for (var i = 0; i < nodes.length; i++) {
      nodes[i].removeAttribute(HIDDEN_ATTR);
      nodes[i].style.removeProperty('display');
    }
  }

  function hideSelectors() {
    var r = rules();
    var fallback = typeof r.hideAncestorLevels === 'number' ? r.hideAncestorLevels : 0;
    list(r.hideSelectors).forEach(function (rule, index) {
      var sel = selectorOf(rule);
      if (!sel) { return; }
      var nodes;
      try { nodes = document.querySelectorAll(sel); } catch (e) { return; }
      var levels = ancestorsOf(rule, fallback);
      for (var i = 0; i < nodes.length; i++) {
        if (isProtected(nodes[i])) { continue; }
        hide(pickTarget(nodes[i], levels), 's' + index);
      }
    });
  }

  function hideSponsored() {
    var labels = {};
    list(rules().sponsoredLabels).forEach(function (l) { labels[String(l).toLowerCase()] = true; });
    var articles = document.querySelectorAll('article:not([' + HIDDEN_ATTR + '])');
    for (var i = 0; i < articles.length; i++) {
      var spans = articles[i].querySelectorAll('span,a');
      for (var j = 0; j < spans.length; j++) {
        if (spans[j].childElementCount !== 0) { continue; }
        var text = (spans[j].textContent || '').trim().toLowerCase();
        if (text && text.length < 20 && labels[text]) { hide(articles[i], 'ad'); break; }
      }
    }
  }

  // ------------------------------------------------------- reel individual fijo

  function isScrollable(el) {
    var oy = getComputedStyle(el).overflowY;
    return (oy === 'auto' || oy === 'scroll') && el.scrollHeight > el.clientHeight + 1;
  }

  function lockContainers() {
    var videos = document.querySelectorAll('video');
    for (var i = 0; i < videos.length; i++) {
      for (var el = videos[i].parentElement; el && el !== document.body && el !== root; el = el.parentElement) {
        if (el.hasAttribute(LOCK_ATTR) || !isScrollable(el)) { continue; }
        el.setAttribute(LOCK_ATTR, String(el.scrollTop));
        el.style.setProperty('overflow', 'hidden', 'important');
        el.style.setProperty('overscroll-behavior', 'none', 'important');
      }
    }
  }

  function unlockContainers() {
    var nodes = document.querySelectorAll('[' + LOCK_ATTR + ']');
    for (var i = 0; i < nodes.length; i++) {
      nodes[i].removeAttribute(LOCK_ATTR);
      nodes[i].style.removeProperty('overflow');
      nodes[i].style.removeProperty('overscroll-behavior');
    }
  }

  function updateReelLock() {
    var on = !!cfg.enabled && isSingleReel(location.pathname);
    if (on !== reelLockOn) {
      reelLockOn = on;
      root.classList.toggle('rb-reel-lock', on);
      if (!on) { unlockContainers(); }
    }
    if (on && document.body) { lockContainers(); }
  }

  // 'locked' / 'page': bloquear el gesto. 'free': otro scroll (p. ej. comentarios).
  function scrollOwner(node) {
    var el = node && node.nodeType === 1 ? node : node && node.parentElement;
    for (; el && el !== document.body && el !== root; el = el.parentElement) {
      if (el.hasAttribute(LOCK_ATTR)) { return 'locked'; }
      if (isScrollable(el)) { return 'free'; }
    }
    return 'page';
  }

  function onScrollGesture(e) {
    if (!reelLockOn || !e.cancelable) { return; }
    if (scrollOwner(e.target) !== 'free') { e.preventDefault(); }
  }

  function onScroll(e) {
    if (!reelLockOn) { return; }
    var el = e.target;
    if (el && el.nodeType === 1 && el.hasAttribute(LOCK_ATTR)) {
      var top = Number(el.getAttribute(LOCK_ATTR)) || 0;
      if (Math.abs(el.scrollTop - top) > 1) { el.scrollTop = top; }
    }
  }

  // --------------------------------------------------------------------- ciclo

  function reportStats() {
    var hidden = document.querySelectorAll('[' + HIDDEN_ATTR + ']').length;
    var key = hidden + '|' + reelLockOn + '|' + location.pathname;
    if (key === lastStats) { return; }
    lastStats = key;
    post({ type: 'stats', hidden: hidden, reelLock: reelLockOn, path: location.pathname });
  }

  function run() {
    timer = null;
    if (!document.body) { return; }
    ensureStyleAttached();
    if (cfg.enabled) {
      hideSelectors();
      if (rules().hideSponsored) { hideSponsored(); }
    }
    updateReelLock();
    reportStats();
  }

  // Como mucho una pasada cada DEBOUNCE_MS: si Instagram muta el DOM sin parar
  // (vídeos, contadores), un debounce puro no llegaría a ejecutarse nunca.
  function schedule() {
    if (timer === null) { timer = setTimeout(run, DEBOUNCE_MS); }
  }

  function start() {
    if (started) { return; }
    started = true;
    installStyles();
    patchHistory();
    window.addEventListener('touchmove', onScrollGesture, { capture: true, passive: false });
    window.addEventListener('wheel', onScrollGesture, { capture: true, passive: false });
    document.addEventListener('scroll', onScroll, true);
    onRouteChange();
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', ready);
    } else {
      ready();
    }
  }

  function ready() {
    if (readyDone) { return; }
    readyDone = true;
    new MutationObserver(schedule).observe(root, { childList: true, subtree: true });
    run();
  }

  function update(newConfig) {
    cfg = newConfig || cfg;
    window.__RB_CONFIG = cfg;
    unhideAll();
    unlockContainers();
    reelLockOn = false;
    root.classList.remove('rb-reel-lock');
    installStyles();
    lastPath = null;
    lastStats = '';
    onRouteChange();
    run();
  }

  // Panel de depuración: resalta en rojo durante 3 s lo que casa con `sel`.
  function test(sel) {
    var nodes;
    try { nodes = document.querySelectorAll(sel); } catch (e) {
      return { ok: false, error: String((e && e.message) || e) };
    }
    var max = Math.min(nodes.length, 50);
    for (var i = 0; i < max; i++) {
      (function (el) {
        var prev = el.style.getPropertyValue('outline');
        el.style.setProperty('outline', '3px solid red', 'important');
        setTimeout(function () {
          if (prev) { el.style.setProperty('outline', prev); } else { el.style.removeProperty('outline'); }
        }, 3000);
      })(nodes[i]);
    }
    return { ok: true, count: nodes.length };
  }

  window.__rb = {
    start: start,
    ready: ready,
    update: update,
    test: test,
    isBlockedPath: isBlockedPath,
    isSingleReel: isSingleReel,
    stats: function () {
      return {
        hidden: document.querySelectorAll('[' + HIDDEN_ATTR + ']').length,
        reelLock: reelLockOn,
        path: location.pathname
      };
    }
  };
})();
