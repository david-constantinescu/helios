// Helios service worker: shows pushed alerts and opens the hub page when one is tapped.
self.addEventListener('push', (event) => {
  let d = {};
  try { d = event.data ? event.data.json() : {}; } catch (e) { d = { title: 'Helios', body: event.data && event.data.text() }; }
  event.waitUntil(self.registration.showNotification(d.title || 'Helios', {
    body: d.body || '', tag: d.tag || 'helios', renotify: true, icon: '/icon-192.png', badge: '/icon-192.png',
    requireInteraction: !!d.urgent, data: { url: '/' }
  }));
});
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(clients.matchAll({ type: 'window' }).then((list) => {
    for (const c of list) { if ('focus' in c) return c.focus(); }
    return clients.openWindow('/');
  }));
});
