import { loadAssets } from './assets';
import { Audio } from './audio';
import { Game } from './game';
import { InputController } from './input';
import { Renderer } from './render';
import { pickLocale } from './strings';

const canvas = document.getElementById('stage') as HTMLCanvasElement | null;
if (!canvas) throw new Error('no canvas');
const ctx = canvas.getContext('2d', { alpha: false });
if (!ctx) throw new Error('no 2d context');

const text = pickLocale(new URLSearchParams(location.search).get('lang'));

async function main(): Promise<void> {
  const stage = canvas as HTMLCanvasElement;
  const context = ctx as CanvasRenderingContext2D;

  // Draw the loading card with no assets at all, then hold it until every
  // image has decoded. Nothing may pop in after the first frame.
  const empty = new Renderer(stage, context, { sprites: {}, hasCreature: false });
  empty.resize();
  empty.drawLoading(text.loading, 0);

  const assets = await loadAssets((fraction) => empty.drawLoading(text.loading, fraction));

  const renderer = new Renderer(stage, context, assets);
  const input = new InputController(stage);
  const audio = new Audio();
  const game = new Game(renderer, input, audio, text, assets);

  const resize = () => {
    renderer.resize();
    input.setViewportHeight(renderer.height);
  };
  resize();
  window.addEventListener('resize', resize);
  window.addEventListener('orientationchange', resize);
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) input.cancel();
  });

  if (new URLSearchParams(location.search).get('debug') === '1') {
    (window as unknown as { penaltySums?: unknown }).penaltySums = game;
  }

  game.start();
}

void main();
