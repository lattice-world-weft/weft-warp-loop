/* SPDX-License-Identifier: MIT */
/* Copyright (c) 2026 K. S. Ernest (iFire) Lee */
/* s7 FFI backed by this project's own artifacts_mmo_h3_client (the
 * vendored picoquic HTTP/3 client, this same directory), replacing
 * s7_http_ffi.c's curl subprocess - the transport is still a subprocess,
 * but now this project's own compiled code, not curl.
 *
 * Direct in-process linking (s7lib + picoquic_vendored in one binary)
 * was tried first and hit a real upstream gap: s7.c's is_decodable()
 * (thirdparty/s7/s7.c ~line 73499) is defined only under
 * "#ifndef _MSC_VER" but still referenced from a call site that isn't
 * excluded the same way, so s7.c fails to link under clang-cl/MSVC
 * specifically - a genuine bug in vendored code this project doesn't
 * patch (vendored files stay unmodified, per this repo's own
 * convention). Mixing s7 built with llvm-mingw (which doesn't define
 * _MSC_VER, so doesn't hit this gap) with picoquic built under clang-cl
 * in one binary was the alternative, but two different C runtimes
 * statically linked into one executable is a real, if narrow, risk
 * this small devtool doesn't need to take on. A subprocess boundary
 * sidesteps both problems entirely.
 *
 * Same (http-request method url bearer-token body) signature as
 * s7_http_ffi.c so artifacts-mmo-agent.scm needs no changes.
 */
#include "s7.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <time.h>
#endif

#ifndef ARTIFACTS_MMO_H3_CLIENT_EXE
#error "ARTIFACTS_MMO_H3_CLIENT_EXE must be defined at build time"
#endif
#ifndef ARTIFACTS_MMO_CACERT_PATH
#error "ARTIFACTS_MMO_CACERT_PATH must be defined at build time"
#endif

/* Escapes embedded double-quotes so a JSON body (nothing but
 * double-quoted field names/strings) survives being embedded inside the
 * shell's own double-quoted command-line argument. The same bug class
 * already fixed once in s7_http_ffi.c's curl-based command builder -
 * recurred here because this is a separate command string, not shared
 * code; artifacts_mmo_h3_client.c's argv[] parsing needs the body as one
 * shell-visible token, same as curl's -d argument did. */
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

static int split_url(const char *url, char *host_out, size_t host_cap, int *port_out, const char **path_out) {
	const char *scheme = "https://";
	size_t scheme_len = strlen(scheme);
	if (strncmp(url, scheme, scheme_len) != 0) return -1;
	const char *rest = url + scheme_len;
	const char *slash = strchr(rest, '/');
	const char *host_end = slash ? slash : rest + strlen(rest);
	const char *colon = memchr(rest, ':', (size_t)(host_end - rest));
	size_t host_len = (colon ? (size_t)(colon - rest) : (size_t)(host_end - rest));
	if (host_len >= host_cap) return -1;
	memcpy(host_out, rest, host_len);
	host_out[host_len] = '\0';
	*port_out = colon ? atoi(colon + 1) : 443;
	*path_out = slash ? slash : "/";
	return 0;
}

static s7_pointer g_http_request(s7_scheme *sc, s7_pointer args) {
	const char *method = s7_string(s7_car(args));
	const char *url = s7_string(s7_cadr(args));
	const char *token = s7_string(s7_caddr(args));
	const char *body = s7_string(s7_cadr(s7_cddr(args)));

	char host[256];
	int port;
	const char *path;
	if (split_url(url, host, sizeof(host), &port, &path) != 0) {
		return s7_make_string(sc, "");
	}

	char cmd[4096];
	/* The outer pair of quotes wrapping the whole string is not
	 * redundant: cmd.exe's own "/c" parsing has a well-known quirk where
	 * a command starting with a quoted path (the .exe) followed by more
	 * arguments gets misparsed ("The filename, directory name, or volume
	 * label syntax is incorrect.") unless the entire command is wrapped
	 * in one more pair of quotes. Confirmed by bisecting with a minimal
	 * popen() reproduction before landing this fix. */
	if (body && body[0]) {
		char *escaped_body = shell_escape_quotes(body);
		snprintf(cmd, sizeof(cmd), "\"\"%s\" %s %d \"%s\" %s %s \"%s\"\"",
			ARTIFACTS_MMO_H3_CLIENT_EXE, host, port, ARTIFACTS_MMO_CACERT_PATH, method, path, escaped_body);
		free(escaped_body);
	} else {
		snprintf(cmd, sizeof(cmd), "\"\"%s\" %s %d \"%s\" %s %s\"",
			ARTIFACTS_MMO_H3_CLIENT_EXE, host, port, ARTIFACTS_MMO_CACERT_PATH, method, path);
	}

	/* artifacts_mmo_h3_client.exe reads the bearer token from
	 * ARTIFACTS_MMO_APIKEY itself (see its main()) - already set in this
	 * process's environment by whatever launched the agent, and
	 * inherited by the child process, so it doesn't need to be passed
	 * on the command line here. */
	(void)token;

	FILE *p = popen(cmd, "r");
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
		"(http-request method url bearer-token body) -> response body string, via artifacts_mmo_h3_client.exe (the vendored picoquic H3 client)");
	s7_define_function(sc, "agent-sleep", g_agent_sleep, 1, 0, false,
		"(agent-sleep seconds) -> waits out an ArtifactsMMO action cooldown");
}
