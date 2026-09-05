/**
 * All drawing.
 *
 * Layer order, back to front: stadium, goal and net, keeper, ball, striker,
 * mascot, interface. The keeper stands in front of the goal line, so it is
 * drawn over the netting; the ball sits between the keeper and the striker;
 * and once the ball has crossed the line the netting goes over it again, so a
 * goal is visibly behind the net.
 */
import { config } from './config';
import type { Assets, Sprite } from './assets';
import { Projection } from './projection';
import type { Effects } from './fx';
import { clamp01, easeOut } from './fx';
import type { Ball } from './ball';
import type { KeeperState } from './keeper';
import { thirdCentre } from './keeper';

export const palette = {
  ink: '#0d1b1e',
  cream: '#f6f0d8',
  teal: '#1c6b70',
  deepTeal: '#0f3d41',
  lime: '#c9f24d',
  cyan: '#35d6e8',
  pink: '#ff2f92',
  gold: '#ffd54a',
  shadow: 'rgba(6, 24, 26, 0.32)',
};

const FONT = `system-ui, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif`;

/** Where the goal frame's inner opening sits inside the goal plate. */
const goalMouth = { left: 0.048, right: 0.952, top: 0.105, bottom: 0.886 };

export type ZonePanel = {
  value: number;
  third: 0 | 1 | 2;
  /** 0 to 1 highlight, used when a zone has just been answered. */
  flash: number;
  correct: boolean;
  revealed: boolean;
};

export type Scene = {
  ball: Ball;
  keeper: KeeperState;
  /** 0 to 1 through the striker's kick. */
  kick: number;
  /** -1 slumped, 0 idle, 1 celebrating. */
  creatureMood: number;
  creaturePhase: number;
  zones: ZonePanel[];
  question: string;
  headline: string;
  penaltyLabel: string;
  message: string;
  hint: string;
  coins: number;
  /** True while the ball has crossed the goal plane. */
  ballPastGoal: boolean;
  aim: {
    visible: boolean;
    power: number;
    targetX: number;
    targetY: number;
    swerve: number;
  };
};

export class Renderer {
  readonly projection = new Projection();
  private dpr = 1;
  /** Pixels per unit of the reference design height. */
  private ui = 1;
  private keeperTint: HTMLCanvasElement | null = null;

  constructor(
    private readonly canvas: HTMLCanvasElement,
    private readonly ctx: CanvasRenderingContext2D,
    private readonly assets: Assets,
  ) {}

  resize(): void {
    this.dpr = Math.min(window.devicePixelRatio || 1, config.render.maxDevicePixelRatio);
    const width = this.canvas.clientWidth || window.innerWidth;
    const height = this.canvas.clientHeight || window.innerHeight;
    this.canvas.width = Math.round(width * this.dpr);
    this.canvas.height = Math.round(height * this.dpr);
    this.projection.resize(width, height);
    this.ui = height / config.render.referenceHeight;
  }

  get width(): number {
    return this.projection.width;
  }

  get height(): number {
    return this.projection.height;
  }

  get uiScale(): number {
    return this.ui;
  }

  /** Screen position of the coin counter, so rewards know where to fly. */
  get coinAnchor(): { x: number; y: number } {
    return { x: this.width - 74 * this.ui, y: 42 * this.ui };
  }

  draw(scene: Scene, effects: Effects): void {
    const ctx = this.ctx;
    ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
    ctx.clearRect(0, 0, this.width, this.height);

    const shake = effects.offset(this.ui);
    ctx.save();
    ctx.translate(shake.x, shake.y);

    this.drawStadium();
    this.drawGroundShadows(scene);
    this.drawGoal(effects, false);
    // The keeper stands in front of the line, so it is drawn over the netting
    // rather than behind it.
    this.drawKeeper(scene);
    this.drawZonePanels(scene);
    this.drawBall(scene);
    if (scene.ballPastGoal) this.drawGoal(effects, true);
    this.drawStriker(scene);
    this.drawCreature(scene);
    this.drawAim(scene);

    ctx.restore();

    this.drawInterface(scene, effects);
    this.drawConfetti(effects);
    this.drawFlyingNumbers(effects);
  }

  // -------------------------------------------------------------------------
  // world layers
  // -------------------------------------------------------------------------

  private drawStadium(): void {
    const sprite = this.assets.sprites.stadium;
    const ctx = this.ctx;
    if (!sprite) {
      ctx.fillStyle = palette.deepTeal;
      ctx.fillRect(0, 0, this.width, this.height);
      return;
    }
    // Cover the frame, then slide the plate so its own ground line sits on the
    // projected goal line.
    const goalGround = this.projection.project(0, 0, config.world.goalZ);
    const scale =
      Math.max(this.width / sprite.width, this.height / sprite.height) * config.stadium.zoom;
    const drawWidth = sprite.width * scale;
    const drawHeight = sprite.height * scale;
    const x = (this.width - drawWidth) / 2;
    const y = goalGround.y - config.stadium.groundAnchor * drawHeight;
    ctx.drawImage(sprite.image, x, y, drawWidth, drawHeight);

    // The turf runs out below the plate on tall screens; carry it on.
    if (y + drawHeight < this.height) {
      ctx.fillStyle = '#2f6b3a';
      ctx.fillRect(0, y + drawHeight - 1, this.width, this.height - (y + drawHeight) + 1);
    }
  }

  /** Contact shadows, so nothing floats. */
  private drawGroundShadows(scene: Scene): void {
    const ctx = this.ctx;
    const shadow = (x: number, z: number, radius: number, alpha: number) => {
      const at = this.projection.project(x, 0, z);
      const rx = radius * at.scale;
      ctx.save();
      ctx.globalAlpha = alpha;
      ctx.fillStyle = palette.shadow;
      ctx.beginPath();
      ctx.ellipse(at.x, at.y, rx, rx * 0.34, 0, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    };

    shadow(config.world.strikerX, config.world.strikerZ, 0.46, 0.9);
    shadow(0, config.world.goalZ - 0.25, 0.5, 0.55);
    shadow(config.world.creatureX, config.world.creatureZ, 0.34, 0.7);
    const ball = scene.ball;
    const drop = clamp01(1 - (ball.pos.y - config.world.ballRadius) / 2.4);
    shadow(ball.pos.x, ball.pos.z, 0.18 + 0.1 * (1 - drop), 0.25 + 0.5 * drop);
  }

  private drawKeeper(scene: Scene): void {
    const sprite = this.assets.sprites.keeper;
    const keeper = scene.keeper;
    const dive = easeOut(keeper.dive);
    const lateral = keeper.direction * dive * config.keeper.diveReach;
    const lift = keeper.direction === 0 ? dive * 0.34 : dive * config.keeper.diveLift;
    const x = lateral;
    const z = config.world.goalZ - 0.35;

    // Squash on landing, then settle.
    const settle = clamp01(keeper.landed / config.keeper.squashDuration);
    const squash = keeper.dive >= 1 ? 1 - 0.16 * Math.sin(settle * Math.PI) : 1;
    const rotation = keeper.direction * dive * config.keeper.diveRotation;

    if (!sprite) {
      const at = this.projection.project(x, lift, z);
      const h = config.keeper.height * at.scale;
      this.ctx.fillStyle = palette.pink;
      this.ctx.fillRect(at.x - h * 0.22, at.y - h, h * 0.44, h);
      return;
    }

    this.drawSprite(sprite, {
      x,
      y: lift,
      z,
      heightMetres: config.keeper.height * squash,
      rotation,
      anchorY: 1,
      tint: config.render.keeperWarmth,
    });
  }

  /**
   * The goal frame and its netting.
   *
   * `overBall` draws the same plate a second time on top of the ball, so a
   * shot that has crossed the line reads through the mesh instead of floating
   * in front of it.
   */
  private drawGoal(effects: Effects, overBall: boolean): void {
    const sprite = this.assets.sprites.goal;
    const ctx = this.ctx;
    const left = this.projection.project(-config.world.goalWidth / 2, 0, config.world.goalZ);
    const right = this.projection.project(config.world.goalWidth / 2, 0, config.world.goalZ);
    const top = this.projection.project(0, config.world.goalHeight, config.world.goalZ);

    if (!sprite) {
      ctx.save();
      ctx.strokeStyle = palette.cream;
      ctx.lineWidth = 8 * this.ui;
      ctx.strokeRect(left.x, top.y, right.x - left.x, left.y - top.y);
      ctx.restore();
      return;
    }

    // Fit the plate so its inner opening lands exactly on the projected goal.
    const mouthWidth = (right.x - left.x) / (goalMouth.right - goalMouth.left);
    const mouthHeight = (left.y - top.y) / (goalMouth.bottom - goalMouth.top);
    const drawX = left.x - goalMouth.left * mouthWidth;
    const drawY = top.y - goalMouth.top * mouthHeight;

    const ripple = effects.netRipple;
    ctx.save();
    if (overBall) ctx.globalAlpha = 0.95;

    if (ripple <= 0) {
      ctx.drawImage(sprite.image, drawX, drawY, mouthWidth, mouthHeight);
    } else {
      // A simple wobble: the plate is drawn in horizontal bands, each nudged
      // sideways by a decaying wave. Enough to read as a net taking a shot.
      const bands = 26;
      const strength =
        config.feel.netRippleAmplitude *
        this.ui *
        (ripple / config.feel.netRippleDuration) ** 1.4;
      const bandHeight = mouthHeight / bands;
      const phase = (config.feel.netRippleDuration - ripple) * 22;
      for (let i = 0; i < bands; i++) {
        const sourceY = (i / bands) * sprite.height;
        const sourceHeight = sprite.height / bands;
        const wave = Math.sin(phase + i * 0.55) * strength * Math.sin((i / bands) * Math.PI);
        ctx.drawImage(
          sprite.image,
          0,
          sourceY,
          sprite.width,
          sourceHeight,
          drawX + wave,
          drawY + i * bandHeight,
          mouthWidth,
          bandHeight + 1,
        );
      }
    }
    ctx.restore();
  }

  /**
   * The three answer panels, floating just in front of the goal line so the
   * netting never swallows them.
   */
  private drawZonePanels(scene: Scene): void {
    const ctx = this.ctx;
    const z = config.world.goalZ - config.zones.standOff;
    for (const zone of scene.zones) {
      const centre = thirdCentre(zone.third);
      const at = this.projection.project(centre, config.world.goalHeight * config.zones.height, z);
      const size = config.zones.size * at.scale;
      const flash = clamp01(zone.flash);

      ctx.save();
      ctx.translate(at.x, at.y);
      const scale = 1 + flash * 0.12;
      ctx.scale(scale, scale);

      // Soft glow.
      ctx.shadowColor = zone.revealed ? palette.lime : 'rgba(15, 61, 65, 0.55)';
      ctx.shadowBlur = (zone.revealed ? 34 : 18) * this.ui;

      const width = size * 1.5;
      const height = size * 1.12;
      ctx.fillStyle = zone.revealed
        ? 'rgba(201, 242, 77, 0.94)'
        : `rgba(246, 240, 216, ${0.9 + flash * 0.1})`;
      roundedRect(ctx, -width / 2, -height / 2, width, height, size * 0.26);
      ctx.fill();

      ctx.shadowBlur = 0;
      ctx.lineWidth = Math.max(2, size * 0.07);
      ctx.strokeStyle = zone.revealed ? palette.teal : 'rgba(28, 107, 112, 0.85)';
      roundedRect(ctx, -width / 2, -height / 2, width, height, size * 0.26);
      ctx.stroke();

      ctx.fillStyle = palette.deepTeal;
      ctx.font = `700 ${Math.round(size * 0.82)}px ${FONT}`;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText(String(zone.value), 0, size * 0.03);
      ctx.restore();
    }
  }

  private drawBall(scene: Scene): void {
    const ball = scene.ball;
    const sprite = this.assets.sprites.ball;
    const ctx = this.ctx;

    // Trail: a handful of fading copies behind the ball.
    for (let i = 0; i < ball.trail.length; i++) {
      const point = ball.trail[i];
      if (!point) continue;
      const fade = (i + 1) / (ball.trail.length + 1);
      const at = this.projection.project(point.x, point.y, point.z);
      const radius = config.world.ballRadius * at.scale;
      ctx.save();
      ctx.globalAlpha = 0.5 * fade;
      ctx.fillStyle = palette.cream;
      ctx.beginPath();
      ctx.arc(at.x, at.y, radius * (0.5 + fade * 0.5), 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    }

    const at = this.projection.project(ball.pos.x, ball.pos.y, ball.pos.z);
    const diameter = config.world.ballRadius * 2 * at.scale;
    if (!sprite) {
      ctx.fillStyle = palette.cream;
      ctx.beginPath();
      ctx.arc(at.x, at.y, diameter / 2, 0, Math.PI * 2);
      ctx.fill();
      return;
    }
    ctx.save();
    ctx.translate(at.x, at.y);
    ctx.rotate(ball.spin * Math.PI * 2);
    ctx.drawImage(sprite.image, -diameter / 2, -diameter / 2, diameter, diameter);
    ctx.restore();
  }

  private drawStriker(scene: Scene): void {
    const sprite = this.assets.sprites.striker;
    if (!sprite) return;
    // A short lunge through the kick, then back to standing.
    const kick = scene.kick;
    const swing = Math.sin(clamp01(kick) * Math.PI);
    this.drawSprite(sprite, {
      x: config.world.strikerX + swing * 0.22,
      y: swing * 0.06,
      z: config.world.strikerZ + swing * 0.12,
      heightMetres: config.striker.height,
      rotation: swing * 0.12,
      anchorY: 1,
      tint: 0,
    });
  }

  private drawCreature(scene: Scene): void {
    const mood = scene.creatureMood;
    const phase = scene.creaturePhase;
    const jump = mood > 0 ? Math.abs(Math.sin(phase * Math.PI * 2)) * config.creature.jumpHeight : 0;
    const slump = mood < 0 ? 0.82 : 1;
    const sprite = this.assets.sprites.creature;

    if (sprite) {
      this.drawSprite(sprite, {
        x: config.world.creatureX,
        y: jump,
        z: config.world.creatureZ,
        heightMetres: config.creature.height * slump,
        rotation: mood > 0 ? Math.sin(phase * 12) * 0.16 : 0,
        anchorY: 1,
        tint: 0,
      });
      return;
    }

    // No mascot art in the build: draw one from shapes so the sideline still
    // reacts. Dropping creature.png into public/assets takes over from this.
    const ctx = this.ctx;
    const at = this.projection.project(config.world.creatureX, jump, config.world.creatureZ);
    const h = config.creature.height * at.scale * slump;
    const w = h * 0.6;
    const armUp = mood > 0 ? 1 : mood < 0 ? -0.4 : 0.3;
    const lean = mood > 0 ? Math.sin(phase * 12) * 0.1 : 0;

    ctx.save();
    ctx.translate(at.x, at.y);
    ctx.rotate(lean);

    // Feet.
    ctx.fillStyle = palette.deepTeal;
    ctx.beginPath();
    ctx.ellipse(-w * 0.19, -h * 0.03, w * 0.15, h * 0.045, 0, 0, Math.PI * 2);
    ctx.ellipse(w * 0.19, -h * 0.03, w * 0.15, h * 0.045, 0, 0, Math.PI * 2);
    ctx.fill();

    // Arms, thrown up on a goal and hanging on a save.
    ctx.lineCap = 'round';
    ctx.strokeStyle = palette.lime;
    ctx.lineWidth = Math.max(3, w * 0.15);
    ctx.beginPath();
    ctx.moveTo(-w * 0.3, -h * 0.55);
    ctx.lineTo(-w * 0.6, -h * (0.55 + armUp * 0.32));
    ctx.moveTo(w * 0.3, -h * 0.55);
    ctx.lineTo(w * 0.6, -h * (0.55 + armUp * 0.32));
    ctx.stroke();

    // Body.
    ctx.fillStyle = palette.lime;
    roundedRect(ctx, -w * 0.36, -h * 0.9, w * 0.72, h * 0.88, w * 0.34);
    ctx.fill();

    // Belly.
    ctx.fillStyle = palette.cream;
    ctx.beginPath();
    ctx.ellipse(0, -h * 0.32, w * 0.21, h * 0.19, 0, 0, Math.PI * 2);
    ctx.fill();

    // Face.
    const eyeY = -h * (mood < 0 ? 0.6 : 0.65);
    ctx.fillStyle = palette.deepTeal;
    ctx.beginPath();
    ctx.arc(-w * 0.15, eyeY, w * 0.075, 0, Math.PI * 2);
    ctx.arc(w * 0.15, eyeY, w * 0.075, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = palette.deepTeal;
    ctx.lineWidth = Math.max(2, w * 0.06);
    ctx.beginPath();
    if (mood < 0) {
      // A slump turns the smile over.
      ctx.arc(0, eyeY + h * 0.14, w * 0.16, Math.PI * 1.15, Math.PI * 1.85);
    } else {
      ctx.arc(0, eyeY + h * 0.06, w * 0.16, Math.PI * 0.15, Math.PI * 0.85);
    }
    ctx.stroke();
    ctx.restore();
  }

  /**
   * The live aim: a curved dotted arc into the goal mouth and a power bar.
   * Both vanish the instant the ball is struck.
   */
  private drawAim(scene: Scene): void {
    if (!scene.aim.visible) return;
    const ctx = this.ctx;
    const { targetX, targetY, swerve, power } = scene.aim;
    const start = scene.ball.pos;
    const speed =
      config.shot.minSpeed + (config.shot.maxSpeed - config.shot.minSpeed) * clamp01(power);
    const distance = config.world.goalZ - start.z;
    const time = distance / speed;
    const g = config.shot.gravity * config.shot.gravityScale;
    const vx = (targetX - start.x) / time - 0.5 * swerve * time;
    const vy = (targetY - start.y - 0.5 * g * time * time) / time;

    ctx.save();
    const steps = 22;
    for (let i = 1; i <= steps; i++) {
      const t = (i / steps) * time;
      const x = start.x + vx * t + 0.5 * swerve * t * t;
      const y = start.y + vy * t + 0.5 * g * t * t;
      const z = start.z + speed * t;
      const at = this.projection.project(x, y, z);
      const fade = 0.25 + 0.6 * (1 - i / steps);
      ctx.globalAlpha = fade;
      ctx.fillStyle = i === steps ? palette.gold : palette.cream;
      ctx.beginPath();
      ctx.arc(at.x, at.y, Math.max(2, 5.5 * this.ui * (1 - i / steps / 1.6)), 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.restore();

    // Power bar, low and central so a thumb never covers it.
    const barWidth = 260 * this.ui;
    const barHeight = 16 * this.ui;
    const x = (this.width - barWidth) / 2;
    const y = this.height - 54 * this.ui;
    ctx.save();
    ctx.fillStyle = 'rgba(13, 27, 30, 0.55)';
    roundedRect(ctx, x, y, barWidth, barHeight, barHeight / 2);
    ctx.fill();
    const fill = clamp01(power);
    ctx.fillStyle = fill < 0.5 ? palette.cyan : fill < 0.85 ? palette.lime : palette.gold;
    roundedRect(ctx, x, y, Math.max(barHeight, barWidth * fill), barHeight, barHeight / 2);
    ctx.fill();
    ctx.restore();
  }

  // -------------------------------------------------------------------------
  // interface
  // -------------------------------------------------------------------------

  private drawInterface(scene: Scene, effects: Effects): void {
    const ctx = this.ctx;
    const u = this.ui;

    // The question, above the crossbar, styled as a scoreboard.
    if (scene.question) {
      const top = this.projection.project(0, config.world.goalHeight, config.world.goalZ);
      const width = Math.min(this.width * 0.86, 760 * u);
      const height = 92 * u;
      const x = (this.width - width) / 2;
      const y = Math.max(66 * u, top.y - height - 26 * u);

      ctx.save();
      ctx.fillStyle = 'rgba(13, 27, 30, 0.86)';
      roundedRect(ctx, x, y, width, height, 18 * u);
      ctx.fill();
      ctx.strokeStyle = 'rgba(53, 214, 232, 0.55)';
      ctx.lineWidth = 2 * u;
      roundedRect(ctx, x, y, width, height, 18 * u);
      ctx.stroke();

      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillStyle = palette.cyan;
      ctx.font = `700 ${Math.round(15 * u)}px ${FONT}`;
      ctx.fillText(scene.penaltyLabel, this.width / 2, y + 20 * u);

      ctx.fillStyle = palette.cream;
      ctx.font = `600 ${Math.round(21 * u)}px ${FONT}`;
      wrapText(ctx, scene.question, this.width / 2, y + 48 * u, width - 44 * u, 25 * u);
      ctx.restore();
    }

    // Coin counter.
    const anchor = this.coinAnchor;
    ctx.save();
    ctx.fillStyle = 'rgba(13, 27, 30, 0.8)';
    roundedRect(ctx, anchor.x - 62 * u, anchor.y - 21 * u, 124 * u, 42 * u, 21 * u);
    ctx.fill();
    ctx.fillStyle = palette.gold;
    ctx.beginPath();
    ctx.arc(anchor.x - 38 * u, anchor.y, 11 * u, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = palette.cream;
    ctx.font = `700 ${Math.round(20 * u)}px ${FONT}`;
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillText(String(scene.coins), anchor.x - 20 * u, anchor.y + u);
    ctx.restore();

    if (scene.hint) {
      ctx.save();
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.font = `600 ${Math.round(19 * u)}px ${FONT}`;
      ctx.fillStyle = 'rgba(13, 27, 30, 0.75)';
      const width = ctx.measureText(scene.hint).width + 34 * u;
      roundedRect(ctx, (this.width - width) / 2, this.height - 108 * u, width, 38 * u, 19 * u);
      ctx.fill();
      ctx.fillStyle = palette.cream;
      ctx.fillText(scene.hint, this.width / 2, this.height - 89 * u);
      ctx.restore();
    }

    if (scene.headline) {
      ctx.save();
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.font = `800 ${Math.round(64 * u)}px ${FONT}`;
      ctx.lineWidth = 10 * u;
      ctx.strokeStyle = palette.deepTeal;
      ctx.fillStyle = palette.lime;
      // Inside the goal mouth, clear of both the scoreboard above the
      // crossbar and the answer panels hanging below it.
      const y = this.projection.project(0, 0.85, config.world.goalZ).y;
      ctx.strokeText(scene.headline, this.width / 2, y);
      ctx.fillText(scene.headline, this.width / 2, y);
      ctx.restore();
    }

    if (scene.message) {
      ctx.save();
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.font = `600 ${Math.round(24 * u)}px ${FONT}`;
      const width = ctx.measureText(scene.message).width + 46 * u;
      const y = this.height * 0.46;
      ctx.fillStyle = 'rgba(13, 27, 30, 0.82)';
      roundedRect(ctx, (this.width - width) / 2, y - 25 * u, width, 50 * u, 25 * u);
      ctx.fill();
      ctx.fillStyle = palette.cream;
      ctx.fillText(scene.message, this.width / 2, y + u);
      ctx.restore();
    }

    void effects;
  }

  private drawConfetti(effects: Effects): void {
    const ctx = this.ctx;
    for (const piece of effects.confetti) {
      ctx.save();
      ctx.translate(piece.x, piece.y);
      ctx.rotate(piece.angle);
      ctx.fillStyle = piece.colour;
      ctx.fillRect(-piece.size / 2, -piece.size / 4, piece.size, piece.size / 2);
      ctx.restore();
    }
  }

  private drawFlyingNumbers(effects: Effects): void {
    const ctx = this.ctx;
    const u = this.ui;
    for (const number of effects.numbers) {
      const t = clamp01(number.age / number.life);
      const ease = easeOut(t);
      const x = number.x + (number.toX - number.x) * ease;
      // Arc upwards on the way rather than sliding in a straight line.
      const y = number.y + (number.toY - number.y) * ease - Math.sin(t * Math.PI) * 60 * u;
      ctx.save();
      ctx.globalAlpha = t > 0.8 ? (1 - t) / 0.2 : 1;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.font = `800 ${Math.round((26 + 8 * (1 - t)) * u)}px ${FONT}`;
      ctx.lineWidth = 6 * u;
      ctx.strokeStyle = palette.deepTeal;
      ctx.strokeText(number.text, x, y);
      ctx.fillStyle = number.colour;
      ctx.fillText(number.text, x, y);
      ctx.restore();
    }
  }

  /** The end card. Drawn over everything, with its own button rectangle. */
  drawEndScreen(lines: { goals: string; maths: string; button: string }): { x: number; y: number; w: number; h: number } {
    const ctx = this.ctx;
    const u = this.ui;
    ctx.save();
    ctx.fillStyle = 'rgba(9, 24, 26, 0.78)';
    ctx.fillRect(0, 0, this.width, this.height);

    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = palette.cream;
    ctx.font = `800 ${Math.round(52 * u)}px ${FONT}`;
    ctx.fillText(lines.goals, this.width / 2, this.height * 0.36);
    ctx.font = `600 ${Math.round(26 * u)}px ${FONT}`;
    ctx.fillStyle = palette.cyan;
    ctx.fillText(lines.maths, this.width / 2, this.height * 0.46);

    const buttonWidth = Math.min(this.width * 0.72, 340 * u);
    const buttonHeight = 62 * u;
    const box = {
      x: (this.width - buttonWidth) / 2,
      y: this.height * 0.6,
      w: buttonWidth,
      h: buttonHeight,
    };
    ctx.fillStyle = palette.lime;
    roundedRect(ctx, box.x, box.y, box.w, box.h, buttonHeight / 2);
    ctx.fill();
    ctx.fillStyle = palette.deepTeal;
    ctx.font = `700 ${Math.round(23 * u)}px ${FONT}`;
    ctx.fillText(lines.button, this.width / 2, box.y + buttonHeight / 2 + u);
    ctx.restore();
    return box;
  }

  drawLoading(text: string, fraction: number): void {
    const ctx = this.ctx;
    ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
    const u = this.ui;
    ctx.fillStyle = palette.ink;
    ctx.fillRect(0, 0, this.width, this.height);
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = palette.cream;
    ctx.font = `700 ${Math.round(28 * u)}px ${FONT}`;
    ctx.fillText(text, this.width / 2, this.height / 2 - 26 * u);
    const width = Math.min(this.width * 0.5, 300 * u);
    const x = (this.width - width) / 2;
    const y = this.height / 2 + 12 * u;
    ctx.fillStyle = 'rgba(246, 240, 216, 0.2)';
    roundedRect(ctx, x, y, width, 10 * u, 5 * u);
    ctx.fill();
    ctx.fillStyle = palette.lime;
    roundedRect(ctx, x, y, Math.max(10 * u, width * clamp01(fraction)), 10 * u, 5 * u);
    ctx.fill();
  }

  // -------------------------------------------------------------------------

  private drawSprite(
    sprite: Sprite,
    options: {
      x: number;
      y: number;
      z: number;
      heightMetres: number;
      rotation: number;
      anchorY: number;
      tint: number;
    },
  ): void {
    const ctx = this.ctx;
    const at = this.projection.project(options.x, options.y, options.z);
    const height = options.heightMetres * at.scale;
    const width = height * (sprite.width / sprite.height);
    const image = options.tint > 0 ? this.warmed(sprite, options.tint) : sprite.image;

    ctx.save();
    ctx.translate(at.x, at.y);
    if (options.rotation) ctx.rotate(options.rotation);
    ctx.drawImage(image, -width / 2, -height * options.anchorY, width, height);
    ctx.restore();
  }

  /**
   * The keeper plate was lit in a different pass from the striker and reads
   * cooler. Rather than regenerate the art, it is warmed once through a small
   * colour matrix and the result cached.
   */
  private warmed(sprite: Sprite, amount: number): CanvasImageSource {
    if (this.keeperTint) return this.keeperTint;
    const canvas = document.createElement('canvas');
    canvas.width = sprite.width;
    canvas.height = sprite.height;
    const ctx = canvas.getContext('2d');
    if (!ctx) return sprite.image;
    ctx.drawImage(sprite.image, 0, 0);
    const frame = ctx.getImageData(0, 0, canvas.width, canvas.height);
    const data = frame.data;
    for (let i = 0; i < data.length; i += 4) {
      if (data[i + 3] === 0) continue;
      const r = data[i] as number;
      const g = data[i + 1] as number;
      const b = data[i + 2] as number;
      data[i] = Math.min(255, r * (1 + amount) + 6 * amount * 255 * 0.02);
      data[i + 1] = Math.min(255, g * (1 + amount * 0.35));
      data[i + 2] = Math.max(0, b * (1 - amount * 0.5));
    }
    ctx.putImageData(frame, 0, 0);
    this.keeperTint = canvas;
    return canvas;
  }
}

function roundedRect(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  w: number,
  h: number,
  r: number,
): void {
  const radius = Math.min(r, w / 2, h / 2);
  ctx.beginPath();
  ctx.moveTo(x + radius, y);
  ctx.arcTo(x + w, y, x + w, y + h, radius);
  ctx.arcTo(x + w, y + h, x, y + h, radius);
  ctx.arcTo(x, y + h, x, y, radius);
  ctx.arcTo(x, y, x + w, y, radius);
  ctx.closePath();
}

function wrapText(
  ctx: CanvasRenderingContext2D,
  text: string,
  centreX: number,
  y: number,
  maxWidth: number,
  lineHeight: number,
): void {
  const words = text.split(' ');
  const lines: string[] = [];
  let line = '';
  for (const word of words) {
    const candidate = line ? `${line} ${word}` : word;
    if (ctx.measureText(candidate).width > maxWidth && line) {
      lines.push(line);
      line = word;
    } else {
      line = candidate;
    }
  }
  if (line) lines.push(line);
  const start = y - ((lines.length - 1) * lineHeight) / 2;
  lines.forEach((entry, index) => ctx.fillText(entry, centreX, start + index * lineHeight));
}
