% load.pl -- entry point.
%
%   swipl prolog/load.pl                    interactive session
%   swipl -g run_tests -t halt prolog/load.pl
%
% This is not a module, on purpose. use_module/1 called from a plain file
% imports into `user`, so an interactive session can see every exported
% predicate without qualifying anything.
%
% Every path below is relative to this file, so the loader works from any
% working directory. No file_search_path alias is needed.

:- use_module('data/limits').
:- use_module('data/cities').
:- use_module('data/countries').
:- use_module('data/overrides').
:- use_module('data/transcon').
:- use_module('data/au_pairs').
:- use_module('data/surcharges').
:- use_module('data/booking_codes').

:- use_module('src/geo').
:- use_module('src/carriers').
:- use_module('src/fold').
:- use_module('src/phrasing').
:- use_module('src/itinerary').
:- use_module('src/annotate').
:- use_module('src/pricing').
:- use_module('src/validate').
:- use_module('src/explain').

% What a routing earns. This runs no fare rules: what a ticket earns and
% whether it may be sold are two separate questions. src/earn/registry.pl is
% the only file that names the programmes; the kernel names none of them.
% See PLANS/05-loyalty-earning.md.
:- use_module('src/earn/kernel').
:- use_module('src/earn/registry').
:- use_module('src/earn/explain').

:- use_module('src/io/route_in').
:- use_module('src/io/route_out').
:- use_module('src/io/json_in').
:- use_module('src/io/json_out').
:- use_module('src/io/earn_out').

% Rule modules export nothing. Loading one is what registers its clauses of
% validate:violation/2. There is no other registry.
:- use_module('src/rules/r00_continents').
:- use_module('src/rules/r04_routing').
:- use_module('src/rules/r05_booking').
:- use_module('src/rules/r06_min_stay').
:- use_module('src/rules/r07_max_stay').
:- use_module('src/rules/r08_stopovers').
:- use_module('src/rules/r15_sales').
:- use_module('src/rules/r19_discounts').

% Rule 9 (transfers) has no module because there is nothing to check.
% "Unlimited online/interline transfers permitted between [the eligible
% carriers]" grants a permission rather than setting a limit, and 4(j) already
% checks the carriers.

% Test suites load only when tests are being run, so a server process never
% carries plunit or the fixtures.
:- if(current_prolog_flag(rtw_tests, true)).
:- use_module(library(plunit)).
:- ensure_loaded('test/test_geo').
:- ensure_loaded('test/test_rules').
:- ensure_loaded('test/test_route').
:- ensure_loaded('test/test_json').
:- ensure_loaded('test/earn/conformance').
:- ensure_loaded('test/test_earn').
:- endif.
