import React from 'react';
import {OffthreadVideo, Img, staticFile} from 'remotion';
import {C, SCREEN_ASPECT, FONT_TEXT} from '../theme';
// Code-drawn generic phone. Screen aspect == simulator screen (402x874 pt). Never stretched (objectFit: cover on matching ratio).
export const PhoneFrame: React.FC<{screenW: number; src?: {kind: 'clip' | 'shot'; file: string; startFrom?: number} | null; missingLabel?: string; children?: React.ReactNode}> = ({screenW, src, missingLabel, children}) => {
  const screenH = screenW / SCREEN_ASPECT; const bez = screenW * 0.04;
  const W = screenW + bez * 2, H = screenH + bez * 2;
  return (<div style={{position: 'relative', width: W, height: H, borderRadius: W * 0.13, padding: bez, boxSizing: 'border-box',
    background: 'linear-gradient(135deg,#3A3F4A,#8A8F99 50%,#2A2E36)', boxShadow: '0 60px 120px rgba(0,0,0,.7), 0 0 0 1px rgba(255,255,255,.08) inset'}}>
    <div style={{position: 'relative', width: screenW, height: screenH, borderRadius: W * 0.115, overflow: 'hidden', background: '#000'}}>
      {src?.kind === 'clip' && <OffthreadVideo src={staticFile(`clips/${src.file}`)} startFrom={src.startFrom ?? 0} muted style={{width: '100%', height: '100%', objectFit: 'cover'}} />}
      {src?.kind === 'shot' && <Img src={staticFile(`shots/${src.file}`)} style={{width: '100%', height: '100%', objectFit: 'cover'}} />}
      {!src && <div style={{position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', textAlign: 'center', padding: 24, color: C.unknown, fontFamily: FONT_TEXT, fontSize: 22, background: C.bg}}>{missingLabel ?? 'No footage captured'}</div>}
      <div style={{position: 'absolute', top: screenW * 0.03, left: '50%', width: screenW * 0.3, height: screenW * 0.085, transform: 'translateX(-50%)', borderRadius: 999, background: '#000'}} />
      {children}
    </div></div>);
};
