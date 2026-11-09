/* =====================================================================
 * consent.js — Bandeau de consentement cookies (RGPD) + Google Consent Mode v2
 * ---------------------------------------------------------------------
 * À inclure sur TOUTES les pages (jeu + pages légales), AVANT le script
 * AdSense. Il :
 *   • pose les consentements Google par défaut sur « denied » (obligatoire
 *     dans l'EEE avant tout chargement de pub personnalisée) ;
 *   • affiche un bandeau Accepter / Refuser / Personnaliser ;
 *   • mémorise le choix (localStorage, 6 mois) ;
 *   • expose window.USConsent.open() pour rouvrir le réglage (« Gérer mes
 *     cookies » en pied de page) ;
 *   • ne charge AdSense qu'APRÈS un consentement (voir us-ads.js).
 *
 * NB : pour une conformité stricte « IAB TCF », Google recommande une CMP
 * certifiée. Ce module est une base maison, honnête et fonctionnelle ; si
 * tu vises un volume important, envisage une CMP certifiée (Google en liste).
 * ===================================================================== */
(function () {
  'use strict';
  var KEY = 'us_consent_v1';
  var MAXAGE_DAYS = 180;

  // --- Google Consent Mode v2 : tout refusé par défaut ---
  window.dataLayer = window.dataLayer || [];
  function gtag(){ window.dataLayer.push(arguments); }
  window.gtag = window.gtag || gtag;
  gtag('consent', 'default', {
    ad_storage: 'denied',
    ad_user_data: 'denied',
    ad_personalization: 'denied',
    analytics_storage: 'denied',
    wait_for_update: 500
  });

  function load() {
    try {
      var raw = localStorage.getItem(KEY);
      if (!raw) return null;
      var o = JSON.parse(raw);
      if (!o || !o.ts) return null;
      if (Date.now() - o.ts > MAXAGE_DAYS * 864e5) return null; // expiré
      return o;
    } catch (e) { return null; }
  }
  function save(choice) {
    try { localStorage.setItem(KEY, JSON.stringify({ choice: choice, ts: Date.now() })); } catch (e) {}
  }

  // Applique le choix à Google Consent Mode et déclenche le chargement des pubs.
  function apply(choice) {
    var granted = (choice === 'all');
    gtag('consent', 'update', {
      ad_storage:        granted ? 'granted' : 'denied',
      ad_user_data:      granted ? 'granted' : 'denied',
      ad_personalization:granted ? 'granted' : 'denied',
      analytics_storage: granted ? 'granted' : 'denied'
    });
    // Signale aux autres scripts (us-ads.js) que le consentement est connu.
    try {
      window.USConsent.state = choice;
      document.dispatchEvent(new CustomEvent('us-consent', { detail: { choice: choice } }));
    } catch (e) {}
  }

  // --- UI du bandeau ---
  function el(tag, css, html) {
    var e = document.createElement(tag);
    if (css) e.style.cssText = css;
    if (html != null) e.innerHTML = html;
    return e;
  }
  function removeBanner() {
    var b = document.getElementById('us-consent-banner');
    if (b && b.parentNode) b.parentNode.removeChild(b);
  }
  function showBanner() {
    if (document.getElementById('us-consent-banner')) return;
    var bar = el('div', [
      'position:fixed', 'left:0', 'right:0', 'bottom:0', 'z-index:99999',
      'background:#0f1d38', 'color:#eef3ea', 'border-top:1px solid #1c3358',
      'box-shadow:0 -8px 24px rgba(0,0,0,.35)', 'padding:16px',
      'font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif', 'font-size:14px'
    ].join(';'));
    bar.id = 'us-consent-banner';
    var inner = el('div', 'max-width:980px;margin:0 auto;display:flex;gap:14px;align-items:center;flex-wrap:wrap');
    var text = el('div', 'flex:1 1 320px;line-height:1.5',
      'Nous utilisons des cookies pour faire fonctionner le jeu et, avec votre accord, afficher des ' +
      'publicités (Google AdSense). Vous pouvez accepter, refuser ou personnaliser. ' +
      '<a href="confidentialite.html" style="color:#f5c542">En savoir plus</a>.');
    var btns = el('div', 'display:flex;gap:8px;flex-wrap:wrap');

    function mkBtn(label, primary) {
      return el('button', [
        'cursor:pointer', 'border-radius:8px', 'padding:9px 16px', 'font-weight:700', 'font-size:14px',
        'border:1px solid ' + (primary ? '#f5c542' : '#1c3358'),
        'background:' + (primary ? '#f5c542' : 'transparent'),
        'color:' + (primary ? '#0a1428' : '#eef3ea')
      ].join(';'), label);
    }
    var bAll = mkBtn('Tout accepter', true);
    var bNone = mkBtn('Tout refuser', false);
    var bCustom = mkBtn('Personnaliser', false);

    bAll.onclick = function () { choose('all'); };
    bNone.onclick = function () { choose('none'); };
    bCustom.onclick = function () { showPrefs(); };

    btns.appendChild(bNone); btns.appendChild(bCustom); btns.appendChild(bAll);
    inner.appendChild(text); inner.appendChild(btns);
    bar.appendChild(inner);
    document.body.appendChild(bar);
  }

  // Panneau « Personnaliser » (simple : publicité oui/non).
  function showPrefs() {
    removeBanner();
    var ov = el('div', [
      'position:fixed', 'inset:0', 'z-index:100000', 'background:rgba(5,10,22,.72)',
      'display:flex', 'align-items:center', 'justify-content:center', 'padding:18px',
      'font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif'
    ].join(';'));
    ov.id = 'us-consent-prefs';
    var card = el('div', 'max-width:460px;width:100%;background:#0f1d38;border:1px solid #1c3358;border-radius:14px;padding:20px;color:#eef3ea');
    card.innerHTML =
      '<h3 style="margin:0 0 10px;font-size:1.1rem">Préférences de cookies</h3>' +
      '<div style="display:flex;gap:10px;align-items:flex-start;margin:14px 0;opacity:.8">' +
        '<input type="checkbox" checked disabled style="margin-top:3px">' +
        '<div><b>Nécessaires</b><br><span style="color:#8095b5;font-size:.9em">Indispensables au ' +
        'fonctionnement du jeu (connexion, préférences). Toujours actifs.</span></div></div>' +
      '<div style="display:flex;gap:10px;align-items:flex-start;margin:14px 0">' +
        '<input id="us-c-ads" type="checkbox" style="margin-top:3px">' +
        '<div><b>Publicité (Google AdSense)</b><br><span style="color:#8095b5;font-size:.9em">' +
        'Cookies publicitaires pour financer le jeu et personnaliser les annonces.</span></div></div>' +
      '<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:16px">' +
        '<button id="us-c-save" style="cursor:pointer;border-radius:8px;padding:9px 16px;font-weight:700;' +
        'border:1px solid #f5c542;background:#f5c542;color:#0a1428">Enregistrer</button></div>';
    ov.appendChild(card);
    document.body.appendChild(ov);
    document.getElementById('us-c-save').onclick = function () {
      var ads = document.getElementById('us-c-ads').checked;
      var el2 = document.getElementById('us-consent-prefs'); if (el2) el2.remove();
      choose(ads ? 'all' : 'none');
    };
  }

  function choose(choice) {
    save(choice);
    removeBanner();
    apply(choice);
  }

  // API publique (« Gérer mes cookies »).
  window.USConsent = {
    state: null,
    open: function () { showPrefs(); },
    // true si la pub perso est autorisée (utilisé par us-ads.js).
    adsAllowed: function () { return this.state === 'all'; }
  };

  // --- Démarrage ---
  function init() {
    var prev = load();
    if (prev && prev.choice) {
      apply(prev.choice);           // applique le choix mémorisé, pas de bandeau
    } else {
      showBanner();                 // premier passage → bandeau
    }
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
