/**
 * Every constant that decides how the game feels lives here.
 *
 * Expect to change these constantly. Nothing outside this file should hold a
 * tuning number; if a value affects feel and it is not here, that is a bug.
 */
export const config = {
  /** Real-world dimensions, in metres. The scene is built in these, never in pixels. */
  world: {
    goalWidth: 7.32,
    goalHeight: 2.44,
    /** Depth of the goal line from the penalty spot. */
    goalZ: 11,
    /** The ball starts here. */
    spotZ: 0,
    ballRadius: 0.11,
    /** Where the striker stands, just behind and beside the ball. */
    strikerX: -0.55,
    strikerZ: -1.15,
    /** Sideline position of the mascot. */
    creatureX: -4.75,
    creatureZ: 8.4,
  },

  camera: {
    x: 0,
    y: 1.6,
    z: -4,
    /** Bigger focal flattens the scene; smaller exaggerates the depth. */
    focal: 12,
    /** Share of the canvas width the goal mouth fills. Sets the pixel scale. */
    goalWidthFraction: 0.62,
    /** Height on screen of the camera's eye line, as a share of canvas height. */
    horizonFraction: 0.4,
  },

  /** The background plate, fitted behind the projected scene. */
  stadium: {
    zoom: 1.06,
    /** Which line of the plate sits on the projected goal line. */
    groundAnchor: 0.645,
  },

  shot: {
    /**
     * Horizontal speed towards the goal, in metres per second.
     *
     * The brief asked for 18 to 30, but over an eleven metre run those give
     * flight times of 0.61s down to 0.37s, and the same brief asks for 0.55s
     * to 0.95s. Flight time is the one that decides how the shot feels, so it
     * wins: this range produces 0.85s at the softest and 0.55s at the hardest.
     */
    minSpeed: 12.9,
    maxSpeed: 20,
    gravity: -9.8,
    /** Arcade snap. Tune this before anything else, it dominates the feel. */
    gravityScale: 1.6,
    /** Lateral acceleration from a curved drag, metres per second squared. */
    maxSwerve: 9,
    /** Drag distance, in fractions of the canvas height, for zero and full power. */
    minDragFraction: 0.035,
    maxDragFraction: 0.34,
    /** Below this, the release is treated as an accidental tap and does nothing. */
    deadDragFraction: 0.03,
    /**
     * Sideways reach at full aim, as a share of half the goal width. Over one
     * on purpose: a shot can be dragged wide of the post, which is what makes
     * aiming a skill rather than a three-way switch.
     */
    aimSpread: 1.12,
    /** Sideways drag, as a share of the longest drag, for full aim. */
    aimSpan: 0.75,
    /** Downward drag below which the shot stays along the ground. */
    liftDead: 0.05,
    /** Downward drag, as a share of the longest drag, from lowest to highest. */
    liftSpan: 0.62,
    /** Aim height at rest and at full lift, as a share of goal height. */
    minAimHeight: 0.16,
    maxAimHeight: 0.92,
    /** How strongly the bow of the drag path becomes swerve. */
    curveGain: 1.2,
    /** Ball spin during flight, in turns per second at full power. */
    spinRate: 2.4,
    trailLength: 7,
  },

  keeper: {
    /** Share of the flight before the keeper commits. Never lower this. */
    commitAt: 0.45,
    /** Weight given to the third the ball is actually heading for. */
    biasToBall: 0.55,
    /** Above this share of the goal height, no dive can reach the ball. */
    unreachableHeight: 0.6,
    /** Sideways travel of a full dive, in metres. */
    diveReach: 2.05,
    diveLift: 0.46,
    diveRotation: 0.82,
    /** Seconds the dive takes to reach full stretch. */
    diveDuration: 0.34,
    squashDuration: 0.22,
    /** How fast the ball comes back off a save, as a share of its speed. */
    reboundSpeed: 0.42,
    /** Standing height of the keeper sprite, in metres. */
    height: 1.62,
  },

  striker: {
    /** Standing height of the striker sprite, in metres. */
    height: 1.44,
    /** Seconds the kick lunge lasts. */
    kickDuration: 0.28,
  },

  creature: {
    height: 1.15,
    jumpHeight: 0.55,
    jumpDuration: 0.75,
  },

  /** The three answer panels floating in the goal mouth. */
  zones: {
    /** Height of a panel's centre, as a share of the goal height. Kept above
     * the keeper's head so the panels never hide the dive. */
    height: 0.8,
    /** Panel size in metres. */
    size: 0.62,
    /** How far in front of the goal line they float, so the net never eats them. */
    standOff: 0.45,
  },

  round: {
    penalties: 5,
    /** From this penalty on, the strike runs in slow motion. */
    slowMotionFrom: 5,
    slowMotionScale: 0.35,
    /** Wrong answers on one question before the answer is revealed. */
    revealAfterMisses: 3,
    coinsPerGoal: 25,
    coinsPerCorrect: 10,
  },

  feel: {
    /** Screen shake, in pixels at the canvas reference height. */
    shakeOnStrike: 6,
    shakeOnGoal: 15,
    shakeDecay: 5.5,
    /** Seconds the picture freezes at the moment of contact. */
    hitPause: 0.06,
    netRippleDuration: 0.75,
    netRippleAmplitude: 5,
    confettiCount: 130,
  },

  physics: {
    /** Fixed timestep. Physics never runs off the raw frame delta. */
    step: 1 / 120,
    /** Never simulate more than this much time in one frame. */
    maxFrameTime: 0.25,
  },

  render: {
    /** Design height the pixel-sized values above are quoted against. */
    referenceHeight: 800,
    maxDevicePixelRatio: 2,
    /**
     * The keeper and the striker were generated in separate passes, so their
     * lighting does not quite agree. The keeper reads cooler, so it is warmed
     * a touch at draw time rather than the art being regenerated.
     */
    keeperWarmth: 0.06,
  },

  audio: {
    masterVolume: 0.55,
    crowdBedVolume: 0.12,
  },
} as const;

export type Config = typeof config;
