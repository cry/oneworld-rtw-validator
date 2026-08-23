# oneworld Explorer validator.
#
#   docker build -t rtw-validator .
#   docker run --rm -p 8080:8080 rtw-validator
#
# A single stage on purpose, because there is nothing to compile. The airport
# table is committed, so the build needs no network and the image can be rebuilt
# from the repository alone.

# Pinned rather than :stable, which moves. If you want the build to survive
# registry changes, get a digest with
#   docker buildx imagetools inspect swipl:10.0.2
# and commit that instead.
FROM swipl:10.0.2

# tini reaps zombies and forwards signals. SWI's daemon handles SIGTERM itself, so
# this is only a safety net for anything it spawns. Drop it and use
# `docker run --init` if you prefer.
RUN apt-get update \
 && apt-get install -y --no-install-recommends tini curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# The order matters for layer caching. Data changes rarely; rules change often.
COPY prolog/data   ./prolog/data
COPY prolog/tools  ./prolog/tools
COPY prolog/src    ./prolog/src
COPY prolog/load.pl prolog/server.pl prolog/daemon.pl prolog/cli.pl ./prolog/
COPY web           ./web

# If anything fails to load, fail the build rather than the first request. This
# also reads web/index.html into the program -- see the note in server.pl -- so a
# missing UI is a build error rather than a 404 in production.
RUN swipl -g "use_module('/app/prolog/server')" -g "halt(0)" -t "halt(1)"

# The image ships no test suite and no fixtures. Run those in CI against the
# source tree. Nothing under /app needs to be writable, so the container can run
# with --read-only.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin rtw \
 && chown -R root:root /app && chmod -R a=rX /app
USER 10001

EXPOSE 8080

# --no-fork keeps the daemon in the foreground, so Docker owns the lifecycle and
# SIGTERM reaches it. --stack-limit turns a runaway query into a resource error
# instead of letting the OOM killer take the whole container; workers inherit the
# limit from the main thread.
#
# This is the exec form, so swipl is the process that gets signalled rather than
# a shell.
ENTRYPOINT ["/usr/bin/tini", "--", \
            "swipl", "--stack-limit=512m", "/app/prolog/daemon.pl", "--no-fork"]
CMD ["--port=8080", "--workers=16"]

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -fsS http://localhost:8080/api/health || exit 1
