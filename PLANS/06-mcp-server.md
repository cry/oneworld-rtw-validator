# The validator over MCP

## The problem

The validator answers three questions — may this itinerary be sold, what would it earn, and how is
it written as a routing — through three front ends: `cli.pl`, `server.pl` and `wasm.pl`. DESIGN.md
states the shape plainly: *three front ends, one `report/3`*. Each is a renderer. None holds rule
logic.

A model is now a fourth kind of caller, and the first that can *act* on the answer: read a verdict,
work out which sector broke a rule, search for a replacement, ask again. Nothing here is reachable
that way today.

The other half of that loop already exists, in another repository. `expertflyer-cli` searches
ExpertFlyer for per-sector booking-class inventory, and it already ships an MCP server —
`src/expertflyer/mcp_server.py`, FastMCP, two tools, a single-user OAuth provider, streamable-HTTP
in Docker. It is the source of the `claude_ai_Expertflyer` connector on the account.

This plan is the half that lives here. [`07-expertflyer-bridge.md`](07-expertflyer-bridge.md) is the
half that lives there. Neither depends on the other being done first.

## Two servers rather than one

The two services stay two servers. Three facts decide it, and none is a preference.

**They are different languages.** The validator is Prolog with no Python anywhere. ExpertFlyer is
Python with no Prolog anywhere. A merged server bridges one into the other by subprocess or HTTP,
which adds a hop and a failure mode and buys nothing a client cannot already do.

**They hold different secrets.** `auth.py` there stores the account password in the keyring, in
plaintext, because ExpertFlyer sessions last a day and there is no refresh token. Under Docker that
is a cleartext file in a volume. The validator holds nothing, needs nothing, and is published to
GitHub Pages. One process for both puts a credential store inside the one artefact here that anyone
can run.

**They fail differently.** The validator is offline, deterministic and total. ExpertFlyer is a
replay of undocumented Next.js Server Actions whose action hashes break on every deploy, with no
rate limiting and no 429 handling. Merging binds the reliable thing's uptime to the fragile one's.

A router in front of both is worse than either. It would translate every field across two schemas,
and every new operation would need plumbing through three places before a model could reach it.
Clients already compose across servers. What composition needs is a shared vocabulary, which is the
contract below.

```
Claude client
  |- rtw          (stdio, Prolog)    validate . earn . routing . classes
  |                                   airports . ruleset . programs      <- this plan
  \- expertflyer  (remote, Python)   search_availability                 <- plan 07
                                      search_availability_range
```

## The joint

The two services meet at the **booking class**:

- ExpertFlyer returns `bookingClassAvailability[]` per sector: `{code, availability, hasAvailability}`.
- Rule 5(b) reads `bookingClass` and decides whether it is a code the fare is sold in.
- The earning side reads the same field to price points and status credits.
- `search_availability` takes a `classes` filter, so knowing which codes to ask for narrows a search
  from every seat on the aircraft to the ones the fare can use.

```
validate  --> verdict, fare basis DONE4
classes   --> [1] LHR-JFK  BA  D      -+   the codes to search for
              [2] JFK-LAX  AA  D       |
                                       v
                      expertflyer search_availability(classes=["D"])
                                       |
              RTW-shaped segments  <----+   format: "rtw"
                     |
validate  <----------+--> earn     5(b) moves from n/a to ok;
                                   status credits priced on a real class
```

The table that answers "which codes" is `data/booking_codes.pl` — eight `row/6` terms, the whole of
5(b) — and `explorer_classes/5` and `basis_classes/5` are the exported projections over it. **No
front end exposes any of it.** It is absent from `ruleset_json/1`, from `server.pl` and from
`wasm.pl`. It is the most useful thing this integration needs, it is already written and already
tested, and it only needs a way out.

## The contract

The shape both repositories must agree on. This plan consumes it; plan 07 produces it. It is not
new — it is the itinerary format `src/io/json_in.pl` already reads and the README already documents,
restated here so each plan is executable without reading the other repository.

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

## Why not proxy the HTTP API

The obvious shortcut is an MCP server forwarding to `/api/validate`. Measured on
`test/fixtures/lhr_classic.json`:

| what the caller gets | bytes |
|---|---|
| `POST /api/validate`, whole response | 13,177 |
| — `annotations` (lat/lon, point kinds, display names) | 5,742 |
| — `checks` register | 4,996 |
| `explain/3` text, default | **109** |
| `explain/3` text, with `checks(true)` | 3,727 |

Forty-four per cent is map coordinates, there because a browser draws a map with them. A model
cannot use any of it and pays for all of it on every call.

The repo already owns the renderer a reader wants. `explain/3` was written to be read once: short
sentences, one fact each, common words. It is the right `content` for a tool result; the trimmed
report is the right `structuredContent`. That is the same division `json_out.pl` and `explain.pl`
already are — two renderers over one `report/5` — so the MCP server writes no fourth renderer.

## 1. Extract the operations: `src/ops.pl` (new)

`wasm.pl:rtw_do/3` is already the dispatcher this needs: six named operations, JSON dict in, JSON
dict out, with `error_reply/3` mapping `input_error` to 400 and everything else to 500. Move
`rtw_do/3`, `input_dict/2`, `error_reply/3` and `failed_reply/2` into a module, following exactly
the pattern `server.pl` uses — a module that `use_module`s the specific `src/` modules it needs
rather than leaning on predicates reaching it through `user`.

`wasm.pl` keeps `rtw_call/4` and its `ensure_loaded(load)`, and gains `:- use_module('src/ops')`.
Its comments about saved images and `library(http/json)` stay put; they are about the WebAssembly
build, not the operations.

This is the only change to existing behaviour, and it is covered: `npm run test:wasm` already diffs
native against WebAssembly over all 54 fixtures times `validate` and `earn`, and CI runs it.

## 2. A seventh operation: `classes`

Add `rtw_do(classes, In, Out)` to `src/ops.pl`. Itinerary in, per-flight-segment permitted codes
out. It runs no fare rules.

It is its own operation for the reason `routing` is its own endpoint rather than a flag on validate:
it answers a different question. `server.pl` and `wasm.pl` pick it up for free.

Everything it needs is exported and tested already:

- `src/pricing.pl:fare/2` for the reported basis.
- `data/booking_codes.pl:basis_classes/5` where a basis exists, `explorer_classes/5` where it does
  not — the same fallback `src/earn/presumed.pl:62-64` already makes, for the same reason.
  `basis_classes/5` is the better of the two because it narrows to the reported fare basis rather
  than the cabin, which is the difference between one code and two.
- `premium_economy_code/2`, `business_alternate_code/2`, `first_alternate_code/1` and
  `middle_east_business_code/2` for the codes the notes of 5(b) permit in a stated case. Return
  these in a separate `alternates` field, never mixed into the applicable codes. `r05_booking.pl`
  keeps that distinction, and a search that conflated them would report a pass the rule never
  granted.

Codes in the table are lowercase atoms; `r05_booking.pl` upcases them at the boundary and so should
this.

Also add `bookingCodes` to `ruleset_json/1` in `src/io/json_out.pl`. The whole of 5(b) is eight
rows, a few hundred bytes against the 5,305 the ruleset already is, and it is the last piece of rule
data a client still has to hardcode. `/api/ruleset` exists so a client never has to.

Add `POST /api/classes` to `server.pl`, over the same operation.

## 3. The MCP server: `mcp.pl` (new)

A peer of `cli.pl` and `daemon.pl`: line-delimited JSON-RPC 2.0 on stdin and stdout, dispatching to
`ops:rtw_do/3`. Methods: `initialize`, `notifications/initialized`, `ping`, `tools/list`,
`tools/call`, `resources/list`, `resources/read`.

Three things it must get right:

- **Nothing but JSON-RPC may reach stdout.** `explain/3` and `explain_earn/2` write to a stream, so
  every call goes through `with_output_to(string(S), ...)`. Warnings and startup messages already go
  to stderr.
- **It must not load `server.pl`.** `cli.pl` does, for its `serve` subcommand. Loading it here reads
  the 2.5 MB WebAssembly bundle, the 472 KB image and both fonts into the process at startup for
  nothing. `mcp.pl` loads `load.pl` and `src/ops.pl` only.
- **Protocol version.** Check the current MCP specification when implementing and declare the
  version actually implemented, negotiating down to what the client asks for.

  *As built:* the current revision is `2026-07-28`, not the `2025-06-18` this plan assumed, and it
  is not a point release. It drops the `initialize` handshake entirely: a modern client states its
  version in the `_meta` of every request and discovers the server through a mandatory
  `server/discover` method. Older clients still open with a handshake. The server answers both,
  which the specification calls dual-era, because which era a given client speaks is not something
  this repository gets to choose. A request naming an unanswerable version is refused with code
  `-32022` and the list of versions that would work.

  *Later, and the reason to distrust "it works" here:* declaring an era obliges the server to the
  whole of it. On `2026-07-28` a cacheable result must carry `ttlMs` and `cacheScope` as well as
  the `resultType` this file already emitted, and without them a client that negotiated that era
  rejects `tools/list` while parsing it — which surfaces at the far end as a server with no tools,
  not as a protocol error. It went unnoticed because era negotiation hid it: over plain stdio a
  client settles on `2025-11-25`, where none of the three fields is in the contract and the stray
  `resultType` is ignored. Only once the server sat behind a proxy did both ends claim the newest
  era and use it. `cacheable/2` in `src/mcp.pl` now holds all three in one place, and
  `test_mcp.pl` asserts them on each of the four cacheable methods — and asserts their *absence*
  on a tool result, which is not cacheable and is given no ttl by that revision.

Tool errors come back as a result with `isError: true` and the message as text, not as a JSON-RPC
error object. A model can read and recover from the first; the second reads as a broken transport.
`ops:error_reply/3` already produces the message: 400 becomes the text, 500 becomes the fixed
internal-error message, exactly as over HTTP.

## 4. The tools

Operation names are already tool names. One vocabulary across CLI subcommands, HTTP paths,
WebAssembly ops and MCP tools:

| tool | in | `content` | `structuredContent` |
|---|---|---|---|
| `validate` | `segments` or `route`, `cabin`, `checks?`, `annotations?` | `explain/3` text | verdict, violations, notChecked, fare, routing |
| `earn` | itinerary, `programs?` | `explain_earn/2` text | whole `earn_json/2` |
| `classes` | itinerary | one line per sector | per-segment codes + alternates |
| `routing` | itinerary | the routing string | `{route}` |
| `airports` | `q`, `limit?` | matches, one per line | `{query, results}` |
| `ruleset` | — | version line | whole `ruleset_json/1` |
| `programs` | — | programme names | whole `programs_json/1` |

`validate` drops `annotations` by default and promotes `annotations.routing` to a top-level string,
the one line of it a reader wants. `annotations: true` returns the whole object for a client that
draws. `checks: false` by default, matching the CLI, because the register is 4,996 bytes answering a
question that was not asked.

`earn` keeps its structured output whole. `earn_out.pl:known_value/5` distinguishes `known`,
`published_as_none`, `unknown` and `range`, with `value` null for the last three, and `lowerBound`
says a total is incomplete. Trim any of that and a client prints 0 for three different non-numbers.

`validate` and `earn` stay separate tools. That separation is load-bearing in `cli.pl`, `server.pl`
and the README: a journey that cannot be sold can still be priced, and a valid one can be
unpriceable.

`ruleset` and `programs` are also exposed as resources — `rtw://ruleset`, `rtw://programs` — plus
`rtw://rules` for `parsed-rules-aug-2026.md`, which makes every citation in a violation checkable
against the tariff it came from. They are tools as well because resource support across clients is
uneven, and a model needs the routing grammar before it can write a route string.

*As built:* one thing this plan asked for is deliberately missing from `alternates`. The notes of
5(b) also let a fare book a *lower cabin's* code where the cabin it paid for is not offered, and
which column counts as lower than which is a reading of the rule rather than a row of the table.
That reading lives in `r05_booking.pl:lower_column/2` and stays there; a second copy in `ops.pl`
would be exactly the drift the `classes` operation exists to avoid. The three notes that are rows of
the table — the business alternate, the First alternate and the QR Middle East exception — are
returned. A client that wants the fall-through reads `bookingCodes` off the ruleset and falls
through the columns itself.

## 5. The loop, written down

A skill in this repo documenting the compose loop: validate for a verdict and a fare basis,
`classes` for the codes to search, ExpertFlyer with `classes=` and `format="rtw"`, then validate and
earn again with the classes filled in. It states that the ExpertFlyer half is optional and names the
connector, so it still reads correctly with only the validator installed.

## 6. Documentation

- `README.md`: a section beside **Deployment**, `mcp` in the CLI usage block, `POST /api/classes` in
  the HTTP API table.
- `DESIGN.md`: "Three front ends, one `report/3`" becomes four, and the `## How it works` diagram
  gains `mcp.pl` beside `server.pl . wasm.pl`.

## 7. Files

| file | change |
|---|---|
| `prolog/src/ops.pl` | new: `rtw_do/3` and the error mapping, moved from `wasm.pl`, plus `classes` |
| `prolog/wasm.pl` | keeps `rtw_call/4`; `use_module('src/ops')` |
| `prolog/mcp.pl` | new: JSON-RPC stdio front end |
| `prolog/src/io/json_out.pl` | `bookingCodes` added to `ruleset_json/1` |
| `prolog/server.pl` | `POST /api/classes` |
| `prolog/test/test_mcp.pl` | new |
| `prolog/test/run_tests.pl` | load the new suite |
| `README.md`, `DESIGN.md` | as above |

*As built*, four files were touched that this plan did not name, and one predicate moved:

| file | why |
|---|---|
| `prolog/src/mcp.pl` | the protocol, split from the entry point so the suite can call it without a process on the other end of a pipe — the split `server.pl` and `daemon.pl` are already in |
| `prolog/src/explain.pl` | `explain/3` told every reader to re-run `--checks`, which is not a thing anyone can type at this front end. It gains a `checks_hint` option and keeps the CLI wording as its default |
| `prolog/test/test_wasm.mjs` | `classes` added to the operations diffed between the two engines |
| `prolog/load.pl` | load the new suite under the test flag |
| `Dockerfile.mcp`, `Dockerfile.mcp.dockerignore` | later: an image serving this front end over HTTP, for a caller on another host. `mcp.pl` runs as a child of a FastMCP proxy — a transport shim with no schema in it. The alternative was writing streamable-HTTP in Prolog, which is protocol code this repository would then own and test, and the shim is a config file. It needs its own ignore file because the shared one excludes `parsed-rules-aug-2026.md`, which the HTTP image has no reader for and this one serves as `rtw://rules` |

`src/ops.pl` also gained `rtw_render/5` beside `rtw_do/3`. A tool result carries the prose and the
report together, and `explain.pl` reads the report *term* while `json_out.pl` reads the same term,
so a caller wanting both would otherwise validate twice and hope the runs agreed. One pipeline, two
entry points.

Untouched: every file under `prolog/src/rules/`, `prolog/src/earn/` and `prolog/data/` except the
one addition to `json_out.pl`. No rule logic moves, and no number changes.

## 8. Verification

**The refactor changed nothing.** Load-bearing, because step 1 moves code the browser depends on:

```sh
swipl -g run_tests -t halt prolog/test/run_tests.pl   # existing tests, all must still pass
npm run build && npm run test:wasm                    # native against WebAssembly, every fixture
```

*As built:* 312 tests pass, of which 31 are new. The engine diff runs 174 replies over 58 fixtures
× `validate`, `earn` and `classes`. The saved image grew by 2.2 KB.

**The new operation agrees with the rule that reads the same table.** `test/test_mcp.pl` asserts,
over every fixture naming a carrier, that the codes `classes` returns for a sector are the ones
`r05_booking.pl` accepts for it. The two projections must not drift. And that a fixture whose class
is stated, run through `classes`, names that class.

**The server speaks the protocol.** In-process plunit over the dispatcher: an `initialize`
handshake, `tools/list` returning schemas that parse, one `tools/call` per tool over a fixture, an
`isError` result for malformed input, a JSON-RPC error for an unknown method. Then by hand:

```sh
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | swipl prolog/mcp.pl
```

**Nothing else reaches stdout.** Run the same pipe and assert every line parses as JSON. A stray
`print_message` is the failure this catches, and it is silent otherwise.

**Registered.** In Claude Code, validate `prolog/test/fixtures/lhr_classic.json`, read back the fare
basis, call `classes`, confirm it names `D` for the BA and AA sectors.

```json
{ "mcpServers": { "rtw": { "command": "swipl",
    "args": ["/Users/carey/projects/oneworld-rtw-planner/prolog/mcp.pl"] } } }
```
