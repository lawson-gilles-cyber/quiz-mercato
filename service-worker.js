/* Ultimate Squad — Service Worker (PWA)
 * Stratégie : NETWORK-FIRST pour les pages et le code.
 * -> On sert TOUJOURS la dernière version en ligne quand le réseau répond.
 * -> Le cache ne sert que de secours (hors-ligne / réseau coupé).
 * Ça évite le piège des "vieilles versions affichées".
 *
 * IMPORTANT : à chaque déploiement d'une nouvelle version du site,
 * incrémenter CACHE_VERSION ci-dessous (v1 -> v2 -> v3...).
 * L'ancien cache est alors supprimé automatiquement.
 */
const CACHE_VERSION = 'us-v1';
const CACHE_NAME = 'ultimate-squad-' + CACHE_VERSION;

// Coquille minimale mise en cache à l'installation (ouverture rapide hors-ligne).
const SHELL = [
  './index.html',
  './manifest.json',
  './icon-192.png',
  './icon-512.png'
];

self.addEventListener('install', (event) => {
  // Prend la main tout de suite sur la nouvelle version.
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) =>
      cache.addAll(SHELL).catch(() => null)  // ne bloque pas si un fichier manque
    )
  );
});

self.addEventListener('activate', (event) => {
  // Supprime les anciens caches d'une version précédente.
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k))
      )
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;

  // On ne gère que le GET. Tout le reste passe directement au réseau.
  if (req.method !== 'GET') return;

  const url = new URL(req.url);

  // Ne JAMAIS mettre en cache les appels Supabase (données live : enchères,
  // budgets, classement...). On laisse passer au réseau tel quel.
  if (url.hostname.endsWith('supabase.co')) return;

  // Pour tout le reste (pages, JS, CSS, images du site) : network-first.
  event.respondWith(
    fetch(req)
      .then((res) => {
        // Met à jour le cache avec la version fraîche (secours futur).
        const copy = res.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(req, copy)).catch(() => {});
        return res;
      })
      .catch(() =>
        // Réseau indisponible -> on sert la copie en cache si elle existe.
        caches.match(req).then((hit) => hit || caches.match('./index.html'))
      )
  );
});
