# The Budget server for Docker: built from this checkout on swift:6.2-noble, run on the slim image (as on the Olares).
# compose.yaml beside this builds it with the repo root as the context; ./setup.sh server docker runs that.
FROM swift:6.2-noble AS build
WORKDIR /src
COPY Packages Packages
COPY Server Server
RUN cd Server && swift build -c release --static-swift-stdlib --product BudgetServer \
 && strip -o /budget-server .build/release/BudgetServer

FROM swift:6.2-noble-slim
RUN useradd --system --no-create-home budget
COPY --from=build /budget-server /usr/local/bin/budget-server
# Inside the container it listens on every interface; compose.yaml publishes both ports on the host's 127.0.0.1 only.
ENV HOST=0.0.0.0 PORT=8080 DASHBOARD_PORT=8081
EXPOSE 8080 8081
USER budget
ENTRYPOINT ["budget-server"]
