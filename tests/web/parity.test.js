'use strict';
// bs_human_ago() in brainsaw/lib.php and humanAgo() in brainsaw/js/autorefresh.js
// must give identical output. Needs php on PATH; fails (never skips) without it.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { humanAgo } = require('../../brainsaw/js/autorefresh.js');

const VALUES = [-3700, -61, -5, 0, 59, 60, 3599, 3600, 86399, 86400, 200000];
const LIB = path.resolve(__dirname, '../../brainsaw/lib.php');

test('humanAgo matches bs_human_ago() from lib.php', () => {
  let out;
  try {
    const code = `require ${JSON.stringify(LIB)}; foreach (${JSON.stringify(VALUES)} as $v) echo bs_human_ago($v), "\\n";`;
    out = execFileSync('php', ['-r', code], { encoding: 'utf8' });
  } catch (e) {
    assert.fail('parity test needs php on PATH and a loadable lib.php: ' + e.message);
  }
  assert.deepEqual(out.trimEnd().split('\n'), VALUES.map(humanAgo));
});
