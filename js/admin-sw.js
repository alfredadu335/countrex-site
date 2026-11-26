// Countrex Admin: installable shell only. Never caches data or logins.
self.addEventListener("install",function(){self.skipWaiting()});
self.addEventListener("activate",function(e){e.waitUntil(self.clients.claim())});
self.addEventListener("fetch",function(e){
  if(e.request.mode==="navigate"){
    e.respondWith(fetch(e.request).catch(function(){return new Response("<meta name=viewport content='width=device-width'><body style='font-family:sans-serif;padding:32px'><h2>You are offline</h2><p>Countrex Admin needs the internet. Reconnect and reopen.</p>",{headers:{"Content-Type":"text/html"}})}));
  }
});
