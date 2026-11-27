package httpkit

import (
	"net"
	"net/http"
	"net/netip"
	"strings"
)

// ClientIP is the address the request came from, as far as anything can know it.
//
// Behind the ALB, RemoteAddr is the load balancer, so every session recorded the
// same address and a per-client limit would have counted the whole internet as
// one client. The ALB appends the address it saw to X-Forwarded-For, which is
// what makes the *last* entry trustworthy and everything to its left whatever
// the client chose to claim: take the last, ignore the rest.
//
// A header that does not end in an address is ignored rather than trusted,
// because the fallback — the peer we are actually talking to — is at least true.
//
// This assumes exactly one trusted proxy, which is true of both paths: the ALB
// in the cluster, and the nginx load balancer in front of it locally. If a
// second hop appears, this is the line that becomes a spoofing hole.
func ClientIP(r *http.Request) string {
	if addr, ok := forwardedClientIP(r.Header.Values("X-Forwarded-For")); ok {
		return addr
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// forwardedClientIP reads the last address in one or more X-Forwarded-For
// headers. Several headers are equivalent to one comma-joined header in every
// proxy that writes them, so they are flattened the same way.
func forwardedClientIP(values []string) (string, bool) {
	last := ""
	for _, value := range values {
		for _, part := range strings.Split(value, ",") {
			if part = strings.TrimSpace(part); part != "" {
				last = part
			}
		}
	}
	return parseClientAddr(last)
}

// parseClientAddr accepts an address with or without the port a proxy may have
// recorded next to it, and returns it in canonical form so the column is
// comparable.
func parseClientAddr(raw string) (string, bool) {
	if raw == "" {
		return "", false
	}
	if host, _, err := net.SplitHostPort(raw); err == nil {
		raw = host
	}
	addr, err := netip.ParseAddr(raw)
	if err != nil {
		return "", false
	}
	return addr.String(), true
}
