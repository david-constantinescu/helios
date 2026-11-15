import React from 'react';
import {Composition, delayRender, continueRender} from 'remotion';
import {Film, total} from './Film';
import {CUT60, TEASER} from './storyboard';
import {FPS} from './theme';

// Fonts: local SF Pro only (never copied into this project). Falls back to system-ui if not installed.
const face = `@font-face{font-family:"SF Pro Display";src:local("SF Pro Display"),local("SFProDisplay-Regular")}`;
export const Root: React.FC = () => {
  const [h] = React.useState(() => delayRender('fonts'));
  React.useEffect(() => { const s = document.createElement('style'); s.textContent = face; document.head.appendChild(s);
    Promise.race([document.fonts.ready, new Promise(r => setTimeout(r, 1500))]).then(() => continueRender(h)); }, [h]);
  return (<>
    <Composition id="Main16x9" component={Film} durationInFrames={total()} fps={FPS} width={1920} height={1080} />
    <Composition id="Cut60" component={Film} durationInFrames={total(CUT60)} fps={FPS} width={1920} height={1080} defaultProps={{plan: CUT60}} />
    <Composition id="Teaser9x16" component={Film} durationInFrames={total(TEASER)} fps={FPS} width={1080} height={1920} defaultProps={{plan: TEASER, vertical: true}} />
  </>);
};
