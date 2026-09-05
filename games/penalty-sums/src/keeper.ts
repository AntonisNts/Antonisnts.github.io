import { config } from './config';
import type { Ball } from './ball';
import { predictedCrossing } from './ball';

/** The goal mouth is three vertical zones; the keeper picks one of them. */
export type Third = 0 | 1 | 2;

export type KeeperState = {
  /** The third the keeper went for, once it has committed. */
  choice: Third | null;
  /** 0 to 1 through the dive. */
  dive: number;
  /** -1, 0 or 1: which way the body is thrown. */
  direction: -1 | 0 | 1;
  /** Seconds since landing, used for the squash. */
  landed: number;
  /** What the keeper thought the ball was doing when it committed. */
  readAt: { x: number; y: number } | null;
};

export function restKeeper(): KeeperState {
  return { choice: null, dive: 0, direction: 0, landed: 0, readAt: null };
}

/** Which third of the goal a horizontal position falls in. */
export function thirdAt(x: number): Third {
  const edge = config.world.goalWidth / 6;
  if (x < -edge) return 0;
  if (x > edge) return 2;
  return 1;
}

/** Centre of a third, in metres. */
export function thirdCentre(third: Third): number {
  const step = config.world.goalWidth / 3;
  return (third - 1) * step;
}

/**
 * Commit to a third.
 *
 * Weighted towards where the ball actually looks to be heading, so the keeper
 * feels like it is reading the shot rather than rolling dice, but beatable:
 * the rest of the weight is spread across the other two thirds.
 */
export function chooseThird(headingFor: Third): Third {
  const weights: [number, number, number] = [0, 0, 0];
  const spread = (1 - config.keeper.biasToBall) / 2;
  for (let i = 0; i < 3; i++) weights[i as Third] = spread;
  weights[headingFor] = config.keeper.biasToBall;

  let roll = Math.random();
  for (let i = 0; i < 3; i++) {
    roll -= weights[i as Third];
    if (roll <= 0) return i as Third;
  }
  return 2;
}

/** Called every physics step while the ball is in the air. */
export function stepKeeper(keeper: KeeperState, ball: Ball, dt: number): void {
  if (keeper.choice === null) {
    // Never earlier than this, or the player cannot feel that their aim
    // mattered; never later, or no dive would be readable.
    if (ball.age >= ball.flightTime * config.keeper.commitAt) {
      const read = predictedCrossing(ball);
      keeper.readAt = read;
      keeper.choice = chooseThird(thirdAt(read.x));
      keeper.direction = keeper.choice === 1 ? 0 : keeper.choice === 0 ? -1 : 1;
    }
    return;
  }
  if (keeper.dive < 1) {
    keeper.dive = Math.min(1, keeper.dive + dt / config.keeper.diveDuration);
  } else {
    keeper.landed += dt;
  }
}

/**
 * Did the keeper get it?
 *
 * Only if it went the right way, and only below the height a dive can reach.
 * Top corners always beat the keeper — that is what teaches placement.
 */
export function saves(keeper: KeeperState, crossX: number, crossY: number): boolean {
  if (keeper.choice === null) return false;
  if (keeper.choice !== thirdAt(crossX)) return false;
  return crossY <= config.keeper.unreachableHeight * config.world.goalHeight;
}
