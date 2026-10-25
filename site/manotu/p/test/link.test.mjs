import test from 'node:test';
import assert from 'node:assert/strict';
import { placeId } from '../link.mjs';
test('public place links only; reject private data and injected parameters', () => {
  for (const prefix of ['https://manotu.app/p/?id=', 'https://manotu.app/p?id=', 'manotu://place?id=']) {
    for (const id of ['w1106132383', 'n123', 'r42', 'c01a166b7f9c67924976aff1beb56c2cd']) assert.equal(placeId(prefix + id), id);
    for (const id of ['private:123', 'pin:1,2', '../me', '%2fme', '', 'w0', 'w123&id=n456', 'w123#key', 'w123&url=https://evil.test']) assert.equal(placeId(prefix + id), null);
  }
  for (const link of ['https://evil.test/p/?id=w123', 'https://manotu.app.evil.test/p/?id=w123', 'https://evil@manotu.app/p/?id=w123', 'http://manotu.app/p/?id=w123', 'https://manotu.app/j/?id=w123', 'manotu://event?id=w123', 'https://manotu.app:443/p/?id=w123', 'https://manotu.app/a/../p/?id=w123', 'https://manotu.app/p/?id=w123\n']) assert.equal(placeId(link), null);
});
