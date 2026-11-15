import React from 'react';
import {useCurrentFrame, interpolate, useVideoConfig} from 'remotion';
import {C, EASE, FPS, FONT_TEXT} from '../theme';
// Earth ... Mars with an accent pulse + trail travelling between. Pure graphic; no data claims.
export const LightTime: React.FC<{from: number; to: number}> = ({from, to}) => {
  const f = useCurrentFrame() / FPS; const {width, height} = useVideoConfig();
  const x0 = width * 0.14, x1 = width * 0.86, y = height * 0.72;
  const p = EASE(interpolate(f, [from, to], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'}));
  const px = x0 + (x1 - x0) * p;
  const lab = {fontFamily: FONT_TEXT, fontSize: 24, letterSpacing: '0.06em', textTransform: 'uppercase', fill: C.dim} as const;
  return (<svg width={width} height={height} style={{position: 'absolute'}}>
    <defs><linearGradient id="trail"><stop offset="0" stopColor={C.accent} stopOpacity="0" /><stop offset="1" stopColor={C.accent} stopOpacity="0.9" /></linearGradient></defs>
    <line x1={x0} y1={y} x2={x1} y2={y} stroke={C.line} strokeWidth={1} strokeDasharray="4 10" />
    <rect x={x0} y={y - 1.5} width={Math.max(0, px - x0)} height={3} fill="url(#trail)" />
    <circle cx={x0} cy={y} r={16} fill={C.accent} /><circle cx={x0} cy={y} r={34} fill={C.accent} opacity={0.12} />
    <circle cx={x1} cy={y} r={12} fill={C.warm} /><circle cx={x1} cy={y} r={28} fill={C.warm} opacity={0.12} />
    <circle cx={px} cy={y} r={9} fill="#fff" /><circle cx={px} cy={y} r={26} fill={C.accent} opacity={0.25} />
    <text x={x0} y={y + 64} textAnchor="middle" {...lab}>Earth</text><text x={x1} y={y + 64} textAnchor="middle" {...lab}>Mars</text>
  </svg>);
};
