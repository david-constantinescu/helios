import {Easing} from 'remotion';
// Exact tokens from ios/CrewHealthHub/UI/Components.swift (brief section 6.1)
export const C = {
  bg: '#0B0F17', bgDeep: '#05070D', elev1: '#121826', elev2: '#1A2234', line: '#263048',
  text: '#E8EDF7', dim: '#9AA6BF', accent: '#5AC8FA', warm: '#FFB347',
  ok: '#3DDC97', watch: '#FFD166', act: '#FF9F4A', escalate: '#FF5D73', unknown: '#7F8AA3',
};
export const FPS = 60;
export const SPRING = {damping: 200, stiffness: 120, mass: 1};
export const SPRING_TITLE = {damping: 18, stiffness: 90};
export const EASE = Easing.bezier(0.22, 1, 0.36, 1);
export const FONT_DISPLAY = '"SF Pro Display", -apple-system, system-ui, sans-serif';
export const FONT_TEXT = '"SF Pro Text", -apple-system, system-ui, sans-serif';
// Simulator screen is 402x874 pt (iPhone 18 Pro); the PhoneFrame screen must keep this ratio.
export const SCREEN_ASPECT = 402 / 874;
