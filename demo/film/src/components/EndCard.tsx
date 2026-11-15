import React from 'react';
import {AbsoluteFill, Img, staticFile, spring, useCurrentFrame, useVideoConfig, interpolate} from 'remotion';
import {C, FPS, FONT_DISPLAY, FONT_TEXT, SPRING_TITLE} from '../theme';
import {END_CARD} from '../storyboard';
export const EndCard: React.FC<{dur: number}> = ({dur}) => {
  const f = useCurrentFrame(); const {fps} = useVideoConfig();
  const s = spring({frame: f, fps, config: SPRING_TITLE});
  const fade = interpolate(f, [dur * FPS - 45, dur * FPS], [1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const txt = interpolate(f, [20, 50], [0, 1], {extrapolateRight: 'clamp'});
  return (<AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', opacity: fade}}>
    {/* icon: public/icon-1024.png copied from the app's AppIcon.appiconset (see README) */}
    <Img src={staticFile('icon-1024.png')} style={{width: 220, height: 220, borderRadius: 50, transform: `scale(${s})`, boxShadow: '0 30px 80px rgba(0,0,0,.6)'}} />
    <div style={{opacity: txt, textAlign: 'center', marginTop: 40}}>
      <div style={{fontFamily: FONT_DISPLAY, fontWeight: 650, fontSize: 96, letterSpacing: '-0.02em', color: C.text}}>{END_CARD.title}</div>
      <div style={{fontFamily: FONT_DISPLAY, fontSize: 40, color: C.dim, marginTop: 10}}>{END_CARD.sub}</div>
      <div style={{fontFamily: FONT_TEXT, fontSize: 28, color: C.dim, marginTop: 40}}>{END_CARD.built}</div>
      <div style={{fontFamily: FONT_TEXT, fontSize: 22, color: C.unknown, marginTop: 14}}>{END_CARD.disclaimer}</div>
    </div></AbsoluteFill>);
};
