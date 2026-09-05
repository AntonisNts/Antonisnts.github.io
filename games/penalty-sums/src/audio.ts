/**
 * Sound.
 *
 * Every cue the game needs is wired here and called from the moment it
 * happens, because retrofitting audio timing later is painful. The sounds
 * themselves are synthesised placeholders — swap each `play` body for a
 * decoded sample and nothing else in the game has to change.
 */
import { config } from './config';

export type Cue = 'kick' | 'net' | 'save' | 'cheer' | 'groan' | 'coin' | 'whistle' | 'post';

export class Audio {
  private ctx: AudioContext | null = null;
  private master: GainNode | null = null;
  private crowdGain: GainNode | null = null;
  private crowdSource: AudioBufferSourceNode | null = null;
  private muted = false;

  /** Must be called from inside a real touch or click, or the tab stays silent. */
  unlock(): void {
    if (this.ctx) {
      void this.ctx.resume();
      return;
    }
    const Ctor = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!Ctor) return;
    this.ctx = new Ctor();
    this.master = this.ctx.createGain();
    this.master.gain.value = config.audio.masterVolume;
    this.master.connect(this.ctx.destination);
    this.startCrowdBed();
  }

  setMuted(muted: boolean): void {
    this.muted = muted;
    if (this.master) this.master.gain.value = muted ? 0 : config.audio.masterVolume;
  }

  get isMuted(): boolean {
    return this.muted;
  }

  /** A steady bed of crowd noise that swells while the ball is in the air. */
  private startCrowdBed(): void {
    const ctx = this.ctx;
    const master = this.master;
    if (!ctx || !master) return;
    const seconds = 4;
    const buffer = ctx.createBuffer(1, ctx.sampleRate * seconds, ctx.sampleRate);
    const data = buffer.getChannelData(0);
    let low = 0;
    for (let i = 0; i < data.length; i++) {
      // Brown-ish noise reads as a distant crowd far better than white noise.
      low = (low + Math.random() * 2 - 1) * 0.5;
      const fade = Math.min(1, Math.min(i, data.length - i) / (ctx.sampleRate * 0.3));
      data[i] = low * 0.6 * fade;
    }
    const source = ctx.createBufferSource();
    source.buffer = buffer;
    source.loop = true;
    const band = ctx.createBiquadFilter();
    band.type = 'bandpass';
    band.frequency.value = 620;
    band.Q.value = 0.7;
    const gain = ctx.createGain();
    gain.gain.value = config.audio.crowdBedVolume;
    source.connect(band).connect(gain).connect(master);
    source.start();
    this.crowdSource = source;
    this.crowdGain = gain;
  }

  /** Swell the crowd as the ball travels. `amount` runs 0 to 1. */
  setCrowdSwell(amount: number): void {
    if (!this.crowdGain || !this.ctx) return;
    const target = config.audio.crowdBedVolume * (1 + amount * 3.2);
    this.crowdGain.gain.setTargetAtTime(target, this.ctx.currentTime, 0.08);
  }

  play(cue: Cue): void {
    const ctx = this.ctx;
    const master = this.master;
    if (!ctx || !master) return;
    const now = ctx.currentTime;

    switch (cue) {
      case 'kick':
        this.thump(now, 150, 0.09, 0.9);
        this.noiseBurst(now, 0.05, 2200, 0.35);
        break;
      case 'net':
        this.noiseBurst(now, 0.22, 1400, 0.3);
        this.thump(now, 90, 0.16, 0.5);
        break;
      case 'post':
        this.tone(now, 420, 0.25, 0.4, 'triangle');
        break;
      case 'save':
        this.noiseBurst(now, 0.12, 900, 0.4);
        this.thump(now, 120, 0.1, 0.6);
        break;
      case 'cheer':
        this.crowdRoar(now, 1.5, 0.55);
        break;
      case 'groan':
        this.crowdRoar(now, 1.1, 0.3, true);
        break;
      case 'coin':
        this.tone(now, 940, 0.09, 0.28, 'square');
        this.tone(now + 0.07, 1360, 0.12, 0.24, 'square');
        break;
      case 'whistle':
        this.tone(now, 2050, 0.16, 0.22, 'sine', 40);
        this.tone(now + 0.17, 2250, 0.2, 0.2, 'sine', 40);
        break;
    }
  }

  private tone(
    at: number,
    frequency: number,
    duration: number,
    volume: number,
    type: OscillatorType = 'sine',
    vibrato = 0,
  ): void {
    const ctx = this.ctx;
    const master = this.master;
    if (!ctx || !master) return;
    const osc = ctx.createOscillator();
    osc.type = type;
    osc.frequency.setValueAtTime(frequency, at);
    if (vibrato > 0) {
      osc.frequency.setValueAtTime(frequency + vibrato, at + duration * 0.5);
      osc.frequency.setValueAtTime(frequency, at + duration);
    }
    const gain = ctx.createGain();
    gain.gain.setValueAtTime(0, at);
    gain.gain.linearRampToValueAtTime(volume, at + 0.01);
    gain.gain.exponentialRampToValueAtTime(0.0001, at + duration);
    osc.connect(gain).connect(master);
    osc.start(at);
    osc.stop(at + duration + 0.05);
  }

  private thump(at: number, frequency: number, duration: number, volume: number): void {
    const ctx = this.ctx;
    const master = this.master;
    if (!ctx || !master) return;
    const osc = ctx.createOscillator();
    osc.type = 'sine';
    osc.frequency.setValueAtTime(frequency, at);
    osc.frequency.exponentialRampToValueAtTime(frequency * 0.35, at + duration);
    const gain = ctx.createGain();
    gain.gain.setValueAtTime(volume, at);
    gain.gain.exponentialRampToValueAtTime(0.0001, at + duration);
    osc.connect(gain).connect(master);
    osc.start(at);
    osc.stop(at + duration + 0.05);
  }

  private noiseBurst(at: number, duration: number, cutoff: number, volume: number): void {
    const ctx = this.ctx;
    const master = this.master;
    if (!ctx || !master) return;
    const length = Math.max(1, Math.floor(ctx.sampleRate * duration));
    const buffer = ctx.createBuffer(1, length, ctx.sampleRate);
    const data = buffer.getChannelData(0);
    for (let i = 0; i < length; i++) {
      data[i] = (Math.random() * 2 - 1) * (1 - i / length);
    }
    const source = ctx.createBufferSource();
    source.buffer = buffer;
    const filter = ctx.createBiquadFilter();
    filter.type = 'lowpass';
    filter.frequency.value = cutoff;
    const gain = ctx.createGain();
    gain.gain.value = volume;
    source.connect(filter).connect(gain).connect(master);
    source.start(at);
  }

  private crowdRoar(at: number, duration: number, volume: number, falling = false): void {
    const ctx = this.ctx;
    const master = this.master;
    if (!ctx || !master) return;
    const length = Math.floor(ctx.sampleRate * duration);
    const buffer = ctx.createBuffer(1, length, ctx.sampleRate);
    const data = buffer.getChannelData(0);
    let low = 0;
    for (let i = 0; i < length; i++) {
      low = (low + Math.random() * 2 - 1) * 0.5;
      const t = i / length;
      const shape = falling ? Math.max(0, 1 - t) ** 1.5 : Math.sin(Math.PI * Math.min(1, t * 1.2));
      data[i] = low * shape;
    }
    const source = ctx.createBufferSource();
    source.buffer = buffer;
    const filter = ctx.createBiquadFilter();
    filter.type = 'bandpass';
    filter.frequency.value = falling ? 380 : 780;
    filter.Q.value = 0.6;
    const gain = ctx.createGain();
    gain.gain.value = volume;
    source.connect(filter).connect(gain).connect(master);
    source.start(at);
  }

  dispose(): void {
    this.crowdSource?.stop();
    void this.ctx?.close();
    this.ctx = null;
  }
}
