import { placeId } from './link.mjs';
const id = placeId(location.href);
const open = document.querySelector('#open');
if (id) {
  open.href = `manotu://place?id=${id}`;
  open.hidden = false;
  if (id === 'w1106132383') {
    document.querySelector('h1').textContent = 'Petronas Bukit Bunga';
    document.querySelector('#description').textContent = 'Eshah Filling Station · Bukit Bunga, Kelantan';
    document.title = 'Petronas Bukit Bunga · Manotu';
  }
} else {
  document.querySelector('h1').textContent = 'Pautan tidak sah · Invalid place link';
  document.querySelector('#description').textContent = 'Minta pengirim berkongsi pautan semula. Ask the sender for a new link.';
}
