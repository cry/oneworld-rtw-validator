% daemon.pl -- production entry point.
%
%   swipl prolog/daemon.pl --no-fork --port=8080 --workers=16
%
% library(http/http_unix_daemon) gives us two things. First, the whole daemon
% CLI: --port, --ip, --user, --group, --workers, --pidfile, --fork, --syslog,
% --https and the certificate options. Second, and more important, the signal
% handling. SIGINT and SIGTERM shut the server down without abandoning requests
% in flight, SIGHUP reloads, and SIGUSR1 reopens log files.
%
% `cli.pl serve` has none of that. It parks the main thread on a message that
% never arrives, so a SIGTERM kills work mid-request. Use cli.pl to develop and
% this file to deploy.
%
% Pass --no-fork under a supervisor that wants a foreground process, such as
% systemd Type=simple or Docker, where this runs as PID 1. Only the parent needs
% to be root, and only to bind a privileged port; --user drops privileges
% afterwards.
%
% The loading order follows the library's own documented example: the daemon
% library first, then the application. No entry point is declared here, because
% http_unix_daemon already declares initialization(http_daemon, main). Declaring
% it again would run the server twice.

:- use_module(library(http/http_unix_daemon)).

:- ensure_loaded('load').

% server.pl is what registers the http_handler/3 directives. The daemon starts
% http_dispatch/1 itself, so server:server/1 is left uncalled here on purpose.
:- use_module('server').
