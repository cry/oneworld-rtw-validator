# oneworld-rtw-planner

A SWI-Prolog engine that answers one question: **is this round-the-world itinerary a valid oneworld
Explorer fare?** When it is not, the answer names every rule the itinerary breaks, and why. The
engine validates and explains. It does not build or optimise itineraries.

The ruleset is oneworld Explorer, Tariff RWR2 Rule 3015, version 27 FEB 26.
[`parsed-rules-aug-2026.md`](parsed-rules-aug-2026.md) holds the transcription. Every violation
cites the clause it came from, so you can compare any answer with that text.

There are four ways to run it: a CLI, an HTTP service, an **MCP server** for a model, and a
**static page that carries the validator with it**. The page runs the same Prolog, compiled to
WebAssembly. The browser applies the rules itself instead of asking a server. The page needs no
server at all, and it is the version published to GitHub Pages. See
[In the browser](#in-the-browser) and [MCP server](#mcp-server).

This file is how to use it. [`DESIGN.md`](DESIGN.md) is why it is built the way it is. It covers the
rule readings that are not obvious, the shape of the code, and the real purpose of the test suite.

## Requirements

Install SWI-Prolog 9 or later (`brew install swi-prolog`). You need no third-party packs: the HTTP
server, the CSV reader and plunit all ship with SWI. The airport table is committed, so a fresh clone
runs offline.

You need node only to rebuild the generated files, and only if you edit them. Those files are the
stylesheet, the map bundle, the WebAssembly pair and the loyalty earning tables. All of them are
committed. The validator never touches npm when you run it, test it or deploy it. The built page
does not touch it either. See [Web UI](#web-ui).

## Use

```sh
# run the service and open the UI at http://localhost:8080
swipl prolog/cli.pl -- serve --port 8080

# validate one itinerary, human-readable
swipl prolog/cli.pl -- validate prolog/test/fixtures/lhr_classic.json

# the same report as JSON
swipl prolog/cli.pl -- validate prolog/test/fixtures/mut_dup_sector.json --json

# list every rule that was measured, not just the ones that were broken
swipl prolog/cli.pl -- validate prolog/test/fixtures/lhr_classic.json --checks

# check a routing with no dates at all
swipl prolog/cli.pl -- route "NYC-BA-X/LON-QR-BKK//SIN-QF-SYD-QF-X/LAX-AA-NYC" --cabin business

# what the same ticket would earn, in every registered loyalty programme
swipl prolog/cli.pl -- earn prolog/test/fixtures/lhr_classes.json

# answer a model over stdin and stdout instead of a person
swipl prolog/mcp.pl
```

A report names three things in order: the verdict, then every rule broken with the clause it came
from, then the fare basis.

```
INVALID — 1 error
  [4(i)]       error           Sector NRT-HKG flown twice in the same direction (segments 4 and 6).
Fare basis: DONE3 (3 continents, business)
```

Exit codes: `0` valid, `1` invalid or indeterminate, `2` malformed input, `3` internal error.

### Routings

Most of the ruleset is about *where* the journey goes, not when. Thus you can write an itinerary the
way a fare is written down, with no dates anywhere:

```
NYC-BA-X/LON-QR-BKK//SIN-QF-SYD-QF-X/LAX-AA-NYC
```

| Notation | Meaning |
|---|---|
| `-` | separates points; whitespace and commas do too |
| `X/JFK`, `XJFK` | a transfer at that point |
| `JFK` | a stopover — that is what the absence of `X/` means |
| `A//B` | that leg is a 4(g) surface sector, at the passenger's own expense |
| `BA` between two points | the carrier of the leg that follows |

Length tells the token kinds apart: airline designators are two characters and place codes are
three. Thus `XIY` is Xi'an rather than a transfer at `IY`, and nothing needs escaping.

A few 4(j) affiliates do have three-letter designators. Those count as carriers only when no airport
or city answers to the same code. `HAC` is both Hokkaido Air System and Hachijojima, so a routing
reads it as the airport. An itinerary flown on HAC gets no routing at all. The alternative is a
string that parses back into a different journey.

[`prolog/data/cities.pl`](prolog/data/cities.pl) lists the metropolitan city codes (`NYC`, `LON`,
`TYO`, …), and `/api/ruleset` serves the same table. The table runs both ways.

Forwards, a city code resolves to a representative airport. Thus `NYC-LON` and `JFK-LHR` are the same
journey. Backwards, an airport knows which metropolitan area it belongs to. 4(i) is written in these
city terms ("the same city pairs / sectors cannot be flown more than once"), and they are what 4(c)
and 4(d) mean by a point. Three results follow:

- `LON-NYC` flown out of Heathrow and back into Gatwick is one city pair flown twice.
- A stop at Gatwick on a journey that began at Heathrow is travel via the origin.
- A finish at Gatwick is a finish at home, not an origin-destination surface sector.

The table leaves out the airports that IATA holds as their own city: Paris Beauvais, Westchester,
Kitchener/Waterloo. This is deliberate. To group places that the fare rule keeps separate invents
violations, and that is the more expensive way to be wrong.

The validator measures a 4(c) origin–destination gap against the seven relations that the clause
permits, and names it in the report. The gap does **not** count toward the maximum of 16 segments in
4(h). See [Reading the rule](DESIGN.md#reading-the-rule-where-it-is-ambiguous).

You can give the same information per segment instead. Put `"stop": "transfer" | "stopover"` on the
segment that *arrives* at the point. `layover`, `connection` and `transit` all mean `transfer`. A
declaration beats the clock, because the traveller knows what was booked. It does not beat a surface
sector. Where the two disagree, the report gives a warning rather than a silent decision.

Every itinerary carries a `mode`, either `full` or `routing`. `full` is the default, and the only
mode that accepts times. Routing mode has no calendar. Rules 6 and 7 then have nothing to measure,
and the report names them in its `notChecked` list. `notChecked` is not the same as `indeterminate`,
which means that the input left out data the rule needs. Neither one is a pass, and both the CLI and
the UI show them.

```
$ swipl prolog/cli.pl -- route "LHR-BA-X/JFK-AA-X/LAX-QF-X/SYD-QF-X/SIN-BA-LHR"
INVALID — 1 error
  [8]          error           The journey has 0 stopovers. It needs at least 2.
Not checked — 1 rule this input cannot answer:
  [7]          Return travel from the last stopover must commence within 12 months of departure, …
Checks — 1 failed, 16 ok, 1 not run, 7 n/a. Re-run with --checks to list them.
```


### What it earns

What a ticket earns is a separate question. A separate operation answers it over the same annotated
itinerary, and it runs no fare rules. A journey that cannot be sold can still be priced for what it
earns. A valid journey can be unpriceable.

```
$ swipl prolog/cli.pl -- earn prolog/test/fixtures/lhr_classes.json
Qantas Frequent Flyer
  25,500 Qantas Points, 660 Status Credits
  [1]   LHR-JFK     ok         4,000 Qantas Points, 100 Status Credits
                               Business (all flights) · 2,501 to 3,500 miles · 3,442 mi
  [2]   JFK-LAX     ok         3,125 Qantas Points, 100 Status Credits
                               Business (all flights) · East Coast USA/Canada and West Coast USA/Canada · 2,469 mi
  …
  These figures are an estimate. The airline's own calculator is authoritative.
  bands table read 2026-08-11 from https://www.qantas.com/en-au/frequent-flyer/calculators/…
```

Every line says which category it resolved, from which row, which route basis priced it, and the
measured distance of the sector. This is the earn register, the counterpart of the check register in
[What passed, and by how much](#what-passed-and-by-how-much).

The earn register is on by default and the check register is not. A points figure looks as though
something *calculated* it. This figure came from a table with no version, no clause numbers and no
notice period. The fetch date follows the totals for the same reason.

**Who sold the sector decides which table prices it.** The two registered programmes read their
tables in different ways. Qantas works from region pairs and mileage bands. Asia Miles works from
distance zones for Cathay's own flights, and from a percentage of the distance flown for its 25
partners. [`DESIGN.md`](DESIGN.md#what-the-ticket-earns) sets out both models. It explains why a
class alone sometimes cannot settle a rate, and shows how the answer says so.

**A membership tier changes the answer, and says where.** `"members": {"qff": {"tier": "gold"}}`
adds the Qantas status bonus: 50% at Silver, 75% at Gold, 100% at Platinum. The bonus reaches Qantas
Points and not Status Credits. That split comes from the `bonus_applies` flag on each currency, not
from a conditional anywhere. The bonus is also a benefit of flying Qantas rather than of holding a
card. Thus the same journey carries a bonus on one sector and none on the next. Each figure shows
the split, as in `23,625 Qantas Points (13,500 + 10,125 Gold)`.

A tier the programme does not publish is refused. The alternative is a quiet price at the base rate. A member who mistyped the tier
cannot tell that from having no status at all.

**A sector that cannot be priced never reads as zero.** A sector comes back `undecided` in three
cases: the input gave no class, the operating carrier is unnamed, or the category depends on a
table that is not loaded. The journey total then reads "0 Qantas Points or more (5 sectors unpriced)". A
smaller number would look complete. A rate that a table publishes as a dash is a third thing again.
It reads "no Status Credits", which is a fact rather than a gap.

You can ask for more than one programme at once. The reply carries sub-totals per programme and **no
ranking between them**. A comparison of a mile with a Status Point needs a valuation, and a valuation
is an opinion. Every number here traces back to a row. See
[`PLANS/05-loyalty-earning.md`](PLANS/05-loyalty-earning.md) for the design and what is still
missing.

### What passed, and by how much

"No rule was broken" is a claim about coverage, and a reader has no way to test it. A
fare-construction tool also gets asked by how much a cap was cleared. Thus every report carries a
**check register** beside the violations. The register gives one line per rule, and says what that
rule measured.

```
$ swipl prolog/cli.pl -- validate prolog/test/fixtures/lhr_classic.json --checks
VALID
Checks — 18 ok, 7 n/a:
  [4(e)]       ok        Intercontinental sectors              Each continent has a limit on flig…
  [4(h)]       ok        Segment count                         The journey has 7 segments. The ru…
  [4(i)]       ok        Repeated sectors                      The journey flies 7 sectors. It fl…
  [4(l)]       n/a       Australian city pairs                 The journey has no flight inside A…
  [5(b)]       n/a       Booking codes                         No segment states the class it is …
  [7]          ok        Maximum stay                          16 days pass between the first fli…
  [8]          ok        Stopovers                             The journey has 4 stopovers. It ne…
```

Every line is written to be read once: short sentences, one fact each, and common words. Continents
are spelled the way a person says them, not the way the table keys them. `europe_middle_east` is a
key, "Europe & Middle East" is a place. The report carries its own table of those names. Thus the
page never has to guess at a name, and never has to wait for a second request before it shows the
first report.

A rule can come out in four ways other than pass or fail, and each stays distinct on purpose.
`undecided` means that the input left data out. `not run` means that the input *mode* cannot answer
the rule. `n/a` means that the itinerary never touches the rule at all: 4(l) with no Australian
sectors is not a restriction cleared.

The report withholds the whole register when the input has errors. Caps measured over an itinerary
that did not parse describe a journey nobody submitted.

### Web UI

`swipl prolog/cli.pl -- serve` serves the page in [`web/`](web/) at `/`. The same directory is a
static site that works with no server behind it at all — see [In the browser](#in-the-browser). The
report is the page. On a wide screen the form takes a sidebar and the answer takes the rest. There
are two ways to enter a journey, on two tabs. They are two different jobs, not one job at two levels
of detail:

* **Routing** — one line, `LHR-BA-JFK-AA-X/LAX-JL-NRT-CX-HKG-QR-LHR`, sent as `{"route": …}` for
  Prolog to parse. A routing that parses fills in the Segments tab from the reading the validator
  made, so you can refine it without retyping. The field wraps instead of scrolling sideways, which
  the grammar allows for free. Whitespace is a separator, so a routing broken across lines parses
  exactly as one line does.
* **Segments** — the flight-by-flight table, sent as `{"mode": …, "segments": […]}`. It holds
  airport typeahead (accent-folded, so `sao paulo` finds São Paulo and `belem` finds Belém), a
  per-segment stop-kind column, a booking class, a fare family, and a switch for dates and times.
  With no clock, the page hides the time columns rather than offer them and then refuse them. The
  page hides the fare-family column the same way when no registered earning programme prices one.
  It learns that from the validator rather than decide it alone. This is the one view a sidebar
  cannot hold: thirteen columns, 1,262px with dates and times shown. So the tab gives the form the
  whole page and moves the answer underneath. When you close the tab, both go back. The panels
  animate between the two arrangements rather than jump.

Some columns hold a value that the whole ticket tends to share: the two carrier codes, the booking
class, the fare family and the kind of connection. These columns **fill down** the way the columns of
a spreadsheet do. The focused cell carries a small square at its corner.

Drag that square over the rows underneath, and the page copies the value into every row it covers.
To reach the last segment in one step, press <kbd>Ctrl</kbd>+<kbd>D</kbd>.

A fill writes only where typing is allowed. Thus a surface sector keeps its empty carrier, and the
last segment keeps its empty stop. The columns that identify one sector have no handle: the
airports, the flight number and the times. A fill down those columns can only describe a journey nobody
can fly.

**Mkt** and **Op** also fill *across* to each other, because a sector nobody codeshared has the same
code in both. A drag down and across at once fills the rectangle, and puts a whole ticket on one
carrier in one gesture. No other neighbouring columns mean the same kind of thing, so no others fill
sideways.

The abbreviated headings say what they stand for on hover. **Mkt** is the marketing carrier, whose
code is on the ticket. **Op** is the operating carrier, whose aircraft flies it.

The two tabs are two ways of writing one journey. Thus **when you open either tab, the page converts
what is in the other**. The `routing` operation writes the table out as one line. The same
annotation pass that the validator uses reads a routing back into the table. The page converts
nothing when the two already agree. That is what stops a round trip through a tab from deleting a
date or a flight number, neither of which a routing can express.

Sometimes the itinerary cannot be written as a routing at all. This happens when a point is neither
a transfer nor a stopover, or when a carrier code is also an airport code. The Routing tab then says
which point and why. It never quietly promotes the point and changes what the journey means.

**Help** in the masthead opens a panel. The panel explains what a oneworld Explorer fare is, what
this tool answers, and how to drive the page. The description of the fare is prose. Every figure in
it comes from the ruleset the validator reports: the continent and flight counts, the stay limit,
the cabins, the carrier count and the routing grammar. Thus there is no second copy to fall out of
date.

Cabin and passengers sit above the tabs. They describe the fare rather than the routing, and they
survive a change of tab. The report panel gives the verdict, the fare basis, and each violation with
its citation and evidence. It also gives **the route drawn as a map**, and an expandable **Rules
evaluated** register of every rule measured and what it measured. That includes the rules this input
cannot answer. They read `not run` in the register, and the report does not call them out on
their own.

The register is collapsed by default, because it runs four times the length of the verdict it
supports. `ok` is the quietest thing in it. On a valid itinerary, `ok` is every row, and colour on
all of them would leave nothing for the one row that is not. When you edit the form after a verdict,
the page marks the report as out of date. A stale answer never looks current.

When you validate, the page scrolls the report into view if the report is not already there. Under
the full-width Segments table the report is otherwise below the fold. When the report is already in
view, the page does not move, and on a wide screen in the Routing tab it always is. When the page
does scroll, a **Back to the segments** button floats over the answer until the form is on screen
again. Thus the page that moved itself also offers the way back.

**The earning panel** is a panel of its own, because earning is a different question and a different
operation answers it. An itinerary that cannot be sold can still be priced for what it earns. A
valid itinerary can be unpriceable. Every registered programme gets a section, built from the list
the validator gives. Thus the page names no programme, no currency, no fare family and no tier of
its own.

The section heading holds the name of the programme and its totals, and is always on screen. When
you open the section, it adds everything that makes those totals checkable: the figure for each
sector with the source row underneath it, the estimate caveat, and the tables with the dates they
were read. That per-segment register is the earn register, the counterpart of the check register.
The panel groups the sectors it cannot price by the reason why. Thus a journey where nothing
resolved reads as one fact rather than sixteen.

**A membership tier lives inside the programme that publishes it.** `"members": {"qff": {"tier":
"gold"}}` comes from a control in the Qantas section, not from a row of settings above the panel.
The tier is a fact about the relationship between the traveller and that one airline. When you
change it, the page re-prices without re-validating, because the itinerary did not change. The page
lists the programmes and never ranks them. A comparison of a mile with a Status Point needs a
valuation, and a valuation is an opinion.

**The route map** sits in the report, under the rules the journey broke.
[`web/map.src.js`](web/map.src.js) draws it from the coordinates already in `annotations`. Each
segment gets one great-circle arc, dashed for a surface sector. Stopovers get filled markers and
transfers get hollow ones. When you hover a connection in the panel beside the map, the same airport
lights up on the map.

**The itinerary lives in the URL.** Thus you can paste a routing into a message, and the reader gets
back a validated report. A link that you open fills in the form, picks the right tab, and validates.

| Parameter | Holds |
|---|---|
| `r` | the routing box, verbatim |
| `s` | the segment table, base64url JSON — only when it was typed rather than parsed from `r` |
| `t=s` | the Segments tab was the one being looked at |
| `c`, `p` | cabin and passengers, only when not the default |
| `b`, `f` | booking class and fare family, one character per segment, `-` for a gap |
| `g` | which earning programme sections are open, only when not all of them |
| `m` | membership tiers, as `qff:gold`, comma-separated |

```
?r=LHR-BA-JFK-AA-X/LAX-JL-NRT-CX-HKG-CX-BKK-QR-X/DOH-QR-LHR
?r=LON-BA-NYC-AA-X/DFW-AA-LAX-QF-SYD//MEL-QF-X/SIN-BA-LON&c=economy&p=adult%2Bchild
?r=LHR-CX-HKG-CX-NRT-JL-LAX-BA-LHR&b=DKJD&f=-F
```

**Colour scheme** is a three-way control in the header: Auto, Light, Dark. Auto follows the OS and
stores nothing. Thus a machine that you never told otherwise keeps following the OS.

## Building

The table that follows lists files that are generated and **committed**.
`data/generated/airports.pl` is committed for the same reason: a clone runs offline, and any change
shows up as a reviewable diff. Nothing at runtime needs node, and nothing in the Docker build needs
it.

| Generated | From | By |
|---|---|---|
| `web/app.css` | `web/app.src.css` | Tailwind CLI |
| `web/map.js` | `web/map.src.js` + `d3-geo`, `topojson-client`, `world-atlas` | esbuild |
| `web/rtw.pvm` | every `.pl` under `prolog/`, via `prolog/wasm.pl` | `prolog/tools/build_image.mjs` |
| `web/vendor/swipl-bundle-no-data.js` | the `swipl-wasm` package | copied verbatim |
| `web/rtw.build.json` | a digest of the above two inputs | `prolog/tools/build_image.mjs` |
| `prolog/data/earn/qff/*.pl` | the captures in `prolog/data/earn/sources/` | `prolog/tools/build_qff_tables.mjs` |
| `prolog/data/earn/cx/*.pl` | the same | `prolog/tools/build_cx_tables.mjs` |

```sh
npm install                # once
npm run build              # rebuild everything in the table above
npm run css                # or just the stylesheet
npm run map                # or just the map bundle
npm run wasm               # or just the WebAssembly pair
npm run earn:qff           # or just the Qantas earning tables
npm run earn:cx            # or just the Asia Miles earning tables
npm run css:watch          # leave running while working on styles
npm run check:contrast     # WCAG check over the palette, no browser needed
npm run test:wasm          # the browser build answers what the native one answers
```

If you change a class in `web/index.html` or `web/app.js` and forget to rebuild, the page shows
without that style. If you change a rule and forget to rebuild, the page validates against the *old*
rules. The second is worse, because nothing looks wrong. `npm run build` and then
`git status --porcelain -- web/` finds both, and the Pages workflow refuses to deploy without it.

The server reads `web/` into memory **at load time**. A change to any of these files thus needs a
restart before it shows up. `--dev` turns that off:

```sh
swipl prolog/cli.pl -- serve --dev        # or: RTW_DEV_ASSETS=1 swipl prolog/daemon.pl …
```

Each request then re-reads the file from the build directory, and replies `Cache-Control: no-store`.
An edit plus a browser reload is the whole loop. If a file has gone, the server prints a warning at
startup and falls back to the copy in the program. `--dev` is off unless you ask for it, because the
path it re-reads from is the one baked in at compile time. That path is right on the machine that
compiled it and nowhere else.

**CAUTION: Do not set `--dev` in production.** The container runs read-only, with no filesystem
access in the request path. That is possible only because the page is read into the program.

Both fonts are bundled under [`web/fonts/`](web/fonts/) rather than fetched from a CDN. The service
must run offline and read-only, and a font request can be the only outbound call the page makes. The
fonts are OFL-licensed. See [`web/fonts/NOTICE.md`](web/fonts/NOTICE.md).

## In the browser

The page never asks a server whether an itinerary is valid. It runs the validator itself: SWI-Prolog
compiled to WebAssembly. The page loads an image built from the same `.pl` files the container runs.
No rule is reimplemented in JavaScript, so there is no second copy of a rule to fall out of step
with the first.

**What it costs.** About 1.3 MB gzipped, in two files:

| File | Raw | Gzipped |
|---|---|---|
| `web/vendor/swipl-bundle-no-data.js` | 2.5 MB | 865 KB |
| `web/rtw.pvm` | 416 KB | (already compressed) |

The image carries the Prolog library with it. Thus the stock `swipl-web.data` is not shipped at all,
and this pair is about 700 KB smaller than the sources plus the standard library. The image boots in
about 50 ms. A sixteen-segment itinerary then validates in about a millisecond, which is faster than
the round trip it replaces.

[`DESIGN.md`](DESIGN.md#in-the-browser-webassembly) covers what the WebAssembly build constrains,
and how the two engines are held to the same answers.

### GitHub Pages

`web/` is the site. Every build output in it is committed, and it uses no absolute paths. Thus you
can serve it from anywhere, including `https://<user>.github.io/<repo>/`. Every path on the page is
relative for that reason. An absolute `/app.css` works behind the service and returns 404 under a
project subpath.

[`.github/workflows/pages.yml`](.github/workflows/pages.yml) runs the Prolog suite. It rebuilds every
generated file, and stops if the result differs from what was committed. It runs the parity test and
the contrast check. Then it publishes `web/`. The freshness check is the one that matters. A stale
`rtw.pvm` publishes rules that are not the ones in the source tree, and nothing downstream notices.

Point Pages at Actions once, by hand: **Settings → Pages → Build and deployment → Source: GitHub
Actions**.

To look at the static site locally, serve the directory with any static server:

```sh
python3 -m http.server 8000 --directory web      # then http://localhost:8000/
```

## MCP server

`swipl prolog/mcp.pl` answers the [Model Context Protocol](https://modelcontextprotocol.io) over
stdin and stdout, so a model can validate an itinerary, read back which rule it broke, fix it and
ask again. It is a fourth front end over the same `report/5` term the CLI prints, and it holds no
rule logic of its own. The protocol is in [`prolog/src/mcp.pl`](prolog/src/mcp.pl); the operations
it answers are in [`prolog/src/ops.pl`](prolog/src/ops.pl), which is the same table the browser
reaches through `wasm.pl`.

Register it with any MCP client. There is no port, no socket and no configuration: the validator
holds no credentials and reads no network, so a session is a pipe to a process that exits when the
pipe closes.

```json
{ "mcpServers": {
    "rtw": { "command": "swipl",
             "args": ["/path/to/oneworld-rtw-planner/prolog/mcp.pl"] } } }
```

Seven tools, named after the operations they run, so one vocabulary covers the CLI subcommands, the
HTTP paths, the browser ops and these.

| Tool | Answers |
|---|---|
| `validate` | May this be sold as an Explorer fare, and if not, which rule stops it |
| `earn` | What the ticket earns, per programme and per sector. Runs no fare rules |
| `classes` | Which booking codes 5(b) sells this fare in, one sector at a time |
| `routing` | The journey written as a routing |
| `airports` | Typeahead over the airport table |
| `ruleset` | Version, caps, carriers, city codes, routing grammar, fare basis, booking codes |
| `programs` | The registered loyalty programmes and where each table was read |

Three resources carry the same reference material for a client that reads them: `rtw://ruleset`,
`rtw://programs`, and `rtw://rules` — the transcription of the tariff, so a citation in a violation
can be checked against the text it points at.

**A tool result is written for a reader, not for a browser.** The reply carries the `explain/3`
text beside the report. On `lhr_classic.json` that text is 109 bytes; the same answer over
`/api/validate` is 13,177, of which 5,742 is the coordinates and display names a page needs to draw
a map. So the check register and the annotations are withheld unless asked for — `"checks": true`
and `"annotations": true` — and `annotations.routing`, the one line of them worth having, is
promoted to the top of the reply instead.

**Input the caller can fix comes back as a tool result with `isError`, not as a JSON-RPC error.** A
model can read the first and try again; the second reads to it as a broken transport. An unknown
tool or an unknown method is a JSON-RPC error, because those are not things a model can correct.

**Two eras of the protocol are answered.** Revision `2026-07-28` replaced the `initialize`
handshake with per-request metadata and a `server/discover` method; the revisions before it still
open with a handshake. Both work here, because which one a given client speaks is not something
this repository gets to choose. A request naming a version the server does not answer is refused
with the list of the ones it does.

Answering an era means answering all of it. On `2026-07-28` a cacheable result — `tools/list`,
`resources/list`, `resources/read`, `server/discover` — must carry `ttlMs` and `cacheScope` beside
the `resultType` every result carries, and a client that negotiated that era rejects the whole
reply without them. Both are set, to 0 and `private`: immediately stale, and never served out of a
shared cache to a different caller. Nothing answered here is per-caller and the tariff is fixed for
the life of the process, so a longer ttl would be sound; this is the conservative floor rather than
a tuned one.

### Over a network

There is no HTTP transport here, and a client that needs one should put a proxy in front rather
than wait for a second implementation of the protocol. [`Dockerfile.mcp`](Dockerfile.mcp) is that
proxy: an image that runs `mcp.pl` as a child process and serves streamable-HTTP on port 8000. It
restates no schema and names no operation — the bridge is a config file, not code — so there is
nothing in it to drift from the seven tools above.

```sh
docker build -f Dockerfile.mcp -t rtw-mcp .
docker run --rm -p 8000:8000 rtw-mcp
```

It authenticates nobody, deliberately. It is meant to sit on an internal network behind a gateway
that authenticates the caller, which is where this one runs. Do not publish it directly — not
because the validator is dangerous, since it holds no credentials and reads no network, but because
an unauthenticated endpoint is an invitation to spend your CPU on someone else's itineraries.

[`.claude/skills/rtw-award-planning/`](.claude/skills/rtw-award-planning/) is a skill that writes
down the loop these tools are for: validate for a verdict and a fare basis, `classes` for the codes
to search, an inventory search for space in those codes, then validate and earn again with the
classes filled in.

## Deployment

Deploy the service when something other than a browser needs to ask. [The HTTP API](#http-api) is
the only way to validate an itinerary from a script, a scheduler or another service. The service
serves the same page as the static site. That page runs the same WebAssembly validator either way,
and the container does not validate for it.

`cli.pl serve` is for development. It parks the main thread on a message that never arrives, so a
`SIGTERM` kills work in flight. In production, use [`prolog/daemon.pl`](prolog/daemon.pl), which is
`library(http/http_unix_daemon)` plus the application. It gives you the whole daemon CLI:
`--port --ip --user --group --workers --pidfile --fork --syslog --https --certfile --keyfile`. It
also gives you the signal handling. SIGINT and SIGTERM shut down without abandoning in-flight
requests. SIGHUP reloads, and SIGUSR1 reopens logs.

### Docker

Build the image. The airport table is committed, so the build needs no network and compiles nothing:

```sh
docker build -t rtw-validator .
```

Run the image. The first form is enough for a trial. The second form is how to deploy it:

```sh
# quick look — the UI is then at http://localhost:8080
docker run --rm -p 8080:8080 rtw-validator

# hardened: no root, no writable filesystem, no capabilities
docker run -d --name rtw -p 8080:8080 \
  --read-only --cap-drop=ALL --security-opt no-new-privileges \
  --restart unless-stopped \
  rtw-validator
```

Docker passes everything after the image name to the daemon. Change the port or the worker count in
`CMD`. `-p` maps the *host* port to the container port, so both must change together:

```sh
docker run -d --name rtw -p 9000:9000 rtw-validator --port=9000 --workers=32
```

Operate it:

```sh
docker logs -f rtw                                     # stderr: startup, 500s with backtraces
docker inspect --format '{{.State.Health.Status}}' rtw # the built-in HEALTHCHECK
curl -fsS localhost:8080/api/health
docker stop rtw && docker start rtw                    # SIGTERM is handled; stop returns in ~0.5s
docker build -t rtw-validator . && docker rm -f rtw    # rebuild after a change, then run again
```

The image carries the CLI too, so it can validate a file without a server:

```sh
docker run --rm -i --entrypoint swipl rtw-validator \
  /app/prolog/cli.pl -- route "NYC-BA-X/LON-QR-SIN-QF-SYD-QF-X/LAX-AA-NYC"
```

**A build on Apple Silicon for an x86 host.** The image is architecture-specific. A `linux/arm64`
image does not start on a `linux/amd64` server:

```sh
docker buildx build --platform linux/amd64 -t rtw-validator:amd64 --load .
```

Access logging is off unless `RTW_HTTP_LOG` names a file. A reverse proxy usually logs this better,
and to load `library(http/http_log)` at all writes `httpd.log` into the working directory. To turn
logging on, give the container a writable path, because the root filesystem is not writable. The
`mode=1777` matters: a bare `--tmpfs` mounts root-owned, the server runs as uid 10001, and
`library(http/http_log)` swallows the permission error rather than fail loudly.

```sh
docker run -d --name rtw -p 8080:8080 --read-only --tmpfs /var/log:mode=1777 \
  -e RTW_HTTP_LOG=/var/log/rtw-http.log rtw-validator
```

The image reads two environment variables. The first is `RTW_HTTP_LOG`. The second is
`RTW_DEV_ASSETS`.

**CAUTION: Do not set `RTW_DEV_ASSETS` on the container.** It makes the server re-read the UI from
disk on every request. The read-only design, with no filesystem in the request path, exists to
prevent that. See [Web UI](#web-ui).

The image runs as uid 10001 with every capability dropped. It has no writable path, and ships
neither the test suite nor the fixtures. `HEALTHCHECK` polls `/api/health` every 30 s. The base
image is pinned to `swipl:10.0.2` rather than `:stable`, which moves. For a harder pin,
`docker buildx imagetools inspect swipl:10.0.2` gives you a digest.

### systemd

Use `Type=simple` with `--no-fork`. Do **not** use `Type=forking`. It waits for a parent that never
exits.

```ini
[Service]
Type=simple
User=rtw
WorkingDirectory=/opt/rtw
ExecStart=/usr/bin/swipl --stack-limit=512m prolog/daemon.pl --no-fork --port=8080 --workers=16
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
```

Only the parent needs to be root, and only to bind a privileged port. `--user` drops privileges
after that.

### HTTP API

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/validate` | itinerary JSON in, report JSON out |
| `POST` | `/api/routing` | itinerary JSON in, `{"route": …}` out — the same journey written as a routing, no rules run |
| `POST` | `/api/earn` | itinerary plus `programs` in, points and status currency out, no rules run |
| `POST` | `/api/classes` | itinerary in, the booking codes 5(b) sells this fare in, per sector, no rules run |
| `GET` | `/api/programs` | the registered loyalty programmes, their currencies, and where each table was read |
| `GET` | `/api/ruleset` | version, limits, free-segment caps, carriers, city codes, routing grammar, continents, fare-basis and surcharge tables |
| `GET` | `/api/airports?q=&limit=` | typeahead over the airport table, accent-folded, with coordinates |
| `GET` | `/api/health` | status and ruleset version |
| `GET` | `/` | the bundled web UI |

Errors come back as `{"error": ..., "message": ...}`. The codes are `400 invalid_request` for
malformed input, `413 request_too_large`, `503 timeout`, and `500 internal_error`. A request body is
capped at 128 KB and 100 segments, and each validation runs under a 10-second limit. All three
limits live in [`prolog/data/limits.pl`](prolog/data/limits.pl), with the fare caps.

`/api/ruleset` exists so a web UI never hardcodes rule data. `/api/programs` is its counterpart on
the earning side, for the same reason: the page names no programme, no currency and no table.

Every validate response carries two things a UI needs.

The first is a `checks` array. It holds `{rule, citation, label, outcome, detail}` for every rule
measured. See [What passed, and by how much](#what-passed-and-by-how-much).

The second is an `annotations` object. It holds the derived route, and the collapsed continent and
traffic-conference sequences. It holds the ground time and the stopover classification of each
connection. `annotations.names` holds the display name for every continent and traffic conference,
so a client never has to invent one from the atom. `annotations.routing` holds the whole journey,
written back out as a routing string.

Together these let a UI draw the itinerary and show *why* a rule fired, rather than print only its
message.

```sh
curl -s -X POST localhost:8080/api/validate \
     -H 'content-type: application/json' \
     --data @prolog/test/fixtures/lhr_classic.json | jq .

# a dated itinerary, written back out as a routing
curl -s -X POST localhost:8080/api/routing \
     -H 'content-type: application/json' \
     --data @prolog/test/fixtures/lhr_classic.json
# {"route":"LHR-BA-JFK-AA-X/LAX-JL-NRT-CX-HKG-CX-BKK-QR-X/DOH-QR-LHR"}
```

`/api/routing` is its own endpoint rather than a flag on validate, because it answers a different
question and runs no rules. It works from the annotation pass. Thus a stop worked out from a
two-hour connection and a stop declared `X/` come out the same way. The routing reaches the same
verdict as the itinerary it came from.

When a point is neither a transfer nor a stopover, the endpoint refuses with `400` and the segment
numbers. A routing has no notation for "unknown", and a bare code means stopover. A guess would thus
change what the itinerary means. `annotations.routing` is `null` in the same case.

## Itinerary format

```json
{
  "origin": "LHR",
  "cabin": "business",
  "mode": "full",
  "passengers": [{ "type": "adult" }],
  "segments": [
    { "n": 1, "type": "flight", "from": "LHR", "to": "JFK",
      "marketingCarrier": "BA", "operatingCarrier": "BA", "flight": "BA117",
      "dep": "2026-09-01T10:25", "arr": "2026-09-01T13:30", "stop": "stopover",
      "bookingClass": "D" },
    { "n": 2, "type": "surface", "from": "GRU", "to": "GIG" }
  ]
}
```

or, for the routing form:

```json
{ "route": "NYC-BA-X/LON-QR-SIN-QF-SYD-QF-X/LAX-AA-NYC", "cabin": "business" }
```

Only `segments[].{from,to}` and one of `segments`/`route` are required. To give both is an error. If
the two disagreed, there would be no principled way to choose between them.

`cabin` defaults to economy, `origin` to the departure point of segment 1, and `type` to `flight`.
`mode` defaults to `full` for `segments` and to `routing` for `route`. Times are **local wall-clock**
times, and a zone designator is accepted and then thrown away. `stop` on the last segment is
ignored, because the journey ends there and there is no intermediate point to describe.

`carrier` is shorthand that fills both carrier fields. `marketingCarrier` on its own leaves the
operator unknown, rather than assume that there is no codeshare.

`bookingClass` is the single RBD letter the segment is sold in, and rule 5(b) reads it. The
*marketing* carrier decides which 5(b) row to read it against. 5(b) is about the code the fare is
sold in, and the seller is the one who sells it. 4(j) is the other way round, and turns on who
operates.

A missing `bookingClass` is *not* filled in for rule 5(b). That rule measures the class that was
booked, and a filled-in value would report a pass it never measured. Only the earning side reads the
tariff to fill that gap, and only because an estimate is permitted to.

`fareFamily` is the branded fare of the carrier: `flex`, `essential` or `light` from Cathay. These
are the only fare brands either programme prices. No fare rule reads `fareFamily` at all. Without
it, Cathay's own Economy cannot be priced to a single number. Both fields are optional, and neither
one affects any other rule.

`members` is optional. Nothing but the earning side reads it:

```json
"members": { "qff": { "tier": "gold" } }
```

Missing information degrades honestly rather than pass in silence. A connection with neither a
timestamp nor a declared stop kind makes rule 8 `indeterminate`, and the verdict `indeterminate`
with it. A missing operating carrier makes 4(j) a `warning`.

A journey that touches Cuba with no carrier named anywhere makes rule 15 `indeterminate`, for the
same kind of reason. The restriction is about who flies it, and the sector that puts most
itineraries into Cuba is American. The report thus cannot say "it does not use American or Alaska"
about an input that named nobody. Warnings on their own still leave a verdict of `valid`.

Routing mode relaxes which rules *apply*. It never relaxes the standard of evidence for the ones that
do.

Because the times are local, an eastbound trans-Pacific sector really does arrive at an earlier clock
time than it departed: NRT 17:00 to LAX 10:00 the same day. Only a jump backwards wider than the span
of world time zones is a data error.

## Tests

```sh
swipl -g run_tests -t halt prolog/test/run_tests.pl   # 312 tests, no node needed
npm run test:wasm                                     # the browser build against the native one
npm run check:contrast                                # WCAG over the palette, no browser needed
```

There are eleven suites. [`DESIGN.md`](DESIGN.md#tests) says what each one is for and which of them are
load-bearing. Every rule id has a fixture.

## Scope

Checked: 4(a)–4(l), 5(b), 6, 7, 8, 15, 19, and the section 0 continent-count to fare-basis mapping.

Not checked, because an itinerary cannot decide them: capacity limitations, GDS fare amounts, group
travel, and voluntary-change fees.

5(b) is checked only where the itinerary says what class it was sold in, and that field is optional.
See `bookingClass` in [Itinerary format](#itinerary-format). With no class anywhere, the register
says it had nothing to read. That is deliberately not `indeterminate`. A routing is a fare notation
with nowhere to write a booking code. To treat that as missing data would make every routing
undecidable over a field the notation cannot express.

Where a class *is* given, three outcomes are possible, because 5(b) holds three kinds of class. The
applicable code for the cabin passes. Any code the table does not name for that carrier is an error.
Between the two sit the codes the notes of 5(b) permit in stated cases:

- The own code of a lower cabin.
- `Y` on a First fare.
- `B` (or `H` on AA) on a DONE Business fare.
- `A` on QR for services within the Middle East.

Those pass too, and the register names the segments and the note they lean on. See
[Reading the rule](DESIGN.md#reading-the-rule-where-it-is-ambiguous) for why they are not warnings.

One rule is measured but cannot be decided, and says so. The real trigger of rule 19 is an infant who
*reaches* two years old between departure and the end of the journey. The input carries an age rather
than a date of birth. Thus a one-year-old who turns two next month and one who turned one last week
look identical here.

The journey on this fare can run a full twelve months, so the risk is real. The consequence is a full
child fare, bought after the fact, for the whole trip. Thus an infant stated as 1 draws a warning
rather than silence. A date of birth would make the rule decidable. Nothing else would.

### What the ticket earns

This is not part of Rule 3015 at all, which is why it is a separate operation. See
[What it earns](#what-it-earns) and [`PLANS/05-loyalty-earning.md`](PLANS/05-loyalty-earning.md).

Two programmes are registered. Qantas Frequent Flyer is priced off both of its published tables,
with its status bonus applied. One table is its own, for Qantas-marketed sectors. The other is the
partner table, for everything else.

Asia Miles covers Cathay and its 25 partners under two different models. Cathay's own flights come
from a table of fixed amounts. Every partner is a percentage of the distance flown. Effective dating
and the Cathay tiers are what is left to do.
[`prolog/data/earn/sources/README.md`](prolog/data/earn/sources/README.md) lists the tables that are
not yet captured.

Four things are out of scope in both programmes, on purpose:

- Award bookings, which earn nothing.
- Qantas Loyalty Bonus, Points Club and lifetime credits.
- Miles from anything that is not a flight.
- Any ranking of one programme against another. A comparison of a mile with a Status Point needs a
  valuation, and a valuation is an opinion.

Nine partners of Asia Miles are outside oneworld, and thus cannot appear on an Explorer fare at all.
They are priced anyway, because the table publishes them. To leave rows out of a transcription is how
a transcription stops being one.

[`DESIGN.md`](DESIGN.md) has the rest: how the rules are structured, the four geography taxonomies,
the earning kernel and its plugin protocol, the WebAssembly target, and the test suites.
