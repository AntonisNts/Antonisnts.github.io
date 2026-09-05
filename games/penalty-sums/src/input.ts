/**
 * One gesture, both platforms: drag anywhere and release.
 *
 * Pointer events cover mouse and touch through the same code path, so nothing
 * is hover-only and nothing needs a second implementation.
 */
import { config } from './config';

export type Drag = {
  active: boolean;
  /** 0 to 1. Below the dead zone the release is ignored. */
  power: number;
  /** -1 to 1, left to right across the goal. */
  aim: number;
  /** 0 to 1, along the goal's height and a little above it. */
  lift: number;
  /** -1 to 1. Negative bends the ball to the left. */
  curve: number;
  /** True once the drag is long enough to count as a real shot. */
  armed: boolean;
  start: { x: number; y: number };
  current: { x: number; y: number };
};

const emptyDrag = (): Drag => ({
  active: false,
  power: 0,
  aim: 0,
  lift: 0,
  curve: 0,
  armed: false,
  start: { x: 0, y: 0 },
  current: { x: 0, y: 0 },
});

export class InputController {
  drag: Drag = emptyDrag();
  private path: { x: number; y: number }[] = [];
  private pointerId: number | null = null;
  private height = 1;

  /** Fired on release with a real drag behind it. */
  onRelease: ((drag: Drag) => void) | null = null;
  /** Fired on any press, so the game can unlock audio and dismiss screens. */
  onPress: ((x: number, y: number) => void) | null = null;

  constructor(private readonly canvas: HTMLCanvasElement) {
    canvas.addEventListener('pointerdown', this.handleDown);
    canvas.addEventListener('pointermove', this.handleMove);
    canvas.addEventListener('pointerup', this.handleUp);
    canvas.addEventListener('pointercancel', this.handleCancel);
    canvas.addEventListener('contextmenu', (event) => event.preventDefault());
  }

  setViewportHeight(height: number): void {
    this.height = height;
  }

  /** Stop a drag in progress without firing a shot. */
  cancel(): void {
    this.pointerId = null;
    this.path = [];
    this.drag = emptyDrag();
  }

  private point(event: PointerEvent): { x: number; y: number } {
    const rect = this.canvas.getBoundingClientRect();
    return { x: event.clientX - rect.left, y: event.clientY - rect.top };
  }

  private handleDown = (event: PointerEvent): void => {
    if (this.pointerId !== null) return;
    this.pointerId = event.pointerId;
    this.canvas.setPointerCapture(event.pointerId);
    const point = this.point(event);
    this.path = [point];
    this.drag = { ...emptyDrag(), active: true, start: point, current: point };
    this.onPress?.(point.x, point.y);
  };

  private handleMove = (event: PointerEvent): void => {
    if (this.pointerId !== event.pointerId) return;
    const point = this.point(event);
    this.path.push(point);
    if (this.path.length > 120) this.path.shift();
    this.drag.current = point;
    this.measure();
  };

  private handleUp = (event: PointerEvent): void => {
    if (this.pointerId !== event.pointerId) return;
    this.canvas.releasePointerCapture(event.pointerId);
    this.pointerId = null;
    this.measure();
    const drag = this.drag;
    this.drag = emptyDrag();
    this.path = [];
    // A release with almost no drag does nothing at all. An accidental tap
    // must never fire a weak shot and waste a penalty.
    if (drag.armed) this.onRelease?.(drag);
  };

  private handleCancel = (event: PointerEvent): void => {
    if (this.pointerId !== event.pointerId) return;
    this.cancel();
  };

  /**
   * Read the gesture. The launch vector points from where the finger is now
   * back to where it started, so pulling down and left sends the ball up and
   * right, the way a catapult does.
   */
  private measure(): void {
    const { start, current } = this.drag;
    const dx = start.x - current.x;
    const dy = current.y - start.y;
    const length = Math.hypot(dx, dy);

    const dead = config.shot.deadDragFraction * this.height;
    const min = config.shot.minDragFraction * this.height;
    const max = config.shot.maxDragFraction * this.height;

    this.drag.armed = length > dead;

    // The brief's mapping: how far you pull is power, how far across you pull
    // is aim, how far down you pull is height. Aim and height are read off
    // their own axes rather than off the drag's angle, because a direction
    // alone cannot reach a bottom corner — the further out you aim, the
    // shallower the pull, and the angle would fight you. Power follows from
    // the two, which is why a top corner naturally costs a harder strike.
    this.drag.power = clamp((length - min) / (max - min), 0, 1);
    this.drag.aim = clamp(dx / (config.shot.aimSpan * max), -1, 1);
    this.drag.lift = clamp((dy - config.shot.liftDead * max) / (config.shot.liftSpan * max), 0, 1);
    this.drag.curve = clamp(this.bow() * config.shot.curveGain, -1, 1);
  }

  /**
   * How far the drag path bows away from the straight line between its ends,
   * as a signed fraction of that line's length. This is what becomes swerve:
   * a path that bows left produces a ball that bends left.
   */
  private bow(): number {
    if (this.path.length < 3) return 0;
    const first = this.path[0] as { x: number; y: number };
    const last = this.path[this.path.length - 1] as { x: number; y: number };
    const chordX = last.x - first.x;
    const chordY = last.y - first.y;
    const chord = Math.hypot(chordX, chordY);
    if (chord < 12) return 0;

    let sum = 0;
    for (let i = 1; i < this.path.length - 1; i++) {
      const point = this.path[i] as { x: number; y: number };
      const cross = chordX * (point.y - first.y) - chordY * (point.x - first.x);
      sum += cross / chord;
    }
    const mean = sum / (this.path.length - 2);
    // The cross product is positive when the path bows to screen-left, and a
    // path bowing left has to produce a ball bending left, which is negative
    // in world x — hence the flip.
    return clamp(-(mean / chord) * 2, -1, 1);
  }
}

function clamp(value: number, min: number, max: number): number {
  return value < min ? min : value > max ? max : value;
}
