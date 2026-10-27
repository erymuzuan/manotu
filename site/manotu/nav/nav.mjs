import { navigateTarget, appLink } from './link.mjs';
const target = navigateTarget(location.href);
const $ = (s) => document.querySelector(s);
if (target) {
  $('#valid').hidden = false;
  $('#invalid').hidden = true;
  $('#label').textContent = target.label || 'Destinasi dikongsi · Shared destination';
  $('#coords').textContent = `${target.lat}, ${target.lng}`;
  $('#open').href = appLink(target);
  document.title = (target.label ? target.label + ' · ' : '') + 'Navigasi · Manotu';
}
