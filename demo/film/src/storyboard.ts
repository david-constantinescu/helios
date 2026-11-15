// Brief section 6.5. Text is EXACT. Times in seconds, absolute for the 2:24 main film.
export type Line = {text: string; kind: 'head' | 'sub' | 'pill' | 'small'; at: number; until: number; side?: 'left' | 'right' | 'center'};
export type Beat = {
  n: number; id: string; start: number; end: number;
  glow?: 'accent' | 'escalate';
  phone: boolean; phoneSide?: 'left' | 'right' | 'center';
  footage: string[];           // capture clip ids, e.g. A05 (resolved by src/data/footage.json)
  graphic?: 'lighttime' | 'dataflow' | 'hazardrings' | 'docfan' | 'lock' | 'crops' | 'icon' | 'endcard';
  lines: Line[];
};
export const BEATS: Beat[] = [
  {n:1,id:'b01',start:0,end:8,phone:false,footage:[],graphic:'lighttime',lines:[
    {text:'Mars is 3–22 light-minutes away.',kind:'head',at:0.8,until:4.6,side:'center'},
    {text:'Each way.',kind:'head',at:4.6,until:8,side:'center'}]},
  {n:2,id:'b02',start:8,end:14,phone:false,footage:[],lines:[
    {text:'Nobody can phone a flight surgeon.',kind:'head',at:8.3,until:14,side:'center'}]},
  {n:3,id:'b03',start:14,end:22,phone:false,footage:[],graphic:'icon',lines:[
    {text:'Crew Health Hub',kind:'head',at:15.2,until:22,side:'center'},
    {text:'Your own flight surgeon, when Earth is too far to call.',kind:'sub',at:16.6,until:22,side:'center'}]},
  {n:4,id:'b04',start:22,end:32,phone:true,phoneSide:'right',footage:['A21','A05'],lines:[
    {text:'Your health, at a glance.',kind:'head',at:22.8,until:32,side:'left'}]},
  {n:5,id:'b05',start:32,end:46,phone:true,phoneSide:'right',footage:['A03','A04'],graphic:'dataflow',lines:[
    {text:'Always in sync with Apple Health.',kind:'head',at:32.6,until:46,side:'left'},
    {text:'Not just once. Continuously.',kind:'sub',at:34.2,until:46,side:'left'},
    {text:'LIVE',kind:'pill',at:38,until:46,side:'left'}]},
  {n:6,id:'b06',start:46,end:58,phone:true,phoneSide:'left',footage:['A10'],lines:[
    {text:'Compared with you.',kind:'head',at:46.6,until:58,side:'right'},
    {text:'Not a textbook.',kind:'sub',at:48,until:58,side:'right'}]},
  {n:7,id:'b07',start:58,end:72,phone:true,phoneSide:'right',footage:['A08','A09'],lines:[
    {text:'See what changed. And why.',kind:'head',at:58.6,until:72,side:'left'}]},
  {n:8,id:'b08',start:72,end:80,phone:true,phoneSide:'left',footage:['A06'],lines:[
    {text:'A one-minute daily check-in.',kind:'head',at:72.5,until:80,side:'right'}]},
  {n:9,id:'b09',start:80,end:90,phone:true,phoneSide:'center',footage:['A11'],graphic:'hazardrings',lines:[
    {text:'Five hazards. One view.',kind:'head',at:80.5,until:90,side:'left'}]},
  {n:10,id:'b10',start:90,end:106,glow:'escalate',phone:true,phoneSide:'right',footage:['A12'],lines:[
    {text:'When it matters,',kind:'head',at:90.8,until:98,side:'left'},
    {text:'it escalates.',kind:'head',at:98,until:106,side:'left'}]},
  {n:11,id:'b11',start:106,end:116,phone:true,phoneSide:'left',footage:['A13','A14'],lines:[
    {text:'Clear steps. Who to call.',kind:'head',at:106.6,until:116,side:'right'}]},
  {n:12,id:'b12',start:116,end:124,phone:true,phoneSide:'left',footage:['A19'],graphic:'docfan',lines:[
    {text:'One page for the flight surgeon.',kind:'head',at:116.5,until:124,side:'right'}]},
  {n:13,id:'b13',start:124,end:130,phone:true,phoneSide:'right',footage:['A18','A20'],graphic:'lock',lines:[
    {text:'Offline-first. Your data stays on your device.',kind:'head',at:124.4,until:130,side:'left'}]},
  {n:14,id:'b14',start:130,end:135,phone:false,footage:[],graphic:'crops',lines:[
    {text:'Honest by design.',kind:'head',at:130.2,until:135,side:'center'}]},
  {n:15,id:'b15',start:135,end:138,phone:false,footage:[],lines:[
    {text:'NEXT',kind:'pill',at:135.1,until:138,side:'center'},
    {text:'Next: habitat sensors · crew console · Mission Control',kind:'small',at:135.3,until:138,side:'center'}]},
  {n:16,id:'b16',start:138,end:144,phone:false,footage:[],graphic:'endcard',lines:[]},
];
export const END_CARD = {
  title:'Crew Health Hub',
  sub:'Your own flight surgeon, when Earth is too far to call.',
  built:'Built for the NASA Space Apps Challenge 2026',
  disclaimer:'Decision support only. Not a medical device.',
};
// Cut compositions: [beat number, duration seconds] (beats are trimmed from their start; holds kept >=1.5s)
export const CUT60: [number, number][] = [[1,5],[3,6],[5,9],[7,9],[10,11],[12,6],[14,5],[16,6]];       // 57 s
export const TEASER: [number, number][] = [[3,5],[5,7],[7,7],[10,7],[16,4]];                           // 30 s
