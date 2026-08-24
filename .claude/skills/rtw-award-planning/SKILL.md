---
name: rtw-award-planning
description: Plan and check a oneworld Explorer round-the-world itinerary — validate it against Rule 3015, find which booking classes the fare sells in, search ExpertFlyer for space in those classes, and price what the ticket earns. Use when the user is building, checking or costing an RTW itinerary, asks whether a routing is a legal Explorer fare, asks which RBD to search for, or asks what a round-the-world ticket would earn in points or status credits.
---

# Planning a oneworld Explorer fare

Two servers answer between them. The `rtw` server validates and prices; it is offline,
deterministic and always available. The ExpertFlyer connector searches live inventory; it is
optional, and this skill still works without it — you simply stop after the third step.

Neither server calls the other. You are the join between them.

## The loop

**1. Get a verdict and a fare basis.**

Call `validate` with either a `route` string or a list of `segments`. Give one or the other, never
both.

```
validate { "route": "LHR-BA-JFK-AA-X/LAX-JL-NRT-CX-HKG-QR-X/DOH-QR-LHR", "cabin": "business" }
```

`X/` marks a transfer; a bare airport code is a stopover. The reply names the verdict, every rule
broken with the clause it came from, and the fare basis — `DONE3` above, meaning a business fare
over three continents.

Read the verdict carefully. `indeterminate` is not `valid`: it means the input left out something a
rule needed, and it names what. Warnings on their own still leave a verdict of `valid`.

Pass `"checks": true` when the user asks *why* something passed, or by how much a cap was cleared.
It is off by default because it is forty times the length of the verdict.

**2. Fix what it named, and ask again.**

Every violation cites a clause. `rtw://rules` is the transcription of the tariff, so any answer can
be checked against the rule it came from rather than taken on trust. Read it before telling a user
a rule says something.

Do not guess at limits. `ruleset` carries every cap, the eligible carriers, the metro city codes,
the routing grammar and the fare-basis table.

**3. Ask which classes the fare sells in.**

```
classes { "route": "...", "cabin": "business" }
```

Per sector, `classes` holds the applicable codes and `alternates` holds codes the notes of 5(b)
allow only where something about the flight is true that an itinerary cannot show — a cabin not
offered, a Middle East sector on QR. A business fare on a published basis is usually one letter:
`D`.

This is what makes the search worth running. Searching every class returns mostly seats the fare
cannot be sold in.

**4. Search for space in those classes** — only if the ExpertFlyer connector is available.

```
search_availability { "origin": "LHR", "destination": "JFK", "date": "2026-09-01",
                      "classes": ["D"], "format": "rtw" }
```

`format: "rtw"` returns segments already shaped for step 5. Without it you get ExpertFlyer's own
field names and have to rename them yourself.

Search one sector at a time and stop when you have what the user asked for. A seven-sector journey
over a month is hundreds of queries against a metered account.

**5. Validate and price with the classes filled in.**

Put the chosen class on each segment as `bookingClass` and call `validate` again, then `earn`.

Rule 5(b) moves from `n/a` to `ok`, because there is now a class to measure. `earn` stops saying
"or more", because every sector can be priced.

```
earn { "segments": [...], "programs": ["qff"] }
```

## Rules that will bite you

**Never invent a booking class.** If the user has not said what class a sector is sold in, leave
`bookingClass` out. Rule 5(b) measures the class that was booked, and a filled-in value reports a
pass that was never measured. The same goes for a carrier: `marketingCarrier` alone leaves the
operator unknown, which is true, rather than asserting there is no codeshare.

**Times are local wall-clock.** `2026-09-01T10:25` at the airport clock. A zone designator is
accepted and then discarded. An eastbound trans-Pacific sector really does arrive earlier than it
departed.

**A missing number is not zero.** On the earning side, `value: null` with `known` set to `unknown`,
`range` or `published_as_none` are three different things, and none of them is nought. A total
flagged `lowerBound` is incomplete. Say so rather than reporting a figure that looks whole.

**Do not rank programmes.** `earn` returns sub-totals per programme and no ordering between them.
Comparing a mile with a status point needs a valuation, and a valuation is an opinion. Give the user
the figures and let them choose.

**Two questions, two tools.** `validate` asks whether the fare may be sold. `earn` asks what the
ticket is worth. A journey that cannot be sold can still be priced, and a valid one can be
unpriceable. Do not report one as though it answered the other.

## Getting an airport code

`airports { "q": "sydney" }` searches the table by code, city or name. Use it rather than guessing:
the validator knows 4,161 airports and will reject a code that is not one of them.
