// Rune Weaver Service Worker for Standalone Mobile PWA Web Push.

// Fail closed to the inbox when payload carries cross-origin or non-http(s) URLs.
function resolveSafeTargetUrl(raw) {
  const fallback = '/#approvals';
  if (typeof raw !== 'string' || raw.trim() === '') return fallback;
  const trimmed = raw.trim();
  if (trimmed.startsWith('/#')) return trimmed;
  try {
    const parsed = new URL(trimmed, self.location.origin);
    const isHttp = parsed.protocol === 'http:' || parsed.protocol === 'https:';
    if (isHttp && parsed.origin === self.location.origin) return trimmed;
  } catch {
    return fallback;
  }
  return fallback;
}

self.addEventListener('push', (event) => {
  if (!event.data) return;
  let payload;
  try {
    payload = event.data.json();
  } catch {
    payload = { title: 'Rune Weaver', body: event.data.text() };
  }

  const title = payload.title || 'Rune Weaver';
  const options = {
    body: payload.body || '',
    icon: '/apple-touch-icon.png',
    badge: '/favicon-32x32.png',
    tag: payload.tag || 'rune-weaver-alert',
    renotify: true,
    data: {
      url: resolveSafeTargetUrl(payload.url),
    },
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const targetUrl = resolveSafeTargetUrl(event.notification.data && event.notification.data.url);

  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((windowClients) => {
      for (const client of windowClients) {
        if (client.url.includes(self.location.origin) && 'focus' in client) {
          if ('navigate' in client) {
            client.navigate(targetUrl);
          }
          return client.focus();
        }
      }
      if (clients.openWindow) {
        return clients.openWindow(targetUrl);
      }
    }),
  );
});
