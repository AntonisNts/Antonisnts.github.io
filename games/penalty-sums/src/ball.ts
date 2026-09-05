import { config } from './config';

export type Vec3 = { x: number; y: number; z: number };

export type Launch = {
  /** Where the shot is aimed on the goal plane, in metres. */
  targetX: number;
  targetY: number;
  /** Speed towards the goal, metres per second. */
  speed: number;
  /** Lateral acceleration through the flight, metres per second squared. */
  swerve: number;
};

export type Ball = {
  pos: Vec3;
  vel: Vec3;
  swerve: number;
  flying: boolean;
  /** Seconds since the strike. */
  age: number;
  /** How long the ball will take to reach the goal plane. */
  flightTime: number;
  spin: number;
  spinRate: number;
  /** Recent positions, newest last, for the trail. */
  trail: Vec3[];
  /** Set once the ball has been beaten back by the keeper. */
  rebounding: boolean;
};

export const gravity = (): number => config.shot.gravity * config.shot.gravityScale;

export function restBall(): Ball {
  return {
    pos: { x: 0, y: config.world.ballRadius, z: config.world.spotZ },
    vel: { x: 0, y: 0, z: 0 },
    swerve: 0,
    flying: false,
    age: 0,
    flightTime: 0,
    spin: 0,
    spinRate: 0,
    trail: [],
    rebounding: false,
  };
}

/**
 * Launch the ball so that, left alone, it crosses the goal plane exactly
 * where the player aimed. Swerve bends the path on the way without moving
 * that arrival point, which is why the aim indicator can draw a curved arc
 * and still be honest — and why swerve beats a keeper who reads the ball's
 * heading rather than its destination.
 */
export function launch(ball: Ball, shot: Launch): void {
  const distance = config.world.goalZ - ball.pos.z;
  const time = distance / shot.speed;
  const g = gravity();

  ball.vel.z = shot.speed;
  ball.vel.x = (shot.targetX - ball.pos.x) / time - 0.5 * shot.swerve * time;
  ball.vel.y = (shot.targetY - ball.pos.y - 0.5 * g * time * time) / time;
  ball.swerve = shot.swerve;
  ball.flying = true;
  ball.rebounding = false;
  ball.age = 0;
  ball.flightTime = time;
  ball.spinRate = config.shot.spinRate * (shot.speed / config.shot.maxSpeed);
  ball.trail = [];
}

export function stepBall(ball: Ball, dt: number): void {
  if (!ball.flying) return;
  ball.vel.y += gravity() * dt;
  ball.vel.x += ball.swerve * dt;
  ball.pos.x += ball.vel.x * dt;
  ball.pos.y += ball.vel.y * dt;
  ball.pos.z += ball.vel.z * dt;
  ball.age += dt;
  ball.spin += ball.spinRate * dt;

  // Bounce off the turf rather than sinking through it.
  if (ball.pos.y < config.world.ballRadius) {
    ball.pos.y = config.world.ballRadius;
    ball.vel.y = Math.abs(ball.vel.y) * 0.42;
    ball.vel.x *= 0.86;
    ball.vel.z *= 0.86;
  }

  ball.trail.push({ ...ball.pos });
  if (ball.trail.length > config.shot.trailLength) ball.trail.shift();
}

/**
 * Where the ball is heading, judged only from where it is and how it is
 * moving right now. The keeper uses this, so it can be fooled by swerve.
 */
export function predictedCrossing(ball: Ball): { x: number; y: number } {
  const remaining = config.world.goalZ - ball.pos.z;
  if (ball.vel.z <= 0.01) return { x: ball.pos.x, y: ball.pos.y };
  const time = remaining / ball.vel.z;
  return {
    x: ball.pos.x + ball.vel.x * time,
    y: ball.pos.y + ball.vel.y * time + 0.5 * gravity() * time * time,
  };
}

/** Turn a save into a rebound out of the goalmouth. */
export function rebound(ball: Ball, sideways: number): void {
  ball.vel.z = -Math.abs(ball.vel.z) * config.keeper.reboundSpeed;
  ball.vel.x = sideways * 3.4;
  ball.vel.y = Math.abs(ball.vel.y) * 0.35 + 2.2;
  ball.swerve = 0;
  ball.rebounding = true;
}
