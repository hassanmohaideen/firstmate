#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/firstmate-preference-responses.json"

python3 - "$FIXTURE" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    cases = json.load(stream)

required = {
    "chat-defaults",
    "chat-no-address-nautical",
    "chat-name-plain",
    "chat-combined-plain",
    "chat-positive-tone",
    "chat-serious-bad-news",
    "chat-security",
    "chat-privacy",
    "chat-escalation",
    "bearings-defaults",
    "bearings-plain-no-address",
    "relay-defaults",
    "relay-public-name",
    "relay-private-name",
}
by_id = {case["id"]: case for case in cases}
if set(by_id) != required:
    raise SystemExit("preference response fixture coverage changed")

nautical = re.compile(r"\b(ahoy|aye|shipshape|under way|underway|charted|landed)\b", re.I)
known_addresses = ("Captain", "Alex")
serious = {"serious-bad-news", "security", "privacy", "escalation"}

for case in cases:
    output = case["output"]
    address = case["address"]
    if address is not None and not re.search(rf"\b{re.escape(address)}\b", output, re.I):
        raise SystemExit(f'{case["id"]}: selected direct address is absent')
    if address is None:
        for candidate in known_addresses:
            if re.search(rf"\b{re.escape(candidate)}\b", output, re.I):
                raise SystemExit(f'{case["id"]}: direct address was not omitted')
    for forbidden in case.get("forbidden_names", []):
        if re.search(rf"\b{re.escape(forbidden)}\b", output, re.I):
            raise SystemExit(f'{case["id"]}: private name was published')

    seasoned = bool(nautical.search(output))
    if seasoned != case["nautical"]:
        raise SystemExit(f'{case["id"]}: tone does not match its observable contract')
    if case["context"] in serious and seasoned:
        raise SystemExit(f'{case["id"]}: serious output contains nautical roleplay')

    if case["channel"] == "bearings":
        headings = re.findall(r"^\*\*(.+?)\*\*$", output, re.M)
        if headings != case["headings"] or len(headings) != 4:
            raise SystemExit(f'{case["id"]}: Bearings bucket contract changed')

if by_id["relay-public-name"].get("name_source") != "public-thread":
    raise SystemExit("public Relay name provenance is absent")
if by_id["relay-private-name"].get("name_source") != "private-home":
    raise SystemExit("private Relay name provenance is absent")

print("ok - generated preference response fixtures")
PY
