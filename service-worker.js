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
const CACHE_VERSION = 'us-v16';
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

// ---------- Web Push : notification reçue (même app fermée) ----------
self.addEventListener('push', (event) => {
  let data = { title: 'Ultimate Squad', body: 'Nouvelle activité sur le mercato', url: '/' };
  try { if (event.data) data = Object.assign(data, event.data.json()); } catch (e) {}
  event.waitUntil(
    self.registration.showNotification(data.title, {
      body: data.body,
      icon: './icon-192.png',
      badge: './icon-192.png',
      data: { url: data.url || '/' },
      vibrate: [80, 40, 80]
    })
  );
});

// Clic sur la notification -> ouvre/réveille l'app sur la bonne page
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const target = (event.notification.data && event.notification.data.url) || '/';
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((wins) => {
      for (const w of wins) { if ('focus' in w) return w.focus(); }
      if (self.clients.openWindow) return self.clients.openWindow(target);
    })
  );
});
