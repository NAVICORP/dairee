{{flutter_js}}
{{flutter_build_config}}

// Dairee's own service worker keeps the app's shell (see server/site.mjs), so
// the app opens without a signal and says so. It never keeps API answers.
// It is set up once the app is running, so a first visit spends its
// connection on the app alone, and is then told which files this browser
// used: they come from the browser's own cache, not the network again.
function keepShell() {
  if (!('serviceWorker' in navigator)) return;
  navigator.serviceWorker.register('sw.js', { scope: './' })
    .then(function () { return navigator.serviceWorker.ready; })
    .then(function (reg) {
      var used = performance.getEntriesByType('resource').map(function (r) { return r.name; });
      if (reg.active) reg.active.postMessage({ keep: used });
    })
    .catch(function () {});
}
if (!navigator.onLine) {
  var note = document.getElementById('boot-note');
  if (note) note.textContent = 'No connection. Opening what is saved on this device.';
}

_flutter.loader.load({
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine();
    const boot = document.getElementById('boot');
    if (boot) { boot.style.opacity = '0'; setTimeout(function () { boot.remove(); }, 300); }
    await appRunner.runApp();
    setTimeout(keepShell, 2000);
  },
});
