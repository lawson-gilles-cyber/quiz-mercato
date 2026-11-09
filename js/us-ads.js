/* =====================================================================
 * us-ads.js — Chargement d'AdSense conditionné au consentement.
 * ---------------------------------------------------------------------
 * Dépend de consent.js (doit être inclus AVANT).
 *
 * À COMPLÉTER avant mise en ligne :
 *   • AD_CLIENT : ton identifiant éditeur AdSense, de la forme "ca-pub-XXXXXXXXXXXXXXXX".
 *   • Les data-ad-slot des emplacements <ins> (voir us-ad-slot).
 *
 * Fonctionnement :
 *   • N'injecte le script AdSense qu'une fois le consentement connu.
 *   • Avec Consent Mode v2, Google peut servir des pubs NON personnalisées même
 *     sans consentement « all » ; ici, par prudence RGPD, on ne charge le script
 *     QUE si l'utilisateur a accepté (choix « Tout accepter »). Adapte si tu veux
 *     des pubs non personnalisées en cas de refus (autorisé par Consent Mode).
 * ===================================================================== */
(function () {
  'use strict';

  // >>> À COMPLÉTER <<<
  var AD_CLIENT = 'ca-pub-XXXXXXXXXXXXXXXX'; // ← ton ID AdSense

  var loaded = false;
  function loadAdSense() {
    if (loaded) return;
    if (!/^ca-pub-\d{16}$/.test(AD_CLIENT)) {
      console.warn('[ads] AD_CLIENT non configuré : AdSense non chargé.');
      return;
    }
    loaded = true;
    var s = document.createElement('script');
    s.async = true;
    s.src = 'https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js?client=' + AD_CLIENT;
    s.crossOrigin = 'anonymous';
    document.head.appendChild(s);
    // Active les blocs <ins class="adsbygoogle"> déjà présents.
    document.querySelectorAll('ins.adsbygoogle').forEach(function () {
      try { (window.adsbygoogle = window.adsbygoogle || []).push({}); } catch (e) {}
    });
  }

  function maybeLoad() {
    try {
      if (window.USConsent && window.USConsent.adsAllowed()) loadAdSense();
    } catch (e) {}
  }

  // Charge dès qu'un consentement « all » est donné…
  document.addEventListener('us-consent', function (e) {
    if (e && e.detail && e.detail.choice === 'all') loadAdSense();
  });
  // …ou si le choix était déjà mémorisé au chargement de la page.
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', maybeLoad);
  else maybeLoad();

  // Helper : crée un emplacement d'annonce responsive dans un conteneur donné.
  // Usage : USAds.slot('monConteneur', '1234567890')
  window.USAds = {
    client: AD_CLIENT,
    slot: function (containerId, adSlotId) {
      var c = document.getElementById(containerId);
      if (!c || !/^\d+$/.test(adSlotId || '')) return;
      var ins = document.createElement('ins');
      ins.className = 'adsbygoogle';
      ins.style.cssText = 'display:block';
      ins.setAttribute('data-ad-client', AD_CLIENT);
      ins.setAttribute('data-ad-slot', adSlotId);
      ins.setAttribute('data-ad-format', 'auto');
      ins.setAttribute('data-full-width-responsive', 'true');
      c.appendChild(ins);
      try {
        if (window.USConsent && window.USConsent.adsAllowed()) {
          (window.adsbygoogle = window.adsbygoogle || []).push({});
        }
      } catch (e) {}
    }
  };
})();
