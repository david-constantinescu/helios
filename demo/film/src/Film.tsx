import React from 'react';
import {AbsoluteFill, Series, useCurrentFrame, useVideoConfig, interpolate, Img, staticFile} from 'remotion';
import {BEATS, Beat} from './storyboard';
import {C, FPS, EASE} from './theme';
import {Starfield, Glow} from './components/Starfield';
import {Words} from './components/Words';
import {PhoneFrame} from './components/PhoneFrame';
import {LightTime} from './components/LightTime';
import {EndCard} from './components/EndCard';
import footage from './data/footage.json';

type Src = {kind: 'clip' | 'shot'; file: string} | null;
const pick = (ids: string[], idx: number): Src => {
  const f = (footage as any);
  const order = [ids[Math.min(idx, ids.length - 1)], ...ids]; // preferred id first, then any other available id
  for (const id of order) { if (!id) continue; if (f.clips[id]) return {kind: 'clip', file: f.clips[id]}; if (f.shots[id]) return {kind: 'shot', file: f.shots[id]}; }
  return null;
};

const BeatView: React.FC<{beat: Beat; dur: number; vertical: boolean}> = ({beat, dur, vertical}) => {
  const f = useCurrentFrame(); const {width, height} = useVideoConfig(); const t = f / FPS;
  const off = beat.start; // text times are absolute in the storyboard; rebase
  const glow = beat.glow === 'escalate' ? C.escalate : C.accent;
  const push = 1 + 0.05 * (f / (dur * FPS));
  const enter = EASE(interpolate(t, [0.2, 1.2], [0, 1], {extrapolateRight: 'clamp'}));
  const phoneW = vertical ? width * 0.62 : height * 0.36;
  const px = beat.phoneSide === 'left' ? width * 0.28 : beat.phoneSide === 'center' ? width * 0.5 : width * 0.72;
  const switchAt = dur / 2;
  const src = pick(beat.footage, t > switchAt ? 1 : 0);
  const missing = beat.footage.length ? `No footage captured (${beat.footage.join(', ')})` : undefined;
  return (<AbsoluteFill>
    <Glow color={glow} x={beat.phone ? `${(px / width) * 100}%` : '50%'} opacity={beat.glow ? 0.14 : 0.08} />
    {beat.graphic === 'lighttime' && <LightTime from={1.2} to={7} />}
    {beat.graphic === 'endcard' && <EndCard dur={dur} />}
    {beat.phone && <div style={{position: 'absolute', left: px, top: height / 2, transform: `translate(-50%,-50%) translateY(${120 * (1 - enter)}px) perspective(2400px) rotateY(${-14 + 8 * enter}deg) rotateX(${6 - 4 * enter}deg) scale(${push})`, opacity: enter}}>
      <PhoneFrame screenW={phoneW} src={src} missingLabel={missing} /></div>}
    {beat.graphic === 'icon' && <div style={{position: 'absolute', left: '50%', top: '30%', transform: 'translate(-50%,-50%)'}}><Img src={staticFile('icon-1024.png')} style={{width: 200, height: 200, borderRadius: 46}} /></div>}
    {beat.lines.map((l, i) => {
      const side = l.side ?? 'center';
      const box: React.CSSProperties = vertical
        ? {position: 'absolute', left: 60, right: 60, top: l.kind === 'head' ? 120 : 330}
        : side === 'center' ? {position: 'absolute', left: 160, right: 160, top: l.kind === 'head' ? '40%' : l.kind === 'sub' ? '58%' : '46%'}
        : {position: 'absolute', [side]: 120, width: width * 0.4, top: l.kind === 'pill' ? '66%' : l.kind === 'sub' ? '60%' : '30%'} as any;
      return <div key={i} style={box}><Words text={l.text} kind={l.kind} at={l.at - off} until={l.until - off} align={vertical || side === 'center' ? 'center' : side} size={vertical && l.kind === 'head' ? 120 : undefined} /></div>;
    })}
  </AbsoluteFill>);
};

// plan: list of [beatNumber, durationSeconds]; null = full storyboard
export const Film: React.FC<{plan?: [number, number][]; vertical?: boolean}> = ({plan, vertical = false}) => {
  const items = plan ?? BEATS.map(b => [b.n, b.end - b.start] as [number, number]);
  return (<AbsoluteFill style={{background: C.bgDeep}}><Starfield />
    <Series>{items.map(([n, d]) => { const b = BEATS.find(x => x.n === n)!;
      return <Series.Sequence key={n} durationInFrames={Math.round(d * FPS)}><BeatView beat={b} dur={d} vertical={vertical} /></Series.Sequence>; })}</Series></AbsoluteFill>);
};
export const total = (plan?: [number, number][]) => Math.round((plan ? plan.reduce((a, [, d]) => a + d, 0) : 144) * FPS);
