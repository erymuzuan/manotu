for (const section of document.querySelectorAll('[data-share-url]')) {
  const data = { title: section.dataset.shareTitle, text: section.dataset.shareText, url: section.dataset.shareUrl };
  const status = section.querySelector('.share-status');
  const native = section.querySelector('[data-native-share]');
  const copy = section.querySelector('[data-copy-link]');
  if (typeof navigator.share === 'function') {
    native.hidden = false;
    native.addEventListener('click', async () => {
      try { await navigator.share(data); status.textContent = ''; }
      catch (error) { if (error.name !== 'AbortError') status.textContent = 'Sharing unavailable. Please use one of the links below.'; }
    });
  }
  copy.hidden = false;
  copy.addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(data.url); status.textContent = 'Pautan disalin · Link copied'; }
    catch { status.textContent = `Copy this link: ${data.url}`; }
  });
}
