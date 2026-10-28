{{flutter_js}}
{{flutter_build_config}}

// Dairee's own service worker keeps the app's shell (see server/site.mjs), so
// the app opens without a signal and says so. It never keeps API answers.
if ('serviceWorker' in navigator) {
  window.addEventListener('load', function () {
    navigator.serviceWorker.register('sw.js', { scope: './' }).catch(function () {});
  });
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
  },
});
