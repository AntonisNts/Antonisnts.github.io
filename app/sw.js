/* PayStamp service worker.
   ---------------------------------------------------------------------------
   This file exists for ONE reason: a browser will not deliver a push
   notification without one. It does not cache anything, and it must not start.

   PayStamp is a single HTML file that is deployed by overwriting it. A service
   worker that cached the app would keep serving whichever version it had cached
   until it decided otherwise -- so a school could be looking at last week's app
   while the database had moved on, with no way to tell and nothing they could
   do about it. That failure is silent, it is hard to explain over the phone,
   and it would be caused entirely by code added for notifications.

   So: no fetch handler. Every request goes to the network exactly as it does
   without a service worker.
*/

// Take over as soon as a new version is installed, rather than waiting for
// every tab to close. There is no cached state to migrate, so there is nothing
// for the old one to finish.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

self.addEventListener("push", (event) => {
  // A push with no payload still has to show something. Browsers require a
  // notification for every push received, and "PayStamp" alone is better than
  // the browser's own "This site has been updated in the background".
  let d = { title: "PayStamp", body: "", url: "/app/" };
  try {
    if (event.data) d = Object.assign(d, event.data.json());
  } catch (e) { /* not JSON: keep the default */ }

  event.waitUntil(self.registration.showNotification(d.title, {
    body: d.body || "",
    icon: "/app/icon-192.png",
    badge: "/app/icon-192.png",
    // Same tag means a second announcement replaces the first rather than
    // stacking. A parent does not want eleven rows from one school.
    tag: d.tag || "paystamp",
    renotify: true,
    data: { url: d.url || "/app/" },
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || "/app/";
  event.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    // If PayStamp is already open, focus it instead of opening a second copy.
    for (const c of all) {
      if (c.url.indexOf("/app/") >= 0 && "focus" in c) {
        try { await c.navigate(url); } catch (e) { /* cross-origin or unsupported */ }
        return c.focus();
      }
    }
    if (self.clients.openWindow) return self.clients.openWindow(url);
  })());
});
