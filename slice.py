import sys
import wave

src, dst, start_ms, end_ms = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])

with wave.open(src, "rb") as r:
    rate = r.getframerate()
    channels = r.getnchannels()
    width = r.getsampwidth()
    total = r.getnframes()
    start = max(0, min(total, int(start_ms * rate / 1000)))
    end = max(start, min(total, int(end_ms * rate / 1000)))
    r.setpos(start)
    frames = r.readframes(end - start)

with wave.open(dst, "wb") as w:
    w.setnchannels(channels)
    w.setsampwidth(width)
    w.setframerate(rate)
    w.writeframes(frames)
