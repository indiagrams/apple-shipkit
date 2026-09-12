"""Drive a real iPhone over Appium/XCUITest. See docs/UI-AUTOMATION.md.

Import it, do not run it — these are the primitives a device arm is written from:

    exec(open("bin/device-rig/drive.py").read())
    S = "<session id>"                     # from POST /session
    press(S, "home")
    tap_app_icon(S, "MyApp")
    e = find(S, "SpotlightSearchField", kind="TextField"); type_into(S, e, "hello")

⚠ SCORE EVERY ACTION BY ITS CONSEQUENCE, NEVER BY THE RETURN VALUE.
  A tap that lands nowhere returns success with a null value. Check
  `frontmost()`, a log line, or the element's own value afterwards. An HTTP 200
  from /actions means "the request parsed", not "the phone moved".

⚠ WHY PYTHON AND NOT SHELL. zsh does not word-split unquoted expansions, so
  `set -- $COORDS` leaves ONE word, the action body goes out malformed, Appium
  answers 400 and the phone never moves — a silent no-op that looks like a
  missed tap. Build action JSON where a list is a list.

⚠ SEARCH THE WHOLE TREE, NOT THE FIRST N ELEMENTS. An overlay (a search field,
  a sheet, an alert) puts its own window in the document while the window behind
  it is still there. Printing the first ten elements shows you the background and
  invites a confident wrong conclusion.

⚠ SOME STATE IS INVISIBLE TO THE TREE. Checkmarks and focus rings can report
  nothing at all while a screenshot shows them plainly. When a selection mark is
  the thing under test, the screenshot is the instrument.
"""

import base64
import json
import re
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:4723/session/"


def req(sid, path, method="GET", body=None, timeout=120):
    """One call against the session. Returns the parsed body, or a dict carrying
    the HTTP error — never raises, so an arm can decide what a failure means."""
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(
        BASE + sid + path, data=data, method=method,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(r, timeout=timeout) as f:
            return json.loads(f.read().decode())
    except urllib.error.HTTPError as e:
        return {"httperror": e.code, "body": e.read().decode()[:400]}


def source(sid):
    return req(sid, "/source")["value"]


def frontmost(sid):
    """Bundle id of the app in front. The cheapest consequence to check."""
    m = re.search(r'bundleId="([^"]*)"', source(sid))
    return m.group(1) if m else "?"


def screenshot(sid, path):
    open(path, "wb").write(base64.b64decode(req(sid, "/screenshot")["value"]))
    return path


def press(sid, name="home"):
    return req(sid, "/execute/sync", "POST",
               {"script": "mobile: pressButton", "args": [{"name": name}]})


def tap(sid, x, y, hold_ms=90):
    return req(sid, "/actions", "POST", {"actions": [{
        "type": "pointer", "id": "f1", "parameters": {"pointerType": "touch"},
        "actions": [
            {"type": "pointerMove", "duration": 0, "x": x, "y": y},
            {"type": "pointerDown", "button": 0},
            {"type": "pause", "duration": hold_ms},
            {"type": "pointerUp", "button": 0},
        ]}]})


def swipe(sid, x1, y1, x2, y2, ms=400):
    return req(sid, "/actions", "POST", {"actions": [{
        "type": "pointer", "id": "f1", "parameters": {"pointerType": "touch"},
        "actions": [
            {"type": "pointerMove", "duration": 0, "x": x1, "y": y1},
            {"type": "pointerDown", "button": 0},
            {"type": "pause", "duration": 80},
            {"type": "pointerMove", "duration": ms, "x": x2, "y": y2},
            {"type": "pointerUp", "button": 0},
        ]}]})


def find(sid, pattern, kind=r"\w+", tree=None):
    """First element whose tag matches `kind` and whose attributes match
    `pattern`. Returns a dict with the real frame, or None."""
    s = tree if tree is not None else source(sid)
    for m in re.finditer(r"<XCUIElementType(" + kind + r")\b[^>]*>", s):
        tag = m.group(0)
        if re.search(pattern, tag):
            d = dict(re.findall(r'(\w+)="([^"]*)"', tag))
            if "x" in d:
                return {"type": m.group(1),
                        **{k: d.get(k) for k in
                           ("name", "label", "value", "x", "y", "width", "height", "visible")}}
    return None


def center(e):
    return (int(e["x"]) + int(e["width"]) // 2, int(e["y"]) + int(e["height"]) // 2)


def type_into(sid, element, text):
    """Focus an element, then type. The tap is not ceremony: send-keys goes to
    the FOCUSED field, and a field never tapped swallows the text silently."""
    tap(sid, *center(element))
    time.sleep(1.5)
    name = element.get("name") or element.get("label")
    el = req(sid, "/element", "POST", {"using": "accessibility id", "value": name})
    val = el.get("value") or {}
    eid = val.get("ELEMENT") or (list(val.values())[0] if val else None)
    if not eid:
        return {"error": "element not addressable by accessibility id", "detail": el}
    return req(sid, "/element/" + eid + "/value", "POST", {"text": text})


def tap_app_icon(sid, name, settle=4.0):
    """Launch an app the sanctioned way — an icon tap from SpringBoard.
    Returns the frontmost bundle id so the caller can score the consequence."""
    press(sid, "home")
    time.sleep(2)
    m = re.search(r'<XCUIElementTypeIcon[^>]*name="' + re.escape(name) + r'"[^>]*>', source(sid))
    if not m:
        return {"error": "no icon named %r on the current home screen page" % name}
    d = dict(re.findall(r'(\w+)="([^"]*)"', m.group(0)))
    tap(sid, int(d["x"]) + int(d["width"]) // 2, int(d["y"]) + int(d["height"]) // 2)
    time.sleep(settle)
    return frontmost(sid)


def syslog(sid, contains=None):
    """Drain the device syslog buffer. Call once before an action to clear it,
    then again after, so everything you read was caused by what you did."""
    r = req(sid, "/log", "POST", {"type": "syslog"})
    lines = [l.get("message", "") for l in (r.get("value") or [])]
    return [l for l in lines if contains in l] if contains else lines
