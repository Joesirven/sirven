"""turn the spoken request into an intent.

SUBSTITUTION. in a live fire the personal agent's language model reads the request. the
rehearsal reads it with fixed patterns so the run is the same every time; it understands the
demo sentence and small variations of it (another hour, another budget, another service).
"""

import re

SERVICES = ("waymo", "uber", "lyft")


class NotUnderstood(Exception):
    pass


def parse(sentence):
    text = sentence.lower()
    place = re.search(r"\bto (?:the |my )?([a-z]+)", text)
    anchor = re.search(r"after my (\d{1,2})(?::(\d{2}))?\s*(am|pm)\b", text)
    budget = re.search(r"under \$(\d+)(?:\.(\d{2}))?", text)
    if not (place and anchor and budget):
        raise NotUnderstood("the rehearsal understands requests shaped like: book me a ride to the "
                            "barber after my 2pm meeting, Waymo preferred, under $25")
    hour = int(anchor.group(1)) % 12 + (12 if anchor.group(3) == "pm" else 0)
    preferred = [name.title() for name in SERVICES if re.search(r"\b%s preferred\b|\bprefer %s\b" % (name, name), text)]
    return {
        "destination_place": place.group(1),
        "after_meeting_at": (hour, int(anchor.group(2) or 0)),
        "preferred_providers": preferred,
        "budget_ceiling_minor": int(budget.group(1)) * 100 + int(budget.group(2) or 0),
    }
