/**
 * The round: five penalties, a question on each, and the rules that keep
 * knowing the answer separate from executing the shot.
 */
import { config } from './config';
import type { Assets } from './assets';
import { Audio } from './audio';
import { Effects, clamp01 } from './fx';
import { InputController, type Drag } from './input';
import { makeQuestion, TierTracker, type Question } from './maths';
import { Renderer, type Scene, type ZonePanel } from './render';
import type { Strings } from './strings';
import {
  launch,
  predictedCrossing,
  rebound,
  restBall,
  stepBall,
  type Ball,
  gravity,
} from './ball';
import { restKeeper, saves, stepKeeper, thirdAt, type KeeperState, type Third } from './keeper';

type Phase = 'ready' | 'aiming' | 'flight' | 'settling' | 'result' | 'ended';

export type Debug = {
  enabled: boolean;
  flightTime: number;
  speed: number;
  keeperChoice: string;
  landing: string;
  swerve: number;
};

export class Game {
  private ball: Ball = restBall();
  private previousBall = { x: 0, y: 0, z: 0 };
  private keeper: KeeperState = restKeeper();
  private effects = new Effects();
  private tiers = new TierTracker();

  private phase: Phase = 'ready';
  private penalty = 1;
  private question: Question;
  private zones: ZonePanel[] = [];
  private misses = 0;
  private answeredThisQuestion = false;

  private goals = 0;
  private savesMade = 0;
  private correct = 0;
  private coins = 0;

  private headline = '';
  private message = '';
  private messageTimer = 0;
  private showHint = true;
  private kick = 0;
  private creatureMood = 0;
  private creaturePhase = 0;
  private resultTimer = 0;
  private endButton = { x: 0, y: 0, w: 0, h: 0 };
  private started = false;
  private lastFrame = 0;
  private accumulator = 0;

  readonly debug: Debug = {
    enabled: new URLSearchParams(location.search).get('debug') === '1',
    flightTime: 0,
    speed: 0,
    keeperChoice: '-',
    landing: '-',
    swerve: 0,
  };

  constructor(
    private readonly renderer: Renderer,
    private readonly input: InputController,
    private readonly audio: Audio,
    private readonly text: Strings,
    private readonly assets: Assets,
  ) {
    this.question = makeQuestion(this.tiers.tier);
    this.buildZones();
    this.input.onPress = () => {
      this.audio.unlock();
      if (!this.started) {
        this.started = true;
        this.audio.play('whistle');
      }
      if (this.phase === 'ended') this.handleEndTap();
    };
    this.input.onRelease = (drag) => this.shoot(drag);
    void this.assets;
  }

  // -------------------------------------------------------------------------
  // round flow
  // -------------------------------------------------------------------------

  private buildZones(): void {
    this.zones = this.question.choices.map((value, index) => ({
      value,
      third: index as Third,
      flash: 0,
      correct: value === this.question.answer,
      revealed: false,
    }));
  }

  private nextPenalty(): void {
    if (this.penalty >= config.round.penalties) {
      this.finishRound();
      return;
    }
    this.penalty++;
    this.misses = 0;
    this.answeredThisQuestion = false;
    this.question = makeQuestion(this.tiers.tier);
    this.buildZones();
    this.resetShot();
  }

  private finishRound(): void {
    this.phase = 'ended';
    this.audio.play('whistle');
    if (this.goals === config.round.penalties) {
      this.effects.burstConfetti(this.renderer.width, this.renderer.height);
      this.audio.play('cheer');
    }
  }

  private resetShot(): void {
    this.ball = restBall();
    this.previousBall = { ...this.ball.pos };
    this.keeper = restKeeper();
    this.kick = 0;
    this.phase = 'ready';
    this.headline = '';
  }

  private handleEndTap(): void {
    // The hub owns what happens next; on its own the game simply restarts.
    const point = this.input.drag.start;
    const box = this.endButton;
    const inside =
      point.x >= box.x && point.x <= box.x + box.w && point.y >= box.y && point.y <= box.y + box.h;
    if (!inside) return;
    window.dispatchEvent(new CustomEvent('penalty-sums:exit', { detail: this.summary() }));
    this.restart();
  }

  /**
   * A read-only view of the round, exposed on `window` behind ?debug=1 so the
   * scene can be driven from a test without reaching into private state.
   */
  inspect() {
    return {
      phase: this.phase,
      penalty: this.penalty,
      answer: this.question.answer,
      answerThird: this.zones.findIndex((zone) => zone.correct),
      zones: this.zones.map((zone) => zone.value),
      goals: this.goals,
      saves: this.savesMade,
      correct: this.correct,
      coins: this.coins,
      keeperChoice: this.keeper.choice,
      flightTime: this.debug.flightTime,
      swerve: this.debug.swerve,
    };
  }

  summary() {
    return {
      goals: this.goals,
      saves: this.savesMade,
      correct: this.correct,
      penalties: config.round.penalties,
      coins: this.coins,
    };
  }

  private restart(): void {
    this.penalty = 1;
    this.goals = 0;
    this.savesMade = 0;
    this.correct = 0;
    this.coins = 0;
    this.misses = 0;
    this.answeredThisQuestion = false;
    this.tiers = new TierTracker();
    this.question = makeQuestion(this.tiers.tier);
    this.buildZones();
    this.effects.clear();
    this.message = '';
    this.resetShot();
  }

  // -------------------------------------------------------------------------
  // the shot
  // -------------------------------------------------------------------------

  private shoot(drag: Drag): void {
    if (this.phase !== 'ready' && this.phase !== 'aiming') return;

    const aim = this.aimFromDrag(drag);
    launch(this.ball, {
      targetX: aim.targetX,
      targetY: aim.targetY,
      speed: aim.speed,
      swerve: aim.swerve,
    });
    this.previousBall = { ...this.ball.pos };
    this.phase = 'flight';
    this.kick = 0.0001;
    this.showHint = false;
    this.headline = '';
    this.message = '';

    this.audio.play('kick');
    this.effects.addShake(config.feel.shakeOnStrike);
    this.effects.hitPause();

    this.debug.flightTime = this.ball.flightTime;
    this.debug.speed = aim.speed;
    this.debug.keeperChoice = '-';
    this.debug.landing = `${aim.targetX.toFixed(2)}, ${aim.targetY.toFixed(2)}`;
    this.debug.swerve = aim.swerve;
  }

  /** Turn the gesture into a target on the goal plane. */
  private aimFromDrag(drag: Drag) {
    const halfWidth = config.world.goalWidth / 2;
    const targetX = drag.aim * config.shot.aimSpread * halfWidth;
    const height =
      config.shot.minAimHeight +
      drag.lift * (config.shot.maxAimHeight - config.shot.minAimHeight);
    const targetY = height * config.world.goalHeight;
    const speed =
      config.shot.minSpeed + (config.shot.maxSpeed - config.shot.minSpeed) * clamp01(drag.power);
    const swerve = drag.curve * config.shot.maxSwerve;
    return { targetX, targetY, speed, swerve };
  }

  /** The live preview uses exactly the same mapping as the shot itself. */
  private previewAim(): Scene['aim'] {
    const drag = this.input.drag;
    if (!drag.active || !drag.armed || this.phase === 'flight' || this.phase === 'ended') {
      return { visible: false, power: 0, targetX: 0, targetY: 0, swerve: 0 };
    }
    const aim = this.aimFromDrag(drag);
    return {
      visible: true,
      power: drag.power,
      targetX: aim.targetX,
      targetY: aim.targetY,
      swerve: aim.swerve,
    };
  }

  /** Called the moment the ball reaches the goal plane. */
  private resolveCrossing(crossX: number, crossY: number): void {
    const halfWidth = config.world.goalWidth / 2;
    const inFrame =
      Math.abs(crossX) <= halfWidth - config.world.ballRadius &&
      crossY <= config.world.goalHeight - config.world.ballRadius &&
      crossY > 0;

    if (!inFrame) {
      const hitPost =
        Math.abs(Math.abs(crossX) - halfWidth) < 0.25 ||
        Math.abs(crossY - config.world.goalHeight) < 0.25;
      this.audio.play(hitPost ? 'post' : 'groan');
      // Missing the frame entirely costs nothing at all.
      this.showResult('', this.text.offTarget, -1, 1.4);
      return;
    }

    const third = thirdAt(crossX);
    const zone = this.zones[third];
    const wasSaved = saves(this.keeper, crossX, crossY);
    if (zone) zone.flash = 1;

    if (zone && zone.correct) {
      if (!this.answeredThisQuestion) {
        this.answeredThisQuestion = true;
        this.correct++;
        this.tiers.record(this.misses === 0);
        this.awardCoins(config.round.coinsPerCorrect);
      }
      if (wasSaved) {
        // Getting the maths right must never be punished by physics.
        this.savesMade++;
        this.audio.play('save');
        this.audio.play('groan');
        rebound(this.ball, this.keeper.direction || 1);
        this.showResult('', this.text.savedCorrect, -1, 1.9);
        return;
      }
      this.goals++;
      this.audio.play('net');
      this.audio.play('cheer');
      this.effects.rippleNet();
      this.effects.addShake(config.feel.shakeOnGoal);
      this.awardCoins(config.round.coinsPerGoal);
      this.showResult(this.text.goal, '', 1, 2);
      return;
    }

    // Wrong zone. The keeper may still have got a hand to it; either way the
    // answer was the problem, so that is what the child is told.
    this.misses++;
    if (wasSaved) {
      this.savesMade++;
      this.audio.play('save');
      rebound(this.ball, this.keeper.direction || 1);
    } else {
      this.audio.play('net');
      this.effects.rippleNet();
    }
    this.audio.play('groan');
    const reveal = this.misses >= config.round.revealAfterMisses;
    if (reveal) {
      for (const panel of this.zones) panel.revealed = panel.correct;
      this.tiers.record(false);
      this.showResult('', this.text.answerWas(this.question.answer), -1, 2.6);
      return;
    }
    this.showResult('', this.text.savedWrong, -1, 1.7);
  }

  private awardCoins(amount: number): void {
    this.coins += amount;
    const at = this.renderer.projection.project(this.ball.pos.x, this.ball.pos.y, this.ball.pos.z);
    this.effects.flyNumber(`+${amount}`, { x: at.x, y: at.y }, this.renderer.coinAnchor);
    this.audio.play('coin');
  }

  private showResult(headline: string, message: string, mood: number, seconds: number): void {
    this.headline = headline;
    this.message = message;
    this.messageTimer = seconds;
    this.creatureMood = mood;
    this.creaturePhase = 0;
    this.phase = 'settling';
    this.resultTimer = seconds;
  }

  /** What happens when the result has finished playing. */
  private concludeResult(): void {
    const scoredOrSpent =
      this.headline === this.text.goal || this.misses >= config.round.revealAfterMisses;
    this.creatureMood = 0;
    if (scoredOrSpent) {
      this.nextPenalty();
    } else {
      // Off target, a save, or a miss with attempts left: take it again.
      this.resetShot();
    }
  }

  // -------------------------------------------------------------------------
  // loop
  // -------------------------------------------------------------------------

  start(): void {
    this.lastFrame = performance.now();
    const frame = (now: number) => {
      const raw = Math.min((now - this.lastFrame) / 1000, config.physics.maxFrameTime);
      this.lastFrame = now;
      this.update(raw);
      this.render();
      requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
  }

  private update(frameTime: number): void {
    // Effects own the hit pause, so they run on real time and hand back the
    // time the simulation is allowed to use.
    const usable = this.effects.update(frameTime, this.renderer.height);
    const scale = this.timeScale();
    this.accumulator += usable * scale;

    let steps = 0;
    while (this.accumulator >= config.physics.step && steps < 240) {
      this.previousBall = { ...this.ball.pos };
      this.stepPhysics(config.physics.step);
      this.accumulator -= config.physics.step;
      steps++;
    }

    // Presentation timers run on real time so messages do not crawl in slow
    // motion along with the ball.
    if (this.kick > 0) {
      this.kick = Math.min(1.2, this.kick + frameTime / config.striker.kickDuration);
      if (this.kick >= 1.2) this.kick = 0;
    }
    this.creaturePhase += frameTime / config.creature.jumpDuration;
    for (const zone of this.zones) zone.flash = Math.max(0, zone.flash - frameTime * 1.6);
    if (this.messageTimer > 0) this.messageTimer -= frameTime;

    if (this.phase === 'settling') {
      this.resultTimer -= frameTime;
      if (this.resultTimer <= 0) this.concludeResult();
    }
  }

  /** The last penalty of the round plays in slow motion from the strike. */
  private timeScale(): number {
    if (this.effects.reducedMotion) return 1;
    const lastPenalty = this.penalty >= config.round.slowMotionFrom;
    const inPlay = this.phase === 'flight' || this.phase === 'settling';
    return lastPenalty && inPlay ? config.round.slowMotionScale : 1;
  }

  private stepPhysics(dt: number): void {
    if (!this.ball.flying) return;
    const beforeZ = this.ball.pos.z;
    stepBall(this.ball, dt);

    if (this.phase === 'flight') {
      stepKeeper(this.keeper, this.ball, dt);
      if (this.keeper.choice !== null && this.debug.keeperChoice === '-') {
        this.debug.keeperChoice = ['left', 'centre', 'right'][this.keeper.choice] ?? '-';
      }
      const progress = clamp01(this.ball.age / Math.max(0.01, this.ball.flightTime));
      this.audio.setCrowdSwell(progress);

      if (beforeZ < config.world.goalZ && this.ball.pos.z >= config.world.goalZ) {
        // Interpolate to the exact moment of crossing.
        const span = this.ball.pos.z - beforeZ;
        const t = span > 0 ? (config.world.goalZ - beforeZ) / span : 0;
        const crossX = this.ball.pos.x - this.ball.vel.x * dt * (1 - t);
        const crossY = this.ball.pos.y - this.ball.vel.y * dt * (1 - t);
        this.effects.hitPause(0.04);
        this.audio.setCrowdSwell(0);
        this.resolveCrossing(crossX, crossY);
      }
    }

    // Let the ball run on a little, then stop simulating it.
    if (this.ball.pos.z > config.world.goalZ + 4 || this.ball.pos.z < -6 || this.ball.age > 6) {
      this.ball.flying = false;
    }
  }

  private render(): void {
    const alpha = clamp01(this.accumulator / config.physics.step);
    const drawn: Ball = {
      ...this.ball,
      pos: {
        x: lerp(this.previousBall.x, this.ball.pos.x, alpha),
        y: lerp(this.previousBall.y, this.ball.pos.y, alpha),
        z: lerp(this.previousBall.z, this.ball.pos.z, alpha),
      },
    };

    const scene: Scene = {
      ball: drawn,
      keeper: this.keeper,
      kick: this.kick,
      creatureMood: this.creatureMood,
      creaturePhase: this.creaturePhase,
      zones: this.zones,
      question: this.phase === 'ended' ? '' : this.question.prompt,
      penaltyLabel: this.text.penaltyLabel(this.penalty, config.round.penalties),
      headline: this.headline,
      message: this.messageTimer > 0 ? this.message : '',
      hint:
        this.showHint && this.phase === 'ready' && !this.input.drag.active
          ? this.text.firstShotHint
          : '',
      coins: this.coins,
      ballPastGoal: drawn.pos.z >= config.world.goalZ,
      aim: this.previewAim(),
    };

    this.renderer.draw(scene, this.effects);

    if (this.phase === 'ended') {
      this.endButton = this.renderer.drawEndScreen({
        goals: this.text.endGoals(this.goals, config.round.penalties),
        maths: this.text.endMaths(this.correct, config.round.penalties),
        button: this.text.continueButton,
      });
    }

    if (this.debug.enabled) this.drawDebug();
  }

  private drawDebug(): void {
    const ctx = (this.renderer as unknown as { ctx: CanvasRenderingContext2D }).ctx;
    const predicted = this.ball.flying ? predictedCrossing(this.ball) : { x: 0, y: 0 };
    const lines = [
      `phase ${this.phase}  penalty ${this.penalty}/${config.round.penalties}`,
      `flight ${this.debug.flightTime.toFixed(3)}s  speed ${this.debug.speed.toFixed(1)} m/s`,
      `gravity ${gravity().toFixed(1)}  swerve ${this.debug.swerve.toFixed(2)}`,
      `keeper ${this.debug.keeperChoice}  commit ${(config.keeper.commitAt * 100).toFixed(0)}%`,
      `aimed at ${this.debug.landing}`,
      `heading for ${predicted.x.toFixed(2)}, ${predicted.y.toFixed(2)}`,
      `tier ${this.tiers.tier}  answer ${this.question.answer}`,
    ];
    ctx.save();
    ctx.font = '13px ui-monospace, Menlo, Consolas, monospace';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    ctx.fillStyle = 'rgba(0,0,0,0.62)';
    ctx.fillRect(10, 10, 320, lines.length * 18 + 14);
    ctx.fillStyle = '#c9f24d';
    lines.forEach((line, index) => ctx.fillText(line, 20, 18 + index * 18));
    ctx.restore();
  }
}

const lerp = (a: number, b: number, t: number): number => a + (b - a) * t;
