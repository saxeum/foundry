package httpkit

import (
	"encoding/json"
	"net/http"
)

// Error is the JSON shape every non-2xx response from an app shares. It is
// deliberately small: a 5xx body says nothing about the cause, because the
// cause belongs in the log with the request id.
type Error struct {
	Error string `json:"error"`
}

// ErrorBody maps a status to the body the platform writes. A 4xx says what the
// status says; a 5xx says nothing useful on purpose.
func ErrorBody(status int) Error {
	if status >= 500 {
		return Error{Error: "internal server error"}
	}
	return Error{Error: http.StatusText(status)}
}

// WriteJSON is the one way this package writes a body. Encoder, not Marshal, so
// the bytes match the generated response visitors an app may also use.
func WriteJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
