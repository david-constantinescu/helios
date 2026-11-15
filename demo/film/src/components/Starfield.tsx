import React from 'react';
import {AbsoluteFill, useCurrentFrame, useVideoConfig} from 'remotion';
import {C, FPS} from '../theme';
function mulberry32(a: number) { return () => { a |= 0; a = (a + 0x6d2b79f5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
export const Starfield: React.FC<{count?: number}> = ({count = 260}) => {
  const f = useCurrentFrame(); const {width, height} = useVideoConfig();
  const rnd = mulberry32(42);
  const stars = Array.from({length: count}, () => ({x: rnd() * width, y: rnd() * height, o: 0.2 + rnd() * 0.4, r: 0.6 + rnd() * 1.2, tw: rnd() < 0.05, ph: rnd() * 6}));
  const t = f / FPS;
  return (<AbsoluteFill style={{background: `radial-gradient(ellipse at 50% 40%, ${C.bg}, ${C.bgDeep})`}}>
    <svg width={width} height={height} style={{position: 'absolute'}}>
      {stars.map((s, i) => <circle key={i} cx={(s.x + t * 4) % width} cy={s.y} r={s.r}
        fill="#fff" opacity={s.tw ? s.o * (0.6 + 0.4 * Math.sin(t * 2 + s.ph)) : s.o} />)}
    </svg></AbsoluteFill>);
};
export const Glow: React.FC<{color: string; x?: string; y?: string; size?: number; opacity?: number}> = ({color, x = '50%', y = '50%', size = 1100, opacity = 0.08}) => (
  <div style={{position: 'absolute', left: x, top: y, width: size, height: size, transform: 'translate(-50%,-50%)', borderRadius: '50%',
    background: `radial-gradient(circle, ${color} 0%, transparent 65%)`, opacity}} />);
