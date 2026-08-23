% run_tests.pl -- test entry point.
%
%   swipl -g run_tests -t halt prolog/test/run_tests.pl
%
% This is separate from prolog/load.pl so a server process carries neither plunit
% nor the fixtures.

:- ensure_loaded('../load').

:- use_module(library(plunit)).
:- use_module(test_geo).
:- use_module(test_rules).
:- use_module(test_route).
:- use_module(test_json).
:- use_module(test_mcp).
:- use_module(earn/conformance).
:- use_module(test_earn).
