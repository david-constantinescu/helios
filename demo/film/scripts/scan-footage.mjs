// Maps clip ids (A01..A22) to files in public/clips and public/shots. Run: npm run scan
import fs from 'fs';
const out = {clips: {}, shots: {}};
for (const [dir, key] of [['public/clips','clips'],['public/shots','shots']]) {
  if (!fs.existsSync(dir)) continue;
  for (const f of fs.readdirSync(dir)) { const m = f.match(/^(A\d\d)/); if (m && !out[key][m[1]]) out[key][m[1]] = f; }
}
fs.writeFileSync('src/data/footage.json', JSON.stringify(out, null, 2));
console.log(out);
