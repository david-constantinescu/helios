// Generates out/captions.srt from src/storyboard.ts text (run with: npx tsx not needed; parses the TS via regex)
import fs from 'fs';
const src = fs.readFileSync('src/storyboard.ts','utf8');
const re = /\{text:'((?:[^'\\]|\\.)*)',kind:'(\w+)',at:([\d.]+),until:([\d.]+)/g;
const t = s => { const ms=Math.round(s*1000); const p=(n,l=2)=>String(n).padStart(l,'0'); return `${p(Math.floor(ms/3600000))}:${p(Math.floor(ms/60000)%60)}:${p(Math.floor(ms/1000)%60)},${p(ms%1000,3)}`; };
let m, i = 1, o = '';
while ((m = re.exec(src))) { if (m[2]==='pill'&&m[1]==='LIVE'||m[2]==='pill'&&m[1]==='NEXT') {} o += `${i++}\n${t(+m[3])} --> ${t(+m[4])}\n${m[1].replace(/\\'/g,"'")}\n\n`; }
const end = "Crew Health Hub\nYour own flight surgeon, when Earth is too far to call.\nBuilt for the NASA Space Apps Challenge 2026\nDecision support only. Not a medical device.";
o += `${i++}\n${t(139)} --> ${t(144)}\n${end}\n`;
fs.mkdirSync('../out',{recursive:true}); fs.writeFileSync('../out/captions.srt', o); console.log('wrote ../out/captions.srt', i-1, 'cues');
