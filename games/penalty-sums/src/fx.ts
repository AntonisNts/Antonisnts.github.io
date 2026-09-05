/**
 * The feel layer: shake, hit pause, net ripple, confetti, and rewards that
 * fly to the counter instead of appearing as a static toast.
 *
 * Everything here is optional decoration. With reduced motion asked for, the
 * shot still plays in full; only the shake and the slow motion drop away.
 */
import { config } from './config';

export const prefersReducedMotion = (): boolean =>
  typeof window !== 'undefined' &&
  window.matchMedia?.('(prefers-reduced-motion: reduce)').matches === true;

export type Confetto = {
  x: number;
  y: number;
  vx: number;
  vy: number;
  spin: number;
  angle: number;
  size: number;
  colour: string;
};

export type FlyingNumber = {
  text: string;
  x: number;
  y: number;
  toX: number;
  toY: number;
  age: number;
  life: number;
  colour: string;
};

const confettiColours = ['#c9f24d', '#19c4c9', '#ffd54a', '#ff5fa2', '#f6f0d8'];

export class Effects {
  shake = 0;
  private pause = 0;
  netRipple = 0;
  confetti: Confetto[] = [];
  numbers: FlyingNumber[] = [];
  private reduced = prefersReducedMotion();

  refreshMotionPreference(): void {
    this.reduced = prefersReducedMotion();
  }

  get reducedMotion(): boolean {
    return this.reduced;
  }

  addShake(amount: number): void {
    if (this.reduced) return;
    this.shake = Math.max(this.shake, amount);
  }

  /** Freeze the picture for a beat at the moment of contact. */
  hitPause(seconds: number = config.feel.hitPause): void {
    if (this.reduced) return;
    this.pause = Math.max(this.pause, seconds);
  }

  get paused(): boolean {
    return this.pause > 0;
  }

  rippleNet(): void {
    this.netRipple = config.feel.netRippleDuration;
  }

  burstConfetti(width: number, height: number): void {
    if (this.reduced) return;
    for (let i = 0; i < config.feel.confettiCount; i++) {
      this.confetti.push({
        x: width * (0.15 + Math.random() * 0.7),
        y: -Math.random() * height * 0.4,
        vx: (Math.random() - 0.5) * 180,
        vy: 120 + Math.random() * 260,
        spin: (Math.random() - 0.5) * 9,
        angle: Math.random() * Math.PI * 2,
        size: 6 + Math.random() * 9,
        colour: confettiColours[Math.floor(Math.random() * confettiColours.length)] as string,
      });
    }
  }

  /** A reward that flies from the ball to the coin counter. */
  flyNumber(text: string, from: { x: number; y: number }, to: { x: number; y: number }): void {
    this.numbers.push({
      text,
      x: from.x,
      y: from.y,
      toX: to.x,
      toY: to.y,
      age: 0,
      life: 0.85,
      colour: '#ffd54a',
    });
  }

  /**
   * Advance the effects. Returns the time the rest of the game should use,
   * which is zero while a hit pause is running.
   */
  update(dt: number, height: number): number {
    if (this.pause > 0) {
      this.pause = Math.max(0, this.pause - dt);
      return 0;
    }

    this.shake = Math.max(0, this.shake - this.shake * config.feel.shakeDecay * dt);
    this.netRipple = Math.max(0, this.netRipple - dt);

    for (const piece of this.confetti) {
      piece.vy += 520 * dt;
      piece.x += piece.vx * dt;
      piece.y += piece.vy * dt;
      piece.angle += piece.spin * dt;
    }
    this.confetti = this.confetti.filter((piece) => piece.y < height + 40);

    for (const number of this.numbers) number.age += dt;
    this.numbers = this.numbers.filter((number) => number.age < number.life);

    return dt;
  }

  /** Current shake offset, in pixels. */
  offset(scale: number): { x: number; y: number } {
    if (this.shake <= 0.01) return { x: 0, y: 0 };
    const amount = this.shake * scale;
    return {
      x: (Math.random() - 0.5) * 2 * amount,
      y: (Math.random() - 0.5) * 2 * amount,
    };
  }

  clear(): void {
    this.confetti = [];
    this.numbers = [];
    this.shake = 0;
    this.netRipple = 0;
    this.pause = 0;
  }
}

/** Smooth 0 to 1 ramp. */
export const easeOut = (t: number): number => 1 - (1 - t) ** 3;
export const easeIn = (t: number): number => t * t;
export const clamp01 = (t: number): number => (t < 0 ? 0 : t > 1 ? 1 : t);
