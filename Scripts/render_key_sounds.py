"""Render the two key-specific WAVs from each original click (requires ffmpeg)."""
from pathlib import Path
import math
import random
import struct
import subprocess
import wave

SOUNDS = Path(__file__).resolve().parents[1] / "Shared" / "TypingSounds"
PRESETS = ("ios-style-click", "soft-tap", "soft-knock", "hollow-tap", "crisp-tick", "mechanical")
SEMITONES = {"space": 2, "backspace": -3}


def render_ios_style_click():
    # An original short plastic tap: a dry attack and two muted resonances.
    rate = 24000
    duration = 0.027
    rng = random.Random(812)
    noise = 0.0
    signal = []
    for i in range(round(rate * duration)):
        t = i / rate
        noise += 0.48 * (rng.uniform(-1, 1) - noise)
        body = sum(gain * math.exp(-t / decay) * math.sin(2 * math.pi * hz * t)
                   for hz, gain, decay in [(740, 1.0, 0.0036), (1320, 0.57, 0.0028)])
        transient = 0.75 * noise * math.exp(-t / 0.0016)
        signal.append((body + transient) * (1 - math.exp(-t / 0.00025))
                      * min(1, (duration - t) / 0.002))
    gain = 0.32 * 32767 / max(map(abs, signal))
    with wave.open(str(SOUNDS / "ios-style-click.wav"), "wb") as out:
        out.setparams((1, 2, rate, 0, "NONE", "not compressed"))
        out.writeframes(struct.pack(f"<{len(signal)}h", *(round(x * gain) for x in signal)))


def main():
    render_ios_style_click()
    for preset in PRESETS:
        source = SOUNDS / f"{preset}.wav"
        with wave.open(str(source)) as sound:
            rate = sound.getframerate()
        for key, semitones in SEMITONES.items():
            shifted_rate = round(rate * 2 ** (semitones / 12))
            subprocess.run([
                "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", str(source),
                "-af", f"asetrate={shifted_rate},aresample={rate}", "-c:a", "pcm_s16le",
                "-fflags", "+bitexact", "-map_metadata", "-1", str(SOUNDS / f"{preset}-{key}.wav"),
            ], check=True)


if __name__ == "__main__":
    main()
