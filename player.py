import os
import sys
import time
import winsound

path, hb, my_id, seconds, stamp = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]), sys.argv[5]

try:
    os.remove(stamp)
except OSError:
    pass
winsound.PlaySound(path, winsound.SND_FILENAME | winsound.SND_ASYNC)
with open(stamp, "w") as fh:
    fh.write("1")
t0 = time.time()
while time.time() - t0 < seconds:
    time.sleep(0.05)
    try:
        with open(hb) as fh:
            if fh.read().strip() != my_id:
                break
        if time.time() - os.path.getmtime(hb) > 2.5:
            break
    except OSError:
        break
winsound.PlaySound(None, 0)
