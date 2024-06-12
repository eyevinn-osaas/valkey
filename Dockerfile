FROM ubuntu:20.04 as build
RUN apt-get update
RUN apt-get install -y build-essential

WORKDIR /src
COPY . .
RUN make
RUN make install

FROM ubuntu:20.04
COPY --from=build /usr/local/bin/ /usr/local/bin/
COPY --from=build /src/valkey.conf /etc/valkey.conf
COPY --from=build /src/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT [ "/usr/local/bin/docker-entrypoint.sh" ]