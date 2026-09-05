import { config } from './config';

/**
 * The scene is 2D sprites scaled by depth, not a 3D engine. Everything is
 * positioned in metres and projected here; no drawing code may work in pixels.
 *
 *   x  left and right, 0 at the centre of the goal
 *   y  height, 0 at the ground
 *   z  depth, 0 at the penalty spot, 11 at the goal line
 */
export type Vec3 = { x: number; y: number; z: number };

export type Projected = {
  x: number;
  y: number;
  /** Metres to pixels at this depth. Multiply any sprite size by it. */
  scale: number;
};

export class Projection {
  width = 0;
  height = 0;
  /** Pixels per metre at unit depth scale. */
  private pixelsPerMetre = 1;
  private horizonY = 0;

  resize(width: number, height: number): void {
    this.width = width;
    this.height = height;
    this.horizonY = height * config.camera.horizonFraction;
    // Fix the pixel scale so the goal mouth fills the intended share of the
    // frame. Everything else follows from it.
    const scaleAtGoal = this.depthScale(config.world.goalZ);
    this.pixelsPerMetre =
      (width * config.camera.goalWidthFraction) / (config.world.goalWidth * scaleAtGoal);
  }

  /** Perspective foreshortening at a depth, before the pixel scale. */
  depthScale(z: number): number {
    const fromCamera = z - config.camera.z;
    return config.camera.focal / (config.camera.focal + fromCamera);
  }

  project(x: number, y: number, z: number): Projected {
    const scale = this.depthScale(z) * this.pixelsPerMetre;
    return {
      x: this.width / 2 + (x - config.camera.x) * scale,
      y: this.horizonY - (y - config.camera.y) * scale,
      scale,
    };
  }

  /** Screen height of one metre at a depth. */
  metres(z: number): number {
    return this.depthScale(z) * this.pixelsPerMetre;
  }

  /**
   * Turn a horizontal drag into an aim across the goal, and a vertical one
   * into an aim up it. Both are in metres on the goal plane.
   */
  get goalPlaneScale(): number {
    return this.metres(config.world.goalZ);
  }
}
