// Public identifiers only; keep this grammar aligned with Android and iOS PlaceLink.
export function placeId(raw) {
  if (raw.length > 256 || /\s/.test(raw)) return null;
  // URL normalizes default ports and dot segments; reject those before parsing as native apps do.
  if (!/^(?:https:\/\/manotu\.app\/p\/?|manotu:\/\/place\/?)\?id=/i.test(raw)) return null;
  let url;
  try { url = new URL(raw); } catch { return null; }
  if (url.username || url.password || url.port || raw.includes('#')) return null;
  const supported = (url.protocol === 'https:' && url.host === 'manotu.app' && ['/p', '/p/'].includes(url.pathname)) ||
    (url.protocol === 'manotu:' && url.host === 'place' && ['', '/'].includes(url.pathname));
  if (!supported || !/^\?id=(?:[nwr][1-9][0-9]{0,19}|c[0-9a-f]{32})$/.test(url.search)) return null;
  return url.search.slice(4);
}
