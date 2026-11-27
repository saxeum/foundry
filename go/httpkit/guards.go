package httpkit

import (
	"errors"
	"mime"
	"net/http"
)

// MaxBodyBytes is the largest request body the platform will read. It is a
// transport guard, not a domain limit: the generated strict handler decodes the
// body before any strict middleware runs, so this has to sit in front.
const MaxBodyBytes = 1 << 20

// BodyGuards applies the two checks the generated code does not make: how large
// a body may be, and what media type it must claim. Both are request-shaping, so
// both belong in front of everything else.
func BodyGuards(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Body != nil && r.Body != http.NoBody {
			r.Body = http.MaxBytesReader(w, r.Body, MaxBodyBytes)
		}

		// Only when there is a body to describe. A POST with nothing in it is not
		// a media-type problem, and routing must get the chance to answer 405
		// before anything here does.
		// -1 means an unknown length (chunked), which still carries a body.
		if carriesBody(r.Method) && r.ContentLength != 0 && !isJSON(r.Header.Get("Content-Type")) {
			WriteJSON(w, http.StatusUnsupportedMediaType, ErrorBody(http.StatusUnsupportedMediaType))
			return
		}

		next.ServeHTTP(w, r)
	})
}

func carriesBody(method string) bool {
	switch method {
	case http.MethodPost, http.MethodPut, http.MethodPatch:
		return true
	}
	return false
}

// isJSON tolerates the charset parameter real clients send. It is deliberately
// strict about the media type itself: text/plain, multipart/form-data and
// application/x-www-form-urlencoded are the three a cross-site form can send
// without a preflight.
func isJSON(contentType string) bool {
	if contentType == "" {
		return false
	}
	mediaType, _, err := mime.ParseMediaType(contentType)
	if err != nil {
		return false
	}
	return mediaType == "application/json"
}

// IsBodyTooLarge reports whether the decoder failed because MaxBytesReader cut
// the body off, which is a 413 rather than the 400 a malformed body gets.
func IsBodyTooLarge(err error) bool {
	var tooLarge *http.MaxBytesError
	return errors.As(err, &tooLarge)
}
