// Navigate links carry coordinates by design (unlike place links). Keep this grammar aligned with Android and iOS NavigateLink.
// Accepts https://manotu.app/nav[/]?lat=&lng=&label= and manotu://navigate[/]?lat=&lng=&label=.
const PREFIX = /^(?:https:\/\/manotu\.app\/nav\/?|manotu:\/\/navigate\/?)\?/i;
const COORD = /^-?(?:0|[1-9][0-9]{0,2})(?:\.[0-9]{1,6})?$/;
const LABEL_CHARS = /^[\p{L}\p{M}\p{N} .,\-#/()'&@:]+$/u;

function coord(text, limit) {
  if (!COORD.test(text)) return null;
  const n = Number(text);
  return Number.isFinite(n) && Math.abs(n) <= limit ? text : null;
}

function labelOf(encoded) {
  if (encoded.includes('+')) return null; // '+' is not an allowed label character; spaces are %20
  let text;
  try { text = decodeURIComponent(encoded); } catch { return null; }
  if (text.length === 0 || text.length > 60 || text.trim() === '') return null;
  if (!LABEL_CHARS.test(text) || /:\/\/|www\./i.test(text)) return null;
  return text;
}

// Returns { lat, lng, label } (label is '' when absent) or null when the link is invalid.
export function navigateTarget(raw) {
  if (typeof raw !== 'string' || raw.length > 512 || /\s/.test(raw) || raw.includes('#')) return null;
  const m = PREFIX.exec(raw);
  if (!m) return null;
  let url;
  try { url = new URL(raw); } catch { return null; }
  if (url.username || url.password || url.port) return null;
  const ok = (url.protocol === 'https:' && url.host === 'manotu.app' && ['/nav', '/nav/'].includes(url.pathname)) ||
    (url.protocol === 'manotu:' && url.host === 'navigate' && ['', '/'].includes(url.pathname));
  if (!ok) return null;
  const seen = new Map();
  for (const part of raw.slice(m[0].length).split('&')) {
    const i = part.indexOf('=');
    if (i < 1) return null;
    const key = part.slice(0, i);
    if (!['lat', 'lng', 'label'].includes(key) || seen.has(key)) return null;
    seen.set(key, part.slice(i + 1));
  }
  const lat = seen.has('lat') ? coord(seen.get('lat'), 90) : null;
  const lng = seen.has('lng') ? coord(seen.get('lng'), 180) : null;
  if (lat === null || lng === null) return null;
  let label = '';
  if (seen.has('label')) {
    label = labelOf(seen.get('label'));
    if (label === null) return null;
  }
  return { lat, lng, label };
}

// App hand-off rebuilt only from validated values.
export function appLink({ lat, lng, label }) {
  return `manotu://navigate?lat=${lat}&lng=${lng}` + (label ? `&label=${encodeURIComponent(label)}` : '');
}
