import test from 'node:test';
import assert from 'node:assert/strict';
import { navigateTarget, appLink } from '../link.mjs';

const bases = ['https://manotu.app/nav/?', 'https://manotu.app/nav?', 'manotu://navigate?', 'manotu://navigate/?'];

test('valid links', () => {
  for (const b of bases) {
    assert.deepEqual(navigateTarget(b + 'lat=3.1301&lng=101.6712'), { lat: '3.1301', lng: '101.6712', label: '' });
    assert.deepEqual(navigateTarget(b + 'lng=-180&lat=-90&label=Kedai%20Ali%20%26%20Anak%20(No.%205)%2C%20Jln%20A%2F1%3A%20%40%23-'),
      { lat: '-90', lng: '-180', label: 'Kedai Ali & Anak (No. 5), Jln A/1: @#-' });
  }
  assert.equal(navigateTarget('manotu://navigate?lat=0&lng=0.123456').lng, '0.123456');
  assert.equal(navigateTarget('manotu://navigate?lat=1&lng=2&label=' + encodeURIComponent('Café 東京 தமிழ்')).label, 'Café 東京 தமிழ்');
  assert.equal(navigateTarget('manotu://navigate?lat=1&lng=2&label=' + 'a'.repeat(60)).label.length, 60);
});

test('coordinate rules', () => {
  for (const [lat, lng] of [['90.0001', '0'], ['-90.1', '0'], ['0', '180.1'], ['0', '-181'], ['1e1', '0'], ['+3.1', '0'], ['3.1234567', '0'],
    ['3.', '0'], ['.5', '0'], ['03.1', '0'], ['abc', '0'], ['', '0'], ['0x10', '0'], ['NaN', '0'], ['Infinity', '0'], ['3,1', '0'], ['1000', '0']])
    assert.equal(navigateTarget(`manotu://navigate?lat=${lat}&lng=${lng}`), null, `${lat},${lng}`);
});

test('parameter rules', () => {
  for (const q of ['lat=1', 'lng=1', 'lat=1&lat=1&lng=2', 'lat=1&lng=2&lng=2', 'lat=1&lng=2&label=A&label=B', 'lat=1&lng=2&extra=1', 'lat=1&lng=2&',
    'lat=1&lng=2&id=w1', 'LAT=1&lng=2', 'lat&lng=2', '', 'lat=1&&lng=2', 'lat=1&lng=2&label=', 'lat=1&lng=2&label=%20%20'])
    assert.equal(navigateTarget('manotu://navigate?' + q), null, q);
});

test('label rules', () => {
  const bad = ['<b>', 'a%3Cb', 'a%3Eb', 'a%0Ab', 'a%0Db', 'a%09b', 'a%00b', 'a%1Fb', 'a%7Fb', 'https%3A%2F%2Fevil.test', 'go%20to%20http%3A%2F%2Fx', 'www.evil.com',
    'a%25b', 'a%22b', 'a%3Bb', 'a%3Db', 'a%5Cb', 'a%7Cb', 'a%24b', 'a%2Bb', 'a+b', 'a%ZZb', '%E0%A4%A', 'a'.repeat(61), '%F0%9F%8D%94', 'a%E2%80%AEb'];
  for (const l of bad) assert.equal(navigateTarget('manotu://navigate?lat=1&lng=2&label=' + l), null, l);
});

test('scheme, host, path, credentials, port, fragment', () => {
  const q = '?lat=1&lng=2';
  for (const link of ['http://manotu.app/nav/' + q, 'https://evil.test/nav/' + q, 'https://manotu.app.evil.test/nav/' + q, 'https://evil@manotu.app/nav/' + q,
    'https://u:p@manotu.app/nav/' + q, 'https://manotu.app:443/nav/' + q, 'https://manotu.app:8443/nav/' + q, 'https://manotu.app/p/' + q, 'https://manotu.app/nav/x' + q,
    'https://manotu.app/a/../nav/' + q, 'https://manotu.app/nav/' + q + '#k', 'https://manotu.app/nav/' + q + '\n', 'https://manotu.app/nav/ ' + q,
    'manotu://place' + q, 'manotu://navigate/x' + q, 'manotu://u@navigate' + q, 'manotu://navigate:80' + q, 'manotu://navigate' + q + '#x', 'manotu:navigate' + q,
    'javascript:alert(1)', '', 'manotu://navigate?lat=1&lng=2&label=' + 'a'.repeat(600)])
    assert.equal(navigateTarget(link), null, link);
  assert.equal(navigateTarget(undefined), null);
});

test('appLink is rebuilt from validated values and round-trips', () => {
  const t = navigateTarget('https://manotu.app/nav/?label=Kedai%20A%20%26%20B&lng=101.6712&lat=3.1301');
  const link = appLink(t);
  assert.equal(link, 'manotu://navigate?lat=3.1301&lng=101.6712&label=Kedai%20A%20%26%20B');
  assert.deepEqual(navigateTarget(link), t);
  assert.equal(appLink({ lat: '1', lng: '2', label: '' }), 'manotu://navigate?lat=1&lng=2');
});
