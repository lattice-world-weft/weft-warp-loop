/* SPDX-License-Identifier: MIT */
/* Copyright (c) 2026 K. S. Ernest (iFire) Lee */
/* Minimal s7 FFI: exposes two Scheme-callable functions,
 * (http-request method url bearer-token body) and (agent-sleep seconds),
 * for artifacts-mmo-agent.scm. http-request shells out to curl (already
 * proven against the live ArtifactsMMO API in this same session) and
 * returns its stdout as a string - not a general HTTP client, one
 * purpose-built call for this agent. Native s7 devtool tier only (ADR
 * 0006 item 10) - the RISC-V sandboxed guest tier has no I/O by design,
 * so this FFI has no place there. */
#include "s7.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <time.h>
#endif

/* Escapes embedded double-quotes so a JSON body (which is nothing but
 * double-quoted field names/strings) survives being embedded inside the
 * shell's own double-quoted -d argument. */
static char *shell_escape_quotes(const char *body) {
	size_t len = strlen(body);
	char *out = (char *)malloc(len * 2 + 1);
	size_t j = 0;
	for (size_t i = 0; i < len; i++) {
		if (body[i] == '"') out[j++] = '\\';
		out[j++] = body[i];
	}
	out[j] = '\0';
	return out;
}

static char *build_command(const char *method, const char *url, const char *token, const char *body) {
	/* url/token come from our own generated Scheme code (fixed API paths,
	 * an env-provided token), not untrusted external input, so simple
	 * shell quoting is enough here - this is a devtool script, not a
	 * service parsing attacker-controlled requests. The JSON body's own
	 * quotes still need escaping (see shell_escape_quotes) or curl never
	 * sees valid JSON. */
	char *escaped_body = body ? shell_escape_quotes(body) : NULL;
	size_t cap = strlen(url) + strlen(token) + (escaped_body ? strlen(escaped_body) : 0) + 512;
	char *cmd = (char *)malloc(cap);
	if (escaped_body && escaped_body[0]) {
		snprintf(cmd, cap,
			"curl -s -X %s \"%s\" -H \"Authorization: Bearer %s\" -H \"Content-Type: application/json\" -d \"%s\"",
			method, url, token, escaped_body);
		free(escaped_body);
	} else {
		free(escaped_body);
		snprintf(cmd, cap,
			"curl -s -X %s \"%s\" -H \"Authorization: Bearer %s\"",
			method, url, token);
	}
	return cmd;
}

static s7_pointer g_http_request(s7_scheme *sc, s7_pointer args) {
	const char *method = s7_string(s7_car(args));
	const char *url = s7_string(s7_cadr(args));
	const char *token = s7_string(s7_caddr(args));
	const char *body = s7_string(s7_cadr(s7_cddr(args)));

	char *cmd = build_command(method, url, token, body);
	FILE *p = popen(cmd, "r");
	free(cmd);
	if (!p) return s7_make_string(sc, "");

	size_t cap = 65536, len = 0;
	char *buf = (char *)malloc(cap);
	size_t n;
	while ((n = fread(buf + len, 1, cap - len - 1, p)) > 0) {
		len += n;
		if (len + 1 >= cap) {
			cap *= 2;
			buf = (char *)realloc(buf, cap);
		}
	}
	buf[len] = '\0';
	pclose(p);
	s7_pointer result = s7_make_string(sc, buf);
	free(buf);
	return result;
}

static s7_pointer g_agent_sleep(s7_scheme *sc, s7_pointer args) {
	s7_double seconds = s7_number_to_real(sc, s7_car(args));
	if (seconds > 0) {
#ifdef _WIN32
		Sleep((unsigned long)(seconds * 1000));
#else
		struct timespec ts = { (time_t)seconds, (long)((seconds - (time_t)seconds) * 1e9) };
		nanosleep(&ts, NULL);
#endif
	}
	return s7_make_integer(sc, 0);
}

void install_http_ffi(s7_scheme *sc) {
	s7_define_function(sc, "http-request", g_http_request, 4, 0, false,
		"(http-request method url bearer-token body) -> response body string");
	s7_define_function(sc, "agent-sleep", g_agent_sleep, 1, 0, false,
		"(agent-sleep seconds) -> waits out an ArtifactsMMO action cooldown");
}
