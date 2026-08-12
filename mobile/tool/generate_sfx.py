"""Synthesise SpeedQuiz's cue set.

Design rules, derived from what was wrong with the old set (fundamentals at
1.2-1.7 kHz, every file mastered to -6 dBFS):

  * Fundamentals live between 170 Hz and 800 Hz. Nothing sits in the 1-4 kHz
    band where the ear is most sensitive and where "harsh" comes from.
  * Additive sine partials with per-partial decay - higher partials fade
    fastest, which is what makes a real struck object sound warm instead of
    electronic.
  * Raised-cosine attack (never an instant edge) and an exponential tail that
    is faded to true zero, so nothing clicks.
  * One-pole lowpass to round off the remaining edge.
  * Mastered to ~ -20 dBFS RMS with peaks near 0.4. Cues sit under the voice
    of the app rather than on top of it.
  * Everything is tuned to one C-major/A-minor family, so two cues landing at
    once are consonant rather than accidental dissonance.
"""
import wave
from pathlib import Path
import numpy as np

SR = 44100
OUT = str(Path(__file__).resolve().parent.parent / "assets" / "audio")

# Equal temperament, A4 = 440.
A3, C4, D4, E4, F3, G4, A4, B4 = 220.00, 261.63, 293.66, 329.63, 174.61, 392.00, 440.00, 493.88
C5, D5, E5, G5, A5 = 523.25, 587.33, 659.25, 783.99, 880.00


def t(dur):
    return np.arange(int(SR * dur)) / SR


def env(n, attack, decay, hold=0.0):
    """Raised-cosine attack, optional hold, exponential decay to silence."""
    a = int(SR * attack)
    h = int(SR * hold)
    e = np.ones(n)
    if a > 0:
        e[:a] = 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, a))
    tail = n - a - h
    if tail > 0:
        e[a + h:] = np.exp(-np.linspace(0, decay, tail))
    return e


def tone(freq, dur, partials=(1.0,), decay=5.0, attack=0.008, hold=0.0, detune=0.0):
    """Additive tone. `partials` are relative amplitudes of harmonics 1..n."""
    x = t(dur)
    n = len(x)
    out = np.zeros(n)
    for i, amp in enumerate(partials, start=1):
        if amp == 0:
            continue
        # Higher partials decay faster - the core of a warm, struck timbre.
        e = env(n, attack, decay * (1 + 0.55 * (i - 1)), hold)
        out += amp * e * np.sin(2 * np.pi * freq * i * x)
        if detune:
            out += amp * 0.5 * e * np.sin(2 * np.pi * freq * i * (1 + detune) * x)
    return out


def lowpass(sig, cutoff):
    """One-pole lowpass - takes the edge off without ringing."""
    a = np.exp(-2 * np.pi * cutoff / SR)
    out = np.empty_like(sig)
    acc = 0.0
    for i, s in enumerate(sig):
        acc = (1 - a) * s + a * acc
        out[i] = acc
    return out


def place(canvas, sig, at):
    """Mix `sig` into `canvas` starting at `at` seconds."""
    i = int(SR * at)
    end = min(len(canvas), i + len(sig))
    canvas[i:end] += sig[: end - i]
    return canvas


def master(sig, peak=0.42, fade_ms=12.0):
    """Fade the tail to true zero, then normalise to a modest peak."""
    f = int(SR * fade_ms / 1000)
    if f < len(sig):
        sig[-f:] *= np.linspace(1, 0, f)
    m = np.abs(sig).max()
    if m > 0:
        sig = sig / m * peak
    return sig


def write(name, sig):
    sig = np.clip(sig, -1.0, 1.0)
    # Triangular dither: keeps the long quiet tails from quantising into buzz.
    dither = (np.random.random(len(sig)) - np.random.random(len(sig))) / 32768.0
    pcm = np.clip((sig + dither) * 32767.0, -32768, 32767).astype("<i2")
    with wave.open(f"{OUT}\\{name}.wav", "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())

    rms = np.sqrt(np.mean(sig ** 2))
    spec = np.abs(np.fft.rfft(sig * np.hanning(len(sig))))
    freqs = np.fft.rfftfreq(len(sig), 1 / SR)
    power = spec ** 2
    centroid = (freqs * power).sum() / (power.sum() + 1e-12)
    print(f"{name:9} {len(sig) / SR * 1000:6.0f}ms  peak {np.abs(sig).max():.2f}  "
          f"rms {20 * np.log10(rms + 1e-12):6.1f} dBFS  f0 {freqs[np.argmax(spec)]:5.0f} Hz  "
          f"centroid {centroid:5.0f} Hz")


# --- tap: the button tick. Plays constantly, so it has to be nearly subliminal.
tap = tone(A4, 0.10, partials=(1.0, 0.22, 0.06), decay=9.0, attack=0.004)
write("tap", master(lowpass(tap, 2600), peak=0.30))

# --- tick: the countdown. Repeats once a second under gameplay - a soft wooden
#     knock, an octave and a half below the old 1658 Hz whistle.
tick = tone(E4, 0.075, partials=(1.0, 0.30, 0.10), decay=14.0, attack=0.003)
write("tick", master(lowpass(tick, 2200), peak=0.24))

# --- correct: a warm rising fourth. Reward, not alarm.
correct = np.zeros(len(t(0.34)))
place(correct, tone(C5, 0.20, partials=(1.0, 0.30, 0.10), decay=6.0), 0.0)
place(correct, tone(G5, 0.26, partials=(1.0, 0.26, 0.08), decay=5.0) * 0.9, 0.075)
write("correct", master(lowpass(correct, 3400), peak=0.40))

# --- wrong: a soft descending minor third, low and mellow, with a slow beat
#     from the detune. Deliberately not a buzzer.
wrong = np.zeros(len(t(0.42)))
place(wrong, tone(A3, 0.24, partials=(1.0, 0.20, 0.05), decay=5.0, detune=0.004), 0.0)
place(wrong, tone(F3, 0.32, partials=(1.0, 0.18, 0.04), decay=4.0, detune=0.004) * 0.95, 0.085)
write("wrong", master(lowpass(wrong, 1500), peak=0.36))

# --- streak: a bright but round major arpeggio.
streak = np.zeros(len(t(0.60)))
for i, f in enumerate((C5, E5, G5)):
    place(streak, tone(f, 0.34, partials=(1.0, 0.28, 0.10, 0.04), decay=6.5) * (0.85 + 0.05 * i),
          i * 0.075)
write("streak", master(lowpass(streak, 4000), peak=0.40))

# --- finish: a Cmaj9 swell. Slow attack so a run ends on a breath, not a stab.
finish = np.zeros(len(t(1.90)))
for f, amp in ((C4, 1.0), (E4, 0.75), (G4, 0.65), (B4, 0.45), (D5, 0.35)):
    place(finish, tone(f, 1.80, partials=(1.0, 0.22, 0.07), decay=3.2, attack=0.14) * amp, 0.0)
write("finish", master(lowpass(finish, 2800), peak=0.42))

# --- unlock: a four-note bell rise for achievements. The one cue allowed to
#     sparkle - bell partials are inharmonic, hence the explicit ratios.
unlock = np.zeros(len(t(1.60)))
bell = (1.0, 0.0, 0.35, 0.0, 0.16, 0.0, 0.07)
for i, f in enumerate((G4, C5, E5, G5)):
    place(unlock, tone(f, 1.10, partials=bell, decay=4.0, attack=0.006) * (0.75 + 0.06 * i),
          i * 0.105)
place(unlock, tone(C5, 1.00, partials=(1.0, 0.3, 0.12), decay=3.0, attack=0.10) * 0.30, 0.30)
write("unlock", master(lowpass(unlock, 5200), peak=0.42))


# --- ambient: an 8 s pad that loops seamlessly. Every partial and every LFO is
#     an exact integer number of cycles per loop, so the join is sample-perfect.
AMB_SR = 22050
AMB_LEN = 8.0


def ambient():
    n = int(AMB_SR * AMB_LEN)
    x = np.arange(n) / AMB_SR
    base = 1.0 / AMB_LEN  # a full cycle across the loop

    def snap(f):
        return round(f / base) * base

    out = np.zeros(n)
    voices = ((110.0, 0.55, 3), (164.81, 0.34, 5), (220.0, 0.26, 7), (329.63, 0.12, 11))
    for freq, amp, lfo_cycles in voices:
        f = snap(freq)
        lfo = 0.72 + 0.28 * np.sin(2 * np.pi * lfo_cycles * base * x)
        out += amp * lfo * np.sin(2 * np.pi * f * x)
        out += amp * 0.30 * lfo * np.sin(2 * np.pi * snap(f * 2) * x)

    # Filter in the frequency domain, not with a running one-pole: circular
    # convolution preserves the loop's exact periodicity, so the seam stays
    # sample-perfect. A time-domain filter leaves the tail mid-transient and
    # the join thumps once per loop.
    freqs = np.fft.rfftfreq(n, 1 / AMB_SR)
    response = 1.0 / np.sqrt(1.0 + (freqs / 900.0) ** 2)
    filt = np.fft.irfft(np.fft.rfft(out) * response, n)

    filt = filt / np.abs(filt).max() * 0.30
    dither = (np.random.random(n) - np.random.random(n)) / 32768.0
    pcm = np.clip((filt + dither) * 32767.0, -32768, 32767).astype("<i2")
    with wave.open(f"{OUT}\\ambient.wav", "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(AMB_SR)
        w.writeframes(pcm.tobytes())
    print(f"{'ambient':9} {AMB_LEN * 1000:6.0f}ms  peak {np.abs(filt).max():.2f}  "
          f"rms {20 * np.log10(np.sqrt(np.mean(filt ** 2))):6.1f} dBFS  seamless loop")


ambient()
