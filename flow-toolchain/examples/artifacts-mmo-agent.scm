;; artifacts-mmo-agent: drives the ArtifactsMMO character AriaWeft through
;; one real taskweft-style plan (move to a resource, gather it), decided
;; and executed entirely in s7 - not by hand-issued curl calls. Extends
;; taskweft-lite.scm's HTN style (a plan is a flat list of primitive
;; actions, each with pre-decided effects) to a live external API instead
;; of the offline plan/bootstrap-domain.json.
;;
;; Native s7 devtool tier (ADR 0006 item 10, no sandbox - this needs real
;; network I/O, which the RISC-V guest tier deliberately has none of).
;; Transport is curl via the FFI in s7_http_ffi.c (install_http_ffi),
;; already proven against this same live server. Not the vendored
;; picoquic H3 client: that path still needs a QPACK header encoder for
;; Authorization (ADR-tracked, unstarted) - Gall's Law says solve the
;; actual problem (play the game) with what already works, not block on
;; the harder transport.
;;
;; No JSON library is vendored; ArtifactsMMO's responses are parsed here
;; with small purpose-built scanners for the handful of fields this
;; domain actually needs (x, y, cooldown seconds, error code/message),
;; not a general JSON parser.

(define api-base "https://api.artifactsmmo.com")
(define character-name "AriaWeft")
(define api-key (getenv "ARTIFACTS_MMO_APIKEY"))

(define (api-get path)
  (http-request "GET" (string-append api-base path) api-key ""))

(define (api-post path body)
  (http-request "POST" (string-append api-base path) api-key body))

;; --- tiny purpose-built JSON field readers ---

(define (find-substring haystack needle start)
  (let ((hlen (length haystack)) (nlen (length needle)))
    (let loop ((i start))
      (cond ((> (+ i nlen) hlen) #f)
            ((string=? (substring haystack i (+ i nlen)) needle) i)
            (else (loop (+ i 1)))))))

;; Reads the integer value of "key":NUMBER (numbers only - every field
;; this domain reads, x/y/cooldown/code, is numeric).
(define (json-int-field json key)
  (let ((key-pos (find-substring json (string-append "\"" key "\":") 0)))
    (if (not key-pos)
        #f
        (let* ((val-start (+ key-pos (length (string-append "\"" key "\":"))))
               (len (length json)))
          (let loop ((i val-start) (digits '()) (neg #f))
            (cond ((and (= i val-start) (< i len) (char=? (json i) #\-))
                   (loop (+ i 1) digits #t))
                  ((and (< i len) (char-numeric? (json i)))
                   (loop (+ i 1) (cons (json i) digits) neg))
                  ((null? digits) #f)
                  (else
                   (let ((n (string->number (list->string (reverse digits)))))
                     (if neg (- n) n)))))))))

(define (has-error json)
  (find-substring json "\"error\":" 0))

;; --- the plan: move to the nearest known ash_tree, then gather it ---
;; (-1, 0) and its resource code were found by querying
;; /maps?content_code=ash_tree against the live server - the nearest
;; level-1 resource to spawn (0,0), one tile away.

(define target-x -1)
(define target-y 0)

(define (wait-out-cooldown response)
  (let ((cd (json-int-field response "remaining_seconds")))
    (if (and cd (> cd 0))
        (begin
          (display "   cooldown: ") (display cd) (display "s - waiting it out\n")
          (agent-sleep (+ cd 1)))
        #f)))

(define (run-agent)
  (display "=== taskweft-style plan for ") (display character-name) (display " ===\n")

  (display "1. fetch current state\n")
  (let* ((state (api-get (string-append "/characters/" character-name)))
         (x (json-int-field state "x"))
         (y (json-int-field state "y")))
    (display "   at (") (display x) (display ",") (display y) (display ")\n")

    (if (and (= x target-x) (= y target-y))
        (display "   already at the target tile - skipping move\n")
        (begin
          (display "2. move action -> (") (display target-x) (display ",") (display target-y) (display ")\n")
          (let* ((body (string-append "{\"x\":" (number->string target-x) ",\"y\":" (number->string target-y) "}"))
                 (move-response (api-post (string-append "/my/" character-name "/action/move") body)))
            (if (has-error move-response)
                (begin (display "   FAILED: ") (display move-response) (newline))
                (begin
                  (display "   moved OK\n")
                  (wait-out-cooldown move-response))))))

    (display "3. gathering action\n")
    (let ((gather-response (api-post (string-append "/my/" character-name "/action/gathering") "")))
      (if (has-error gather-response)
          (begin (display "   FAILED: ") (display gather-response) (newline))
          (begin
            (display "   gathered OK: ") (display gather-response) (newline))))))

(run-agent)
