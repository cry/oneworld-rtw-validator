#!/usr/bin/env swipl
% mcp.pl -- Model Context Protocol entry point.
%
%   swipl prolog/mcp.pl
%
% JSON-RPC 2.0 over stdin and stdout, one message per line. The protocol is in
% src/mcp.pl and the operations it answers are in src/ops.pl, which is the same
% table the browser reaches through wasm.pl. This file is the process: it fixes
% the stream encodings and runs the loop, the way daemon.pl does for server.pl.
%
% A client is configured to start it like this:
%
%   { "mcpServers": { "rtw": { "command": "swipl",
%                              "args": ["/path/to/prolog/mcp.pl"] } } }
%
% There is no port, no socket and no configuration. The validator holds no
% credentials and reads no network, so a session is a pipe to a process that
% exits when the pipe closes.

:- initialization(main, main).

:- ensure_loaded('load').
:- use_module('src/mcp').

% UTF-8 both ways, and set here rather than in the module because it is a
% property of this process rather than of the protocol. A city name with an
% accent in it reaches the reader as it was written.
main(_Argv) :-
    set_stream(user_input,  encoding(utf8)),
    set_stream(user_output, encoding(utf8)),
    set_stream(user_error,  encoding(utf8)),
    mcp_loop.
