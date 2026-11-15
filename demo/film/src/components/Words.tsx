import React from 'react';
import {useCurrentFrame, interpolate} from 'remotion';
import {C, EASE, FPS, FONT_DISPLAY, FONT_TEXT} from '../theme';
// Per-word reveal: opacity 0-1, translateY 24-0, blur 10-0 over 0.6s, 70ms stagger. Exit 0.35s fade + 12px up.
export const Words: React.FC<{text: string; kind: 'head' | 'sub' | 'pill' | 'small'; at: number; until: number; align?: 'left' | 'right' | 'center'; size?: number}> = ({text, kind, at, until, align = 'left', size}) => {
  const frame = useCurrentFrame(); const t = frame / FPS;
  const words = text.split(' ');
  const exit = interpolate(t, [until - 0.35, until], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const style: Record<string, React.CSSProperties> = {
    head: {fontFamily: FONT_DISPLAY, fontWeight: 650, fontSize: size ?? 112, letterSpacing: '-0.02em', lineHeight: 1.05, color: C.text},
    sub: {fontFamily: FONT_DISPLAY, fontWeight: 400, fontSize: size ?? 44, lineHeight: 1.25, color: C.dim},
    pill: {fontFamily: FONT_TEXT, fontWeight: 500, fontSize: 26, letterSpacing: '0.06em', textTransform: 'uppercase', color: C.accent, border: `1px solid ${C.accent}`, borderRadius: 999, padding: '8px 22px', display: 'inline-block'},
    small: {fontFamily: FONT_DISPLAY, fontWeight: 400, fontSize: size ?? 34, color: C.dim},
  };
  return (<div style={{...style[kind], textAlign: align, opacity: 1 - exit, transform: `translateY(${-12 * exit}px)`}}>
    {words.map((w, i) => {
      const p = EASE(interpolate(t, [at + i * 0.07, at + i * 0.07 + 0.6], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'}));
      return <span key={i} style={{display: 'inline-block', opacity: p, transform: `translateY(${24 * (1 - p)}px)`, filter: `blur(${10 * (1 - p)}px)`, marginRight: '0.26em'}}>{w}</span>;
    })}</div>);
};
