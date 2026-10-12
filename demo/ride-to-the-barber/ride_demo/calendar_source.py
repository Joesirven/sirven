"""calendar read and write-back against a fixture calendar.

SUBSTITUTION. no calendar connector exists in the repo yet, and the demo must not touch Jose's
real calendar before his own live fire. reads come from fixtures/calendar.json; the write-back
goes to a copy of it in the run's state directory, plus a standard calendar file (.ics) any
calendar app can import by hand.
"""

import json
import os
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo


def clock_time(moment):
    return moment.strftime("%-I:%M%p").lower()


class FixtureCalendar:
    def __init__(self, fixture_path, state_dir):
        with open(fixture_path) as handle:
            data = json.load(handle)
        self.zone = ZoneInfo(data["time_zone"])
        self.path = os.path.join(state_dir, "calendar.json")
        if os.path.exists(self.path):
            with open(self.path) as handle:
                data = json.load(handle)
        self.data = data
        self.state_dir = state_dir

    def events(self):
        found = []
        for event in self.data["events"]:
            found.append(dict(event, start=self._at(event["start"]), end=self._at(event["end"])))
        return sorted(found, key=lambda event: event["start"])

    def _at(self, text):
        moment = datetime.fromisoformat(text)
        return moment if moment.tzinfo else moment.replace(tzinfo=self.zone)

    def theirs(self):
        """the user's own events: never one the agent wrote, like an earlier run's ride."""
        return [event for event in self.events() if "written_by" not in event]

    def meeting_at(self, hour, minute=0):
        """the first event that starts at hour:minute, on the earliest day that has one."""
        for event in self.theirs():
            if (event["start"].hour, event["start"].minute) == (hour, minute):
                return event
        return None

    def next_event_matching(self, after, words):
        for event in self.theirs():
            text = (event["title"] + " " + event.get("location", "")).lower()
            if event["start"] >= after and any(word in text for word in words):
                return event
        return None

    def write_back(self, title, start, end, location, description, booking_id):
        event = {
            "event_id": "evt-ride-" + booking_id,
            "title": title,
            "start": start.isoformat(),
            "end": end.isoformat(),
            "location": location,
            "description": description,
            "written_by": "sirven agent (rehearsal)",
        }
        self.data["events"].append(event)
        os.makedirs(self.state_dir, exist_ok=True)
        with open(self.path, "w") as handle:
            json.dump(self.data, handle, indent=2)
            handle.write("\n")
        ics_path = os.path.join(self.state_dir, "ride.ics")
        with open(ics_path, "w", newline="") as handle:
            handle.write(to_ics(event, start, end))
        return event, ics_path


def after_window(meeting, walk_minutes=5, span_minutes=15):
    earliest = meeting["end"] + timedelta(minutes=walk_minutes)
    return earliest, earliest + timedelta(minutes=span_minutes)


def _ics_text(value):
    return value.replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\n", "\\n")


def _fold(line):
    """standard calendar files keep lines to 75 octets; longer ones continue after a space."""
    data = line.encode("utf-8")
    parts = []
    while len(data) > 75:
        cut = 75 if not parts else 74
        while cut > 0 and (data[cut] & 0xC0) == 0x80:
            cut -= 1
        parts.append(data[:cut].decode("utf-8"))
        data = data[cut:]
    parts.append(data.decode("utf-8"))
    return "\r\n ".join(parts)


def to_ics(event, start, end):
    universal = "%Y%m%dT%H%M%SZ"
    lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//sirven//ride rehearsal//EN",
        "BEGIN:VEVENT",
        "UID:%s@sirven.invalid" % event["event_id"],  # literal: the calendar format's unique identifier property
        "DTSTAMP:%s" % datetime.now(timezone.utc).strftime(universal),
        "DTSTART:%s" % start.astimezone(timezone.utc).strftime(universal),
        "DTEND:%s" % end.astimezone(timezone.utc).strftime(universal),
        "SUMMARY:%s" % _ics_text(event["title"]),
        "LOCATION:%s" % _ics_text(event["location"]),
        "DESCRIPTION:%s" % _ics_text(event["description"]),
        "END:VEVENT",
        "END:VCALENDAR",
    ]
    return "\r\n".join(_fold(line) for line in lines) + "\r\n"
