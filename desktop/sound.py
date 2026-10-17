"""Synthesises an accelerating steam-train chuff followed by a chime whistle, and plays it with afplay."""
import math, os, random, struct, wave

from paths import DATA
import osutil

PATH = os.path.join(DATA, "train.wav")
RATE = 22050


def _mix(buf, sig, at):
    start = int(at * RATE)
    if len(buf) < start + len(sig):
        buf.extend([0.0] * (start + len(sig) - len(buf)))
    for i, s in enumerate(sig):
        buf[start + i] += s


def _chuff(dur=0.14):
    n = int(RATE * dur)
    out, lp, lp2 = [], 0.0, 0.0
    for i in range(n):
        t = i / RATE
        lp += 0.35 * (random.uniform(-1, 1) - lp)   # hissy steam
        lp2 += 0.04 * (random.uniform(-1, 1) - lp2)  # low rumble
        env = min(1, t / 0.006) * math.exp(-t / 0.035)
        thump = math.sin(2 * math.pi * 70 * t) * math.exp(-t / 0.05)
        out.append(env * (lp * 1.4 + lp2 * 5 + thump * 0.8))
    return out


def _whistle(dur, f1, f2):
    n = int(RATE * dur)
    out = []
    for i in range(n):
        t = i / RATE
        env = min(1, t / 0.04) * min(1, (dur - t) / 0.15)
        bend = 1 - 0.04 * math.exp(-t / 0.08)  # pitch starts flat, settles
        s = 0.0
        for f in (f1, f2):
            ph = 2 * math.pi * f * bend * t
            s += math.sin(ph) + 0.35 * math.sin(2 * ph) + 0.15 * math.sin(3 * ph)
        s += random.uniform(-1, 1) * 0.12  # breath
        out.append(0.22 * env * (1 + 0.03 * math.sin(2 * math.pi * 7 * t)) * s)
    return out


def build():
    random.seed(3)
    buf = []
    t, gap = 0.0, 0.30
    for _ in range(7):
        _mix(buf, _chuff(), t)
        t += gap
        gap = max(0.15, gap * 0.85)
    t += 0.05
    _mix(buf, _whistle(0.35, 587, 740), t)
    _mix(buf, _whistle(0.9, 587, 740), t + 0.5)
    peak = max(abs(s) for s in buf) or 1
    os.makedirs(os.path.dirname(PATH), exist_ok=True)
    with wave.open(PATH, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s / peak * 0.9)) * 32000)) for s in buf))


def play():
    if not os.path.exists(PATH):
        build()
    osutil.play_wav(PATH)


if __name__ == "__main__":
    build()
    play()
