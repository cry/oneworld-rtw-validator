# The ExpertFlyer bridge

> **This plan is carried out in `/Users/carey/projects/expertflyer-cli`, not in this repository.**
> It lives here because it is the other half of [`06-mcp-server.md`](06-mcp-server.md) and the two
> share one contract. It needs nothing from this repository except that contract, restated in full
> below, so it can be handed to an agent working only in the ExpertFlyer tree. Neither plan depends
> on the other being done first.

## The problem

`expertflyer-cli` already ships an MCP server: `src/expertflyer/mcp_server.py`, FastMCP, two tools
(`search_availability`, `search_availability_range`), a single-user OAuth provider and
streamable-HTTP in Docker. It is the source of the `claude_ai_Expertflyer` connector on the account.

What it returns is ExpertFlyer's own shape: a segment carries `departureAirport`,
`marketingAirlineCode`, `flightNumber`, and a full airport record on each end. The validator reads a
different shape. Today a model has to rename every field of every segment of every itinerary by
hand, which is token-heavy over a fifty-result search and is a place to make quiet mistakes.

One output format closes that gap.

## Why the conversion belongs there and not here

`mcp_server.py:383 _format_itineraries` already reshapes raw ExpertFlyer segments. Adding an output
format keeps knowledge of ExpertFlyer's scraped wire format in the repository that already tracks
it, and takes a dependency on the validator's input schema, which is stable, versioned and
documented. The reverse direction would put an undocumented third-party format that changes without
notice into a codebase whose data is all committed, dated and offline.

## The contract

The shape this plan produces and plan 06 consumes. It is the itinerary format
`prolog/src/io/json_in.pl` reads and the validator's README documents.

```json
{
  "origin": "LHR",
  "cabin": "economy | business | first",
  "segments": [
    { "n": 1, "type": "flight | surface", "from": "LHR", "to": "JFK",
      "marketingCarrier": "BA", "operatingCarrier": "BA", "flight": "BA117",
      "dep": "2026-09-01T10:25", "arr": "2026-09-01T13:30",
      "stop": "stopover | transfer", "bookingClass": "D" }
  ]
}
```

Rules that matter to the joint:

- Only `from` and `to` are required on a segment. `type` defaults to `flight`.
- Times are **local wall-clock**, `YYYY-MM-DDTHH:MM`. A zone designator is accepted and discarded.
- An eastbound trans-Pacific sector legitimately arrives at an earlier clock time than it departed.
  Only a backwards jump wider than the span of world time zones is a data error.
- `bookingClass` is a single RBD letter. **A missing `bookingClass` is not filled in for rule 5(b).**
  That rule measures the class that was booked, and a filled-in value would report a pass it never
  measured. An unknown class must be absent, never guessed.
- `carrier` is shorthand filling both carrier fields. `marketingCarrier` alone leaves the operator
  unknown rather than assuming no codeshare.

## 1. A `format` parameter on both tools

Add `format: Literal["ef", "rtw"] = "ef"` to `search_availability` (mcp_server.py:282) and
`search_availability_range` (mcp_server.py:319). The default keeps `"ef"`, so nothing that calls the
deployed connector today changes.

`_format_itineraries` gains an `rtw` branch emitting, per itinerary:

```json
{ "segments": [ { "n": 1, "from": "LHR", "to": "JFK",
                  "marketingCarrier": "BA", "operatingCarrier": "BA",
                  "flight": "BA117", "dep": "2026-09-01T10:25",
                  "arr": "2026-09-01T13:30" } ],
  "availability": [ { "n": 1, "classes": [ {"code": "D", "seats": 9} ] } ] }
```

The field mapping is `departureAirport` to `from`, `arrivalAirport` to `to`,
`marketingAirlineCode` to `marketingCarrier`, `operatingAirlineCode` to `operatingCarrier`,
`flightNumber` to `flight`, `departureDateTime` to `dep`, `arrivalDateTime` to `arr`.

Four things the branch must get right:

- **`operatingAirlineCode` of `"**"` means unknown.** Omit `operatingCarrier` entirely rather than
  emit `"**"`. Per the contract, `marketingCarrier` alone leaves the operator unknown, which is what
  is true. `"**"` would be read as a carrier code and fail airline lookup.
- **`bookingClass` is left unset.** ExpertFlyer returns an availability list, not a chosen class.
  Picking one is a decision, not a conversion, and the contract is explicit that a guessed class
  would report a 5(b) pass that was never measured. The codes travel in the sibling `availability`
  field and the caller chooses.
- **The year.** ExpertFlyer returns `MM-DDTHH:MM` with no year. `cli.py:284` prepends `date[:4]`,
  which is wrong for any itinerary crossing 31 December, and this fare runs up to twelve months.
  Derive the year from the search date and roll it forward when the month goes backwards. Put it in
  one helper and have `cli.py` use it too, so the bug is fixed once rather than forked.
- **Drop the bulk.** `departureAirportData` and `arrivalAirportData` carry a full airport record
  each: name, location, timezone region, GMT string, region. The validator resolves airports from
  its own committed table. None of it should cross.

## 2. A cap that says so

The compose loop will drive considerably more ExpertFlyer traffic than a person clicking does. A
seven-sector itinerary over a thirty-day window is 210 date-searches, and `search_availability`
page-loops with **no page cap** (session.py:277-307), while `search_availability_range` fans out
five dates at a time with no rate limiting, no backoff and no `Retry-After` or 429 handling
anywhere. `_check_auth` (session.py:31) also reads HTTP 500 as an expired session and responds with
a fresh password POST to Auth0, so a period of server-side trouble becomes repeated login attempts.
`traffic/auth_flow.md` notes that ExpertFlyer meters queries per account, and the code never reads
that quota. This is your own account.

Rewriting that client is outside this plan. What is in it: a page cap per search and a date cap per
range call, both **surfaced in the result** rather than truncating silently. A truncated result that
does not say so reads as "there is no more availability", which is a different and wrong answer.

If the client is to be left untouched, this step comes out and nothing else in either plan depends
on it.

## 3. A test for the formatter

That repository has no tests at all: no `tests/`, no pytest, no CI, no linter. Not a reason to add a
suite here. But the `rtw` branch is the piece another repository consumes, it is a pure function of
one dict, and it has a date bug in its neighbour. So one `tests/test_format.py` covering the rtw
branch: the field mapping, the `"**"` case, the absent `bookingClass`, and a December to January
search asserting the year rolls forward.

`traffic/availability_response.json` exists locally but is gitignored. Commit a trimmed two-segment
fixture, enough to exercise the mapping and small enough to read.

## 4. Documentation

- `README.md`: `format` on both tools, with the rtw shape and a note that `bookingClass` is
  deliberately absent.
- `CLAUDE.md`: the same, in the architecture notes, plus the year-derivation helper.

## 5. Files

All paths relative to `/Users/carey/projects/expertflyer-cli`.

| file | change |
|---|---|
| `src/expertflyer/mcp_server.py` | `format` on both tools; `rtw` branch in `_format_itineraries`; caps |
| `src/expertflyer/cli.py` | use the shared year helper at `cli.py:284` |
| `tests/test_format.py` | new |
| `tests/fixtures/availability_two_segment.json` | new, trimmed and committed |
| `pyproject.toml` | pytest as a dev dependency |
| `README.md`, `CLAUDE.md` | as above |

Untouched: `auth.py`, and everything in `session.py` except the caps in step 2. No change to the
OAuth provider, the transport, or the deployed connector's default behaviour.

## 6. Verification

```sh
uv run pytest
uv run expertflyer-cli mcp availability LHR JFK 2026-09-01 --format rtw
```

The CLI passthrough at `cli.py:449` exercises the tool without a client, so the rtw shape can be
checked by eye against the contract before anything is redeployed.

Then, with plan 06 also done, paste the `segments` array straight into the `rtw` server's `validate`
tool. It must parse with no edits. That is the whole test of the contract.

## Joint verification, once both plans are done

In Claude Code with both servers registered: validate `lhr_classic.json`, read back the fare basis,
call `classes`, search one sector on ExpertFlyer for those codes with `format="rtw"`, fill the
chosen class into the segment, then validate and earn again.

The check is that rule 5(b) moves from `n/a` to `ok`, and the status-credit total stops reading
`or more`.
