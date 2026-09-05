/**
 * Image loading. Every image is decoded before the first frame is drawn, so
 * nothing ever pops in.
 */
export type SpriteName = 'striker' | 'keeper' | 'ball' | 'goal' | 'stadium' | 'creature';

export type SpriteEntry = {
  file: string;
  width: number;
  height: number;
  sourceWidth: number;
  sourceHeight: number;
  trim: { x: number; y: number; w: number; h: number };
  scale: number;
  /** Where the sprite is pinned, as a fraction of the trimmed image. */
  anchor: { x: number; y: number };
};

export type Sprite = SpriteEntry & { image: HTMLImageElement };

export type Assets = {
  sprites: Partial<Record<SpriteName, Sprite>>;
  /** True when the mascot art is present rather than drawn from shapes. */
  hasCreature: boolean;
};

const BASE = 'assets/';

function loadImage(url: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.decoding = 'async';
    image.onload = () => resolve(image);
    image.onerror = () => reject(new Error(`could not load ${url}`));
    image.src = url;
  });
}

export async function loadAssets(onProgress?: (fraction: number) => void): Promise<Assets> {
  const manifestResponse = await fetch(`${BASE}manifest.json`);
  const manifest = (await manifestResponse.json()) as Record<string, SpriteEntry>;
  const names = Object.keys(manifest) as SpriteName[];

  const sprites: Partial<Record<SpriteName, Sprite>> = {};
  let done = 0;
  await Promise.all(
    names.map(async (name) => {
      const entry = manifest[name];
      if (!entry) return;
      try {
        const image = await loadImage(`${BASE}${entry.file}`);
        sprites[name] = { ...entry, image };
      } catch {
        // A missing plate is not fatal: the mascot, in particular, is drawn
        // from shapes when its art is not there.
      }
      done++;
      onProgress?.(done / names.length);
    }),
  );

  return { sprites, hasCreature: Boolean(sprites.creature) };
}
