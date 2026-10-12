"""the run's recording: what was on screen, when, and the structured events behind it.

with a recording directory, every line goes to three files as well as the screen:
  transcript.txt   the lines, each with seconds since the start
  run.cast         asciicast version 2, replayable with: asciinema play run.cast
  events.jsonl     one JSON object per step, for checking a run without reading it
"""

import json
import os
import threading
import time
from datetime import datetime


class Recorder:
    def __init__(self, directory=None, title="sirven rehearsal"):
        self.directory = directory
        self.started = time.monotonic()
        self._lock = threading.Lock()
        self._files = {}
        if directory:
            os.makedirs(directory, exist_ok=True)
            for name in ("transcript.txt", "run.cast", "events.jsonl"):
                self._files[name] = open(os.path.join(directory, name), "w")
            header = {"version": 2, "width": 110, "height": 50, "title": title,
                      "timestamp": int(datetime.now().timestamp())}
            self._files["run.cast"].write(json.dumps(header) + "\n")

    def _elapsed(self):
        return time.monotonic() - self.started

    def say(self, text, who="agent"):
        with self._lock:
            seconds = self._elapsed()
            for line in str(text).split("\n"):
                shown = line if who == "agent" else "%-10s| %s" % (who, line)
                print(shown, flush=True)
                if self._files:
                    self._files["transcript.txt"].write("%7.1f  %s\n" % (seconds, shown))
                    self._files["run.cast"].write(json.dumps([round(seconds, 3), "o", shown + "\r\n"]) + "\n")
            for handle in self._files.values():
                handle.flush()

    def event(self, name, **data):
        if not self._files:
            return
        with self._lock:
            entry = {"seconds": round(self._elapsed(), 3), "event": name}
            entry.update(data)
            self._files["events.jsonl"].write(json.dumps(entry, sort_keys=True) + "\n")
            self._files["events.jsonl"].flush()

    def close(self):
        for handle in self._files.values():
            handle.close()
        self._files = {}
