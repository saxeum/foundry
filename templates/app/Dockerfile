# The app image: /app-api serves, /app-migrate applies the embedded SQL. The
# migration Job runs this same digest, so schema and binary cannot diverge.
FROM golang:1.27-alpine AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .

RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/app-api ./cmd/web && \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/app-migrate ./cmd/migrate

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/app-api /app-api
COPY --from=build /out/app-migrate /app-migrate
EXPOSE 4000
ENTRYPOINT ["/app-api"]
