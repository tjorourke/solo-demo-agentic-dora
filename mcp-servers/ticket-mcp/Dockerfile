FROM golang:1.25 AS build

WORKDIR /src
COPY go.mod go.sum* ./
COPY main.go ./
RUN go mod tidy
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/ticket-mcp .

FROM gcr.io/distroless/static-debian12
COPY --from=build /out/ticket-mcp /ticket-mcp

EXPOSE 8080
ENTRYPOINT ["/ticket-mcp"]
