% src/mcp.pl -- the Model Context Protocol, as messages.
%
% JSON-RPC 2.0 in and out, dispatching to the operation table in src/ops.pl. A
% fourth renderer over the same report/5 term the CLI prints, holding no rule
% logic of its own.
%
% This is the module, and prolog/mcp.pl is the entry point that runs it -- the
% same split server.pl and daemon.pl are in, and for the same two reasons. The
% logic can be tested without a process to talk to, and the file with the
% initialization directive in it stays small enough to read in one go.
%
% Three things here are not obvious.
%
% *Nothing but JSON-RPC may reach the output stream.* The transport is standard
% output, so a stray write corrupts the session rather than showing up as a
% message. src/explain.pl writes to a stream, so the text a tool result carries
% is captured with with_output_to/2 -- in src/ops.pl, where the renderer is
% called. Everything else -- warnings, load messages, the report of a crash --
% goes to standard error, where SWI already sends it.
%
% *server.pl is deliberately not loaded.* cli.pl loads it for its `serve`
% subcommand, and loading it reads the whole web UI into the program: a 2.5 MB
% WebAssembly bundle, a 416 KB image and two fonts. None of that is reachable
% from here.
%
% *The server answers two eras of the protocol.* Revision 2026-07-28 dropped the
% `initialize` handshake: a modern client states its version in the `_meta` of
% every request and may call `server/discover` first. Clients speaking the older
% revisions still open with `initialize`. Both are answered here, which is what
% the specification calls a dual-era server, because which era a given client
% speaks is not something this file gets to choose.

:- module(mcp,
          [ mcp_loop/0,
            reply_for/2,
            tool/4,
            resource/4,
            resource_content/3,
            protocol_version/1
          ]).

:- use_module(ops).
:- use_module('earn/registry').
:- use_module('../data/limits').

:- if(exists_source(library(json))).
:- use_module(library(json)).
:- else.
:- use_module(library(http/json)).
:- endif.

:- use_module(library(apply)).
:- use_module(library(lists)).
:- use_module(library(readutil)).
:- use_module(library(yall)).

server_name('oneworld-rtw-planner').
server_version('1.0.0').

%! protocol_version(?Version) is nondet.
%  Newest first. The first is what an `initialize` with nothing usable in it
%  gets back. 2026-07-28 is the revision that replaced the handshake with
%  per-request metadata; the two below it still use one.
protocol_version('2026-07-28').
protocol_version('2025-11-25').
protocol_version('2025-06-18').

legacy_version('2025-11-25').
legacy_version('2025-06-18').

% --- the loop --------------------------------------------------------------

%! mcp_loop is det.
%  Read a message, answer it, repeat until the input ends. The caller sets the
%  stream encodings; see mcp.pl.
mcp_loop :- loop.

% The session outlives any one message. A message that fails or throws where it
% should have replied is a bug here, and it is reported and stepped over rather
% than allowed to end a conversation that was going fine until then. Only end of
% input stops the loop.
loop :-
    read_line_to_string(user_input, Line),
    (   Line == end_of_file
    ->  true
    ;   (   catch(handle_line(Line), E, ( internal_error(handle_line, E), fail ))
        ->  true
        ;   format(user_error, 'mcp: no reply produced for a message~n', [])
        ),
        loop
    ).

% A line that is not JSON at all cannot be answered, because a reply needs the
% id that was in it. The specification says to drop it; saying so on stderr is
% the only way anyone finds out.
handle_line(Line) :-
    (   Line == ""
    ->  true
    ;   catch(atom_json_dict(Line, Msg, [value_string_as(string)]), _, fail)
    ->  dispatch(Msg)
    ;   format(user_error, 'mcp: ignoring a line that is not JSON~n', [])
    ).

dispatch(Msg) :-
    (   reply_for(Msg, Reply)
    ->  write_message(Reply)
    ;   true
    ).

%! reply_for(+Msg, -Reply) is semidet.
%
%  The whole protocol, as a function from one message to one reply. It fails for
%  a notification, which has no id and takes no reply whatever it asks for --
%  that includes notifications/initialized, which a legacy client sends to close
%  its handshake and which needs nothing done.
%
%  Nothing here reads or writes a stream, which is what lets the suite exercise
%  every method without a process on the other end of a pipe.
reply_for(Msg, _) :-
    \+ get_dict(id, Msg, _), !,
    fail.
reply_for(Msg, Reply) :-
    Id = Msg.id,
    % The reader is asked for value_string_as(string), so every value in the
    % message is a string, method names included. The clauses below are written
    % over atoms, as the rest of this repository is.
    (   get_dict(method, Msg, Method0)
    ->  atom_string(Method, Method0)
    ;   Method = ''
    ),
    (   get_dict(params, Msg, Params), is_dict(Params)
    ->  true
    ;   Params = _{}
    ),
    (   version_refused(Params, Supported, Requested)
    ->  version_error(Id, Supported, Requested, Reply)
    ;   % catch/3 fails when its goal fails, so the call is made inside an
        % if-then-else. Without that, a method this server does not answer takes
        % the whole loop down with it instead of drawing a -32601.
        (   catch(method(Method, Params, Result), Error, true)
        ->  true
        ;   true
        ),
        (   nonvar(Error)
        ->  request_error(Method, Error, Code, Message),
            error_reply(Id, Code, Message, Reply)
        ;   nonvar(Result)
        ->  Reply = _{ jsonrpc: '2.0', id: Id, result: Result }
        ;   format(atom(M), 'Method not found: ~w', [Method]),
            error_reply(Id, -32601, M, Reply)
        )
    ).

% A malformed request is described back to the caller, because that is
% information they already have. Anything else is a bug here: the term and its
% backtrace go to stderr, where whoever started the server can read them, and
% the caller is told only that it happened. That is the same split server.pl
% makes, for the same reason.
request_error(_, mcp_error(Code, Message), Code, Message) :- !.
request_error(Method, Error, -32603, 'Internal error') :-
    internal_error(Method, Error).

% A request that names a protocol version this server does not answer is
% refused with the list it does, so the client can pick one and try again. A
% request that names none is from a client of the older era, which settled its
% version in the handshake and does not repeat it.
version_refused(Params, Supported, Requested) :-
    get_dict('_meta', Params, Meta), is_dict(Meta),
    get_dict('io.modelcontextprotocol/protocolVersion', Meta, Requested0),
    atom_string(Requested, Requested0),
    \+ protocol_version(Requested),
    findall(V, protocol_version(V), Supported).

% --- methods ---------------------------------------------------------------

%! cacheable(+Result0, -Result) is det.
%  Add the freshness directives 2026-07-28 requires on a cacheable result.
%
%  That revision made `resultType` mandatory on every result, and on the
%  cacheable ones -- server/discover, tools/list, resources/list and
%  resources/read -- `ttlMs` and `cacheScope` mandatory beside it. `resultType`
%  alone does not satisfy it: a client that negotiated the era rejects the whole
%  reply over the two missing keys, and because the rejection happens while
%  parsing tools/list it surfaces at the far end as a server with no tools
%  rather than as a protocol error.
%
%  Which is how this was found. Over plain stdio a client settles on 2025-11-25,
%  where none of the three fields is in the contract and the stray resultType is
%  ignored; behind a proxy it negotiates the newest era both ends claim, and
%  this server claims this one.
%
%  tools/call is deliberately not in that set. It carries `resultType` -- also
%  required there -- but a tool result is not cacheable and the revision gives
%  it no ttl.
%
%  0 milliseconds means immediately stale, and `private` forbids a shared cache
%  from serving one caller's reply to another. Both are the conservative
%  reading. Nothing answered here is per-caller and the tariff is fixed for the
%  life of the process, so a real ttl would be sound -- but that is a policy
%  decision, and this is the correctness floor.
cacheable(Result0, Result) :-
    put_dict(_{ resultType: complete, ttlMs: 0, cacheScope: private },
             Result0, Result).

%! method(+Method, +Params, -Result) is semidet.
%  Fails for a method this server does not answer, which dispatch/1 turns into
%  a -32601. It must fail rather than throw: an exception here is a bug, and the
%  two are reported differently on purpose.

% The modern opening. A client may call it first to learn what this server
% speaks, or skip it and send a request straight away.
method('server/discover', _, Result) :-
    findall(V, protocol_version(V), Versions),
    server_name(Name),
    server_version(Version),
    instructions(Instructions),
    cacheable(_{ supportedVersions: Versions,
                 capabilities: _{ tools: _{}, resources: _{} },
                 instructions: Instructions,
                 '_meta': _{ 'io.modelcontextprotocol/serverInfo':
                             _{ name: Name, version: Version } } },
              Result).

% The older opening. The version asked for is echoed back when this server
% answers it, and the newest legacy revision offered otherwise -- a client of
% that era has no way to ask again.
method(initialize, Params, _{ protocolVersion: Version,
                              capabilities: _{ tools: _{}, resources: _{} },
                              serverInfo: _{ name: Name, version: SVersion },
                              instructions: Instructions }) :-
    (   get_dict(protocolVersion, Params, Asked0),
        atom_string(Asked, Asked0),
        legacy_version(Asked)
    ->  Version = Asked
    ;   once(legacy_version(Version))
    ),
    server_name(Name),
    server_version(SVersion),
    instructions(Instructions).

method(ping, _, _{}).

method('tools/list', _, Result) :-
    findall(T, tool_json(T), Tools),
    cacheable(_{ tools: Tools }, Result).

method('tools/call', Params, Result) :-
    (   get_dict(name, Params, Name0)
    ->  atom_string(Name, Name0)
    ;   throw(mcp_error(-32602, 'A tool call needs a "name".'))
    ),
    (   get_dict(arguments, Params, Args), is_dict(Args)
    ->  true
    ;   Args = _{}
    ),
    (   tool(Name, _, _, _)
    ->  true
    ;   format(atom(M), 'Unknown tool: ~w', [Name]),
        throw(mcp_error(-32602, M))
    ),
    tool_operation(Name, Args, Op, OpArgs),
    call_tool(Op, OpArgs, Result).

method('resources/list', _, Result) :-
    findall(R, resource_json(R), Resources),
    cacheable(_{ resources: Resources }, Result).

method('resources/read', Params, Result) :-
    (   get_dict(uri, Params, Uri0)
    ->  atom_string(Uri, Uri0)
    ;   throw(mcp_error(-32602, 'A resource read needs a "uri".'))
    ),
    (   resource_content(Uri, MimeType, Text)
    ->  Content = _{ uri: Uri, mimeType: MimeType, text: Text }
    ;   format(atom(M), 'Unknown resource: ~w', [Uri]),
        throw(mcp_error(-32602, M))
    ),
    cacheable(_{ contents: [Content] }, Result).

instructions(S) :-
    ruleset_version(V),
    format(atom(S),
           'Validates a round-the-world itinerary against the oneworld Explorer fare, \c
            Tariff RWR2 Rule 3015, version ~w, and prices what it would earn. \c
            An itinerary is either a list of segments or a routing string such as \c
            "NYC-BA-X/LON-QR-SIN-QF-SYD-QF-X/LAX-AA-NYC"; give one or the other, never both. \c
            Call `itinerary` with `op` to choose the question: `validate` answers whether the \c
            fare may be sold and cites the clause behind every violation; `earn` answers what \c
            the ticket is worth and runs no fare rules, because a journey that cannot be sold \c
            can still be priced; `classes` answers which booking codes section 5(b) sells \c
            this fare in, which is what to ask an inventory system for; `routing` rewrites \c
            the journey in fare-construction notation.',
           [V]).

% --- tools -----------------------------------------------------------------

% The operation names are the tool names, with one exception that earns itself.
% One vocabulary across the CLI subcommands, the HTTP paths, the browser ops and
% these, so a reader who has seen any one of them has seen them all.
%
% The exception: `validate`, `earn`, `classes` and `routing` take the SAME
% input -- itinerary_schema/1, below -- and MCP has no way to say so. Every tool
% in `tools/list` carries its own full copy of its schema, so four tools meant
% four copies of a 1,806-byte `segments` description: 7.2 KB, more than a tenth
% of everything the gateway this sits behind sends to every conversation that
% connects, whether or not an itinerary is ever mentioned.
%
% So those four are one tool, `itinerary`, and the operation moves into a
% required `op` parameter. The vocabulary survives as the enum values -- `op`
% is the word the browser side already uses -- and the three tools with input of
% their own (airports, ruleset, programs) are unaffected and stay named after
% their operations. Underneath, nothing changed: tool_operation/4 turns the tool
% call back into an operation and call_tool/3 is reached exactly as before, so
% the CLI, the HTTP paths and these still run the same four code paths.

% A title names the action, starting with the verb: it is what a client shows
% in a list beside other servers' tools, where `The ruleset` reads as a
% sentence fragment about nothing in particular and `Get fare rules, caps and
% reference tables` says what calling it does. The description is the place for
% prose. The server name supplies the subject, so a title does not repeat it.

%! tool(?Name, ?Title, ?Description, ?InputSchema) is nondet.
tool(itinerary, 'Validate, price or rewrite an itinerary',
     'One itinerary, four questions. Pick one with `op`:\n\n\c
      `validate` -- may this be sold as a oneworld Explorer fare? Returns a verdict of \c
      valid, invalid or indeterminate, every rule broken with the clause it came from, and \c
      the fare basis. Indeterminate means the input left out something a rule needed, not \c
      that the rule passed. Takes `checks` and `annotations`.\n\n\c
      `earn` -- what is the ticket worth? Points, miles and status currency per loyalty \c
      programme and per sector, with the table row each figure came from. Runs no fare \c
      rules: a journey that cannot be sold can still be priced, and a valid one can be \c
      unpriceable. A sector whose booking class was not given is priced on the class section \c
      5(b) sells this fare in, and the reply says which class it presumed and why; where no \c
      5(b) row settles it, the sector comes back undecided rather than zero. Takes \c
      `programs`.\n\n\c
      `classes` -- which booking codes may it be sold in? The codes section 5(b) allows, one \c
      sector at a time, which is what to ask an inventory system for when searching for \c
      space the fare can actually use. Runs no fare rules. `classes` holds the applicable \c
      codes; `alternates` holds codes the notes allow only where something about the flight \c
      is true that an itinerary cannot show.\n\n\c
      `routing` -- the same journey in fare-construction notation, such as \c
      "LHR-BA-JFK-AA-X/LAX-JL-NRT-CX-HKG-QR-X/DOH-QR-LHR". Runs no rules. Refuses when a \c
      point is neither a stopover nor a transfer, because the notation has no way to write \c
      "unknown" and a bare code already means stopover.',
     Schema) :-
    itinerary_schema(Base),
    findall(P, earn_program_id(P), Ids),
    Extra = _{ op: _{ type: string,
                      enum: [validate, earn, classes, routing],
                      description: 'Which question to answer. See the description; there is \c
                                    no default, because the four answer different questions \c
                                    about the same journey and guessing one would quietly \c
                                    return something nobody asked for.' },
               checks: _{ type: boolean,
                          description: 'op=validate only. Also return one line per rule \c
                                        measured, including the rules that passed and by how \c
                                        much. Off by default.' },
               annotations: _{ type: boolean,
                               description: 'op=validate only. Also return the derived \c
                                             geography of the journey: coordinates, continent \c
                                             and traffic conference per sector, and the kind \c
                                             of every connection. Off by default; a reader \c
                                             wants the routing string, which is always \c
                                             returned.' },
               programs: _{ type: array,
                            items: _{ type: string, enum: Ids },
                            description: 'op=earn only. Which programmes to price. Every \c
                                          registered programme by default. The reply carries \c
                                          no ranking between them: comparing a mile with a \c
                                          status point needs a valuation, and a valuation is \c
                                          an opinion.' } },
    add_properties(Base, Extra, Schema0),
    % The only required key at the top level. Everything else about an itinerary
    % is optional on purpose -- see itinerary_schema/1 -- but an absent `op` has
    % no safe reading.
    put_dict(required, Schema0, [op], Schema).
tool(airports, 'Search airports by code, city or name',
     'Search the airport table by code, city or name, accent-folded. Use it to turn a place \c
      into the IATA code an itinerary needs, and to check a code is one the validator knows.',
     _{ type: object,
        properties: _{ q: _{ type: string,
                             description: 'Code, city or airport name.' },
                       limit: _{ type: integer,
                                 description: 'How many matches to return. 20 by default, 100 at most.' } },
        required: [q] }).
tool(ruleset, 'Get fare rules, caps and reference tables',
     'Everything a client would otherwise hardcode: the ruleset version, every cap with the \c
      clause it comes from, the eligible carriers, the metro city codes, the continents and \c
      traffic conferences, the fare-basis table, the section 5(b) booking codes and the \c
      premium-economy surcharge bands. Read this rather than assuming a number.',
     _{ type: object, additionalProperties: false }).
tool(programs, 'List loyalty programmes and their tables',
     'The registered programmes, their currencies, which currency a status bonus reaches, \c
      the fare families each prices, the tiers it publishes, and where every table was read \c
      and when.',
     _{ type: object, additionalProperties: false }).

earn_program_id(P) :- earn_programs(Ids), member(P, Ids).

% Both input forms, described once. Only `from` and `to` are ever required, and
% giving both `segments` and `route` is an error rather than a preference, so
% neither is marked required here and json_in.pl says which mistake was made.
itinerary_schema(
    _{ type: object,
       properties:
         _{ route: _{ type: string,
                      description: 'The journey in fare-construction notation, such as \c
                                    "NYC-BA-X/LON-QR-SIN-QF-SYD-QF-X/LAX-AA-NYC". \c
                                    "X/" marks a transfer; a bare code is a stopover. \c
                                    Give this or "segments", never both.' },
            segments: _{ type: array,
                         description: 'The journey one sector at a time. \c
                                       Give this or "route", never both.',
                         items:
                           _{ type: object,
                              properties:
                                _{ n: _{ type: integer, description: 'Position in the journey, from 1.' },
                                   type: _{ type: string, enum: [flight, surface],
                                            description: 'Defaults to flight.' },
                                   from: _{ type: string, description: 'IATA code of the departure point.' },
                                   to: _{ type: string, description: 'IATA code of the arrival point.' },
                                   carrier: _{ type: string,
                                               description: 'Shorthand filling both carrier fields.' },
                                   marketingCarrier: _{ type: string,
                                                        description: 'Who sells the sector. Rule 5(b) reads this one. \c
                                                                      Giving it alone leaves the operator unknown rather \c
                                                                      than assuming there is no codeshare.' },
                                   operatingCarrier: _{ type: string,
                                                        description: 'Who flies the sector. Rule 4(j) reads this one.' },
                                   flight: _{ type: string, description: 'Flight number, such as "BA117".' },
                                   dep: _{ type: string,
                                           description: 'Local wall-clock departure, "YYYY-MM-DDTHH:MM". \c
                                                         A zone designator is accepted and then discarded.' },
                                   arr: _{ type: string, description: 'Local wall-clock arrival, "YYYY-MM-DDTHH:MM".' },
                                   stop: _{ type: string,
                                            description: 'What the point after this sector counts as: \c
                                                          stopover, or transfer. Worked out from the ground \c
                                                          time when times are given.' },
                                   bookingClass: _{ type: string,
                                                    description: 'The single RBD letter the sector is sold in. \c
                                                                  Leave it out when it is not known: rule 5(b) \c
                                                                  measures the class that was booked, and a \c
                                                                  guessed one would report a pass nobody measured.' },
                                   fareFamily: _{ type: string, enum: [flex, essential, light],
                                                  description: 'The branded fare. No fare rule reads it; \c
                                                                Cathay cannot be priced to a single number without it.' } },
                              required: [from, to] } },
            origin: _{ type: string,
                       description: 'IATA code the journey starts from. Defaults to the departure point of segment 1.' },
            cabin: _{ type: string, enum: [economy, business, first],
                      description: 'Defaults to economy.' },
            passengers: _{ type: array,
                           description: 'Who is travelling. Read by rule 19 only.',
                           items: _{ type: object,
                                     properties: _{ type: _{ type: string, enum: [adult, child, infant] },
                                                    age: _{ type: integer } } } },
            members: _{ type: object,
                        description: 'Membership tier per programme, such as {"qff": {"tier": "gold"}}. \c
                                      Read by the earning side only.' } } }).

add_properties(Schema, Extra, Out) :-
    get_dict(properties, Schema, Props),
    put_dict(Extra, Props, Merged),
    put_dict(properties, Schema, Merged, Out).

tool_json(_{ name: Name, title: Title, description: Description, inputSchema: Schema }) :-
    tool(Name, Title, Description, Schema).

%! tool_operation(+ToolName, +Args, -Op, -OpArgs) is det.
%
%  Which operation a tool call means, and the arguments to run it with.
%
%  For every tool but `itinerary` this is the identity: the tool is named after
%  its operation. `itinerary` carries the operation in a required `op`
%  parameter, which is read here and then REMOVED -- json_in.pl validates the
%  argument dict strictly and would reject `op` as an unknown field, so leaving
%  it in would turn every call into an input error.
%
%  A bad `op` is a caller mistake, so it comes back as an input error naming the
%  four it could have been, rather than as a JSON-RPC error that reads to a
%  model as a broken transport.
tool_operation(itinerary, Args, Op, OpArgs) :-
    !,
    (   get_dict(op, Args, Op0)
    ->  atom_string(Op, Op0)
    ;   throw(mcp_error(-32602,
                        'An itinerary call needs "op": one of validate, earn, \c
                         classes or routing.'))
    ),
    (   memberchk(Op, [validate, earn, classes, routing])
    ->  true
    ;   format(atom(M),
               'Unknown op: ~w. It is one of validate, earn, classes or routing.',
               [Op]),
        throw(mcp_error(-32602, M))
    ),
    del_dict(op, Args, _, OpArgs).
tool_operation(Name, Args, Name, Args).

% --- calling a tool --------------------------------------------------------

% A tool result carries two renderings of one answer. `content` is the text
% src/explain.pl writes, which was written to be read once and is two orders of
% magnitude smaller than the report it summarises. `structuredContent` is the
% report itself, trimmed of what only a map needs.
%
% Input the caller can fix comes back as a result with isError, not as a
% JSON-RPC error. A model can read the first and try again; the second reads to
% it as a broken transport. That split is why op_error_reply/3 returns the
% status separately from the message.
call_tool(Op, Args, Result) :-
    catch(( run(Op, Args, Dict, Text0)
          ->  Status = 200
          ;   Status = 500, op_failed_reply(Op, Dict)
          ),
          Error,
          op_error_reply(Error, Status, Dict)),
    (   Status == 200
    ->  shape(Op, Args, Dict, Text0, Text, Structured),
        Result = _{ resultType: complete,
                    content: [_{ type: text, text: Text }],
                    structuredContent: Structured,
                    isError: false }
    ;   Result = _{ resultType: complete,
                    content: [_{ type: text, text: Dict.message }],
                    isError: true },
        (   Status == 500
        ->  ( get_dict(detail, Dict, D) -> true ; D = 'no detail' ),
            internal_error(Op, D)
        ;   true
        )
    ).

% The two operations with a renderer of their own are run through rtw_render/5,
% which produces the text and the report from a single pass. The rest have no
% report term behind them, so the text is written here from the dict.
run(Op, Args, Dict, Text) :-
    explain_options(Op, Args, Opts),
    rtw_render(Op, Args, Opts, Dict, Text), !.
run(Op, Args, Dict, none) :-
    rtw_do(Op, Args, Dict).

explain_options(validate, Args, Opts) :-
    !,
    (   flag(Args, checks)
    ->  Opts = [checks(true)]
    ;   Opts = [checks_hint('with "checks": true')]
    ).
explain_options(_, _, []).

%! shape(+Tool, +Args, +Dict, +Text0, -Text, -Structured) is det.

% The check register is 4,996 bytes on a seven-sector journey and answers a
% question nobody asked unless they asked it. The annotations are another 5,742,
% of which the part a reader can use is the one-line routing. So both come off
% by default and the routing is promoted to the top level, which is where a
% caller would look for it anyway.
shape(validate, Args, Dict, Text, Text, Structured) :- !,
    Annotations = Dict.annotations,
    (   get_dict(routing, Annotations, R) -> Routing = R ; Routing = null ),
    del_dict(annotations, Dict, _, Trimmed0),
    (   flag(Args, checks) -> Trimmed1 = Trimmed0 ; del_dict(checks, Trimmed0, _, Trimmed1) ),
    (   flag(Args, annotations)
    ->  Structured = Trimmed1.put(_{ routing: Routing, annotations: Annotations })
    ;   Structured = Trimmed1.put(routing, Routing)
    ).
shape(earn, _, Dict, Text, Text, Dict) :- !.
shape(classes, _, Dict, _, Text, Dict) :- !,
    with_output_to(string(Text), write_classes(Dict)).
shape(routing, _, Dict, _, Text, Dict) :- !,
    format(atom(Text), '~w', [Dict.route]).
shape(airports, _, Dict, _, Text, Dict) :- !,
    with_output_to(string(Text), write_airports(Dict)).
% These two are the reference tools, and for them the data *is* the answer --
% there is no verdict to render and no prose that would be shorter than the
% figures. They used to return a version line and a list of programme names,
% with everything they exist to deliver carried only in `structuredContent`.
% That is the field a client is least likely to show its reader: it has no
% output schema to validate against here, and clients routinely pass only the
% text blocks to the model. So `ruleset`, whose description says to read it
% rather than assume a number, delivered one line and nothing to read.
%
% The serialized JSON goes in the text, which is also what the specification
% asks of a tool returning structured content. `rtw://ruleset` and
% `rtw://programs` already do exactly this; a reader should not have to know
% that the resource carries more than the tool of the same name.
shape(ruleset, _, Dict, _, Text, Dict) :- !,
    json_text(Dict, Text).
shape(programs, _, Dict, _, Text, Dict) :-
    json_text(Dict, Text).

%! json_text(+Dict, -Text) is det.
%  Wrapped at a width rather than written on one line: unlike the resources,
%  which are read by whatever asked for a document, this is read by someone
%  scanning for a number.
%  A string rather than an atom, which is what every other renderer here
%  produces -- `with_output_to(string(...))` throughout. The resources use
%  `as(atom)`; nothing downstream cares, but a caller writing an assertion does.
json_text(Dict, Text) :-
    atom_json_dict(Text, Dict, [as(string), width(72)]).

write_classes(Dict) :-
    (   Dict.fareBasis == null
    ->  format('Fare basis: none published; read against the ~w cabin.~n', [Dict.cabin])
    ;   format('Fare basis: ~w; read against that column.~n', [Dict.fareBasis])
    ),
    forall(member(S, Dict.segments), write_class_line(S)).

write_class_line(S) :-
    (   S.reason \== null
    ->  format('  [~w] ~w-~w  ~w~n', [S.n, S.from, S.to, S.reason])
    ;   atomic_list_concat(S.classes, ' ', Codes),
        findall(Text,
                ( member(A, S.alternates),
                  format(atom(Text), '~w (~w)', [A.code, A.note]) ),
                Alts),
        (   Alts == []
        ->  format('  [~w] ~w-~w  ~w  ~w~n', [S.n, S.from, S.to, S.marketingCarrier, Codes])
        ;   atomic_list_concat(Alts, ', ', AltText),
            format('  [~w] ~w-~w  ~w  ~w  or ~w~n',
                   [S.n, S.from, S.to, S.marketingCarrier, Codes, AltText])
        )
    ).

write_airports(Dict) :-
    (   Dict.results == []
    ->  format('No airport matches "~w".~n', [Dict.query])
    ;   forall(member(R, Dict.results),
               format('~w  ~w, ~w~n', [R.iata, R.city, R.country]))
    ).

flag(Args, Key) :-
    get_dict(Key, Args, V),
    V == true.

% --- resources -------------------------------------------------------------

% The two reference documents, plus the transcription of the tariff itself.
% They are tools as well, because a client that does not read resources would
% otherwise have no way to reach them, and a model needs the routing grammar
% before it can write a routing.
resource('rtw://ruleset', 'The ruleset',
         'Version, caps, carriers, city codes, routing grammar, fare-basis table, \c
          section 5(b) booking codes and surcharge bands.',
         'application/json').
resource('rtw://programs', 'The loyalty programmes',
         'Programmes, currencies, tiers, fare families, and the source of every table.',
         'application/json').
resource('rtw://rules', 'Rule 3015, transcribed',
         'The tariff text every citation in a violation points at. Read it to check any \c
          answer this server gives against the rule it came from.',
         'text/markdown').

resource_json(_{ uri: Uri, name: Name, title: Name, description: Description, mimeType: Mime }) :-
    resource(Uri, Name, Description, Mime).

resource_content('rtw://ruleset', 'application/json', Text) :-
    rtw_do(ruleset, _{}, Dict),
    atom_json_dict(Text, Dict, [as(atom), width(0)]).
resource_content('rtw://programs', 'application/json', Text) :-
    rtw_do(programs, _{}, Dict),
    atom_json_dict(Text, Dict, [as(atom), width(0)]).
resource_content('rtw://rules', 'text/markdown', Text) :-
    rules_path(File),
    read_file_to_string(File, Text, [encoding(utf8)]).

% The path is resolved against this file at compile time rather than against the
% working directory, so the server can be started from anywhere. server.pl reads
% its assets at compile time as well, and for a stronger version of the same
% reason. This one is read per request because it is 17 KB that most sessions
% never ask for, and there is no request thread to keep off the filesystem.
:- dynamic rules_path/1.

:- prolog_load_context(directory, Dir),
   file_directory_name(Dir, Prolog),
   file_directory_name(Prolog, Root),
   atomic_list_concat([Root, '/parsed-rules-aug-2026.md'], Path),
   assertz(rules_path(Path)).

% --- writing a reply -------------------------------------------------------

error_reply(Id, Code, Message,
            _{ jsonrpc: '2.0', id: Id,
               error: _{ code: Code, message: Message } }).

% -32022 is the code the specification gives this case, and the list of versions
% is what lets the client pick one and ask again rather than give up.
version_error(Id, Supported, Requested,
              _{ jsonrpc: '2.0', id: Id,
                 error: _{ code: -32022,
                           message: 'Unsupported protocol version',
                           data: _{ supported: Supported, requested: Requested } } }).

% width(0) turns off the line breaking atom_json_dict does by default. The
% transport is one message per line, so a newline inside a message ends it early
% and everything after it is read as a line that is not JSON.
write_message(Dict) :-
    atom_json_dict(Atom, Dict, [as(atom), width(0)]),
    format(user_output, '~w~n', [Atom]),
    flush_output(user_output).

% A bug in a rule is reported to stderr, where whoever started the server can
% read it. It cannot go to stdout, and the caller is told only that it happened.
internal_error(What, Error) :-
    format(user_error, 'mcp: ~w raised ~q~n', [What, Error]).
