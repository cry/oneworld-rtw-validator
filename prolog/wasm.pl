% wasm.pl -- entry point for the browser build.
%
% The same rules the server runs, reached from JavaScript instead of over HTTP.
% prolog/tools/build_image.mjs consults this file inside SWI-Prolog compiled to
% WebAssembly and saves the result as web/rtw.pvm. web/worker.js then boots that
% image and calls rtw_call/4. Nothing here decides anything about a fare. Like
% server.pl, this file only renders the same report/3 term, and every predicate
% it calls is one the server calls too.
%
% The operations themselves are in src/ops.pl, which mcp.pl loads as well. This
% file had them first, and a second copy would be a second place for the two
% front ends to disagree about what `earn` means. What is left here is the shape
% the browser needs: one goal, four arguments, always succeeds.
%
% This is not a module, for the same reason load.pl is not: a query from the
% JavaScript side runs in `user`, and predicates defined in a module would not
% be visible there unless every call named the module.
%
% Two facts about the WebAssembly build shape this file.
%
% *A saved image has no autoloading.* Only what was compiled in exists, so a
% goal put together in the browser cannot reach library predicates. Even
% member/2 raises an existence error. That is why rtw_call/4 is the only way in:
% the browser names an operation, never a goal. It also means every library this
% file needs must be imported right here, at build time, where a mistake breaks
% the build instead of the first request.
%
% *library(http/json) is missing*, because the HTTP package is not part of the
% build. library(json) is there and has the same predicates. cli.pl already
% picks between the two, so the same conditional is reused here rather than
% written a second way.

:- ensure_loaded(load).
:- use_module('src/ops').

:- if(exists_source(library(json))).
:- use_module(library(json)).
:- else.
:- use_module(library(http/json)).
:- endif.

:- use_module(library(apply)).
:- use_module(library(lists)).
:- use_module(library(yall)).

%! rtw_call(+Op, +InText, -Status, -OutText) is det.
%
%  One operation per server endpoint, sharing the same names: `validate`,
%  `routing`, `earn`, `classes`, `ruleset`, `airports` and `programs`. InText
%  and OutText are JSON text. Status is the status the server would have replied
%  with: 200, 400 for input the caller can fix, or 500 for a bug in a rule.
%  Sending the status back beats making the browser guess at failure from the
%  shape of the body, and it keeps the front ends describing the same failure
%  the same way.
%
%  This is total and deterministic. An operation that throws and an operation
%  that merely fails both come back as a reply. A predicate that failed where it
%  should have succeeded is a bug in a rule, so it is reported as one. Letting
%  the query fail instead would show up in the browser as a call that never
%  resolved, which is the least useful way for a bug to appear.
rtw_call(Op, In, Status, Out) :-
    catch(( rtw_do(Op, In, Dict)
          ->  Status = 200
          ;   Status = 500, op_failed_reply(Op, Dict)
          ),
          Error,
          op_error_reply(Error, Status, Dict)),
    atom_json_dict(Out, Dict, [as(atom), width(0)]).

% width(0) turns off the line breaking atom_json_dict does by default. Without
% it, any message long enough to wrap arrives with newlines inside it.
