{{flutter_js}}
{{flutter_build_config}}

// No Flutter service worker: the server revalidates every file instead,
// so a new release reaches every counter on its next reload.
// A browser profile has one durable cart and payment queue. Let a second
// tab wait for ownership instead of overwriting the first cashier's work.
if (navigator.locks) {
  const label = document.querySelector('#splash div');
  navigator.locks.request('cartunez-register', async () => {
    if (label) label.textContent = 'Opening Cartunez POS';
    await _flutter.loader.load();
    await new Promise(() => {}); // Released by the browser when this tab closes.
  });
  if (label) label.textContent = 'Waiting for the register. Close the other POS tab to continue here.';
} else {
  _flutter.loader.load();
}
