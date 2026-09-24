// Fails if any TRACKED file contains a credentialed RPC endpoint or a private-key-shaped value.
//
//   node script/check-no-secrets.mjs
//
// WHY: on 2026-09-23 an archive-probe evidence file carrying Joshua's Alchemy key was committed to this
// PUBLIC repository. The key must be rotated, and the probe can no longer serialize a URL (see
// script/test-probe-redaction.mjs). This is the independent last gate: it scans what git would publish,
// so a secret introduced by ANY path, not only the probe, fails CI before it is pushed further.
//
// It prints the file and line number of a hit, NEVER the matched value.

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const PATTERNS = [
  { name: 'Alchemy endpoint with a key', re: /g\.alchemy\.com\/v2\/[A-Za-z0-9_-]{16,}/ },
  { name: 'Infura endpoint with a key', re: /infura\.io\/v3\/[A-Za-z0-9]{24,}/ },
  { name: 'QuickNode endpoint with a key', re: /quiknode\.pro\/[A-Za-z0-9]{24,}/ },
  { name: 'dRPC endpoint with a key', re: /drpc\.org\/[^\s"']*dkey=[A-Za-z0-9_-]{16,}/ },
  { name: 'apikey query parameter', re: /[?&](api[_-]?key|apikey|key)=[A-Za-z0-9_-]{20,}/i },
  { name: '32-byte hex private key assignment', re: /(PRIVATE_KEY|private_key|privateKey)\s*[:=]\s*["']?0x[0-9a-fA-F]{64}/ },
];

// EVERY tracked file, with no exemption by name. The first version exempted this file and the probe
// redaction test by filename, which contradicted "any tracked file" and left the test file, which builds
// endpoint-shaped material on purpose, as the most plausible place for a real copied key to go unscanned.
// The Codex diff review (round 4) caught it. Neither file needs an exemption: this file's patterns are
// regex source text, not literal endpoints, and the tests build their fake values at runtime. Entries that
// are not readable text (the lib/forge-std gitlink, binaries) are skipped by CONTENT below, not by path.
const files = execFileSync('git', ['ls-files'], { encoding: 'utf8' }).split('\n').filter(Boolean);

const hits = [];
for (const f of files) {
  let text;
  try { text = readFileSync(f, 'utf8'); } catch { continue; }
  if (text.includes('\u0000')) continue; // binary
  const lines = text.split('\n');
  lines.forEach((line, i) => {
    for (const p of PATTERNS) {
      const m = line.match(p.re);
      if (!m) continue;
      // A key-shaped value made of one or two repeated hex digits (0x000...0, 0x111...1) is a template
      // placeholder, not a credential. Skipping by VALUE rather than allowlisting a file means a real key
      // later pasted into the same template is still caught.
      const hex = m[0].match(/0x([0-9a-fA-F]{64})/);
      if (hex && new Set(hex[1].toLowerCase()).size <= 2) continue;
      hits.push(`${f}:${i + 1}  ${p.name}`);
    }
  });
}

if (hits.length) {
  console.error(`SECRET SCAN FAILED: ${hits.length} hit(s). Values are not printed.`);
  for (const h of hits) console.error(`  ${h}`);
  console.error('\nRemove the value, ROTATE the credential (assume it was scraped), and re-run.');
  process.exit(1);
}
console.log(`secret scan: ${files.length} tracked files, no credentialed endpoints or key assignments.`);
