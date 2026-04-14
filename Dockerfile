# Build the server with the Dart SDK, then copy the compiled exe into
# a minimal runtime. The sibling ../core package is required at build
# time because pubspec.yaml pulls it via a path dependency.
FROM dart:3.5 AS build

WORKDIR /app

# Copy the sibling core package first so pub get can resolve the path
# dependency. The build context is expected to be the parent directory
# (../ in docker-compose) so both packages are visible.
COPY core/ /app/core/
COPY keycase/pubspec.yaml keycase/pubspec.lock* /app/keycase/

WORKDIR /app/keycase
RUN dart pub get

COPY keycase/ /app/keycase/
RUN dart pub get --offline
RUN dart compile exe bin/server.dart -o /app/keycase/bin/server

# Runtime image — dart:3.5 also ships a `runtime` tag that's smaller,
# but using scratch + runtime-deps keeps the image under 30MB.
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/keycase/bin/server /app/bin/server
COPY --from=build /app/keycase/db /app/db

WORKDIR /app
EXPOSE 8080
CMD ["/app/bin/server"]
