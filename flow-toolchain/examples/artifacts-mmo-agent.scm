;; artifacts-mmo-agent: drives the ArtifactsMMO character AriaWeft using
;; taskweft's own RECTGTN discipline (taskweft/taskweft's docs/rectgtn.md,
;; the model behind the mcp__taskweft__plan/replan tools this repo already
;; uses for plan/bootstrap-domain.json): a todo-list of TwCalls, methods
;; that decompose a compound task into subtasks, actions that are the
;; primitives - but run as a live plan/execute/replan loop, not a single
;; static plan computed once and blindly executed. RECTGTN's own soundness
;; contract (docs/rectgtn.md) is built around replanning from whatever
;; state execution actually reached, exactly because a plan can go stale;
;; a live game world (cooldowns, position, resource availability) is
;; exactly that situation, more so than the offline plan/bootstrap-domain.json
;; taskweft-lite.scm plans against once and never re-checks.
;;
;; Where this differs from taskweft-lite.scm: that domain's methods are
;; pure data (fixed subtask lists - fine for a domain with one static
;; answer). Real RECTGTN methods can compute their subtasks from current
;; state (GTPyHOP, which taskweft's model descends from, works this way -
;; methods are functions, not tables). Here, "harvest"'s subtasks depend on
;; where the nearest tile for a resource actually is, discovered by
;; querying the live map - so methods here are Scheme procedures over
;; state, decomposed lazily, one task at a time, right before it runs -
;; not a plan committed to in full up front.
;;
;; Native s7 devtool tier (ADR 0006 item 10, no sandbox - real network
;; I/O). Transport is curl via s7_http_ffi.c's (http-request ...),
;; already proven against this same live server. No JSON library is
;; vendored; parsing is the same small purpose-built scanners as before.

(define api-base "https://api.artifactsmmo.com")
(define character-name "AriaWeft")
(define api-key (getenv "ARTIFACTS_MMO_APIKEY"))

(define (api-get path)
  (http-request "GET" (string-append api-base path) api-key ""))

(define (api-post path body)
  (http-request "POST" (string-append api-base path) api-key body))

;; --- tiny purpose-built JSON field readers (same approach as taskweft-lite.scm) ---

(define (find-substring haystack needle start)
  (let ((hlen (length haystack)) (nlen (length needle)))
    (let loop ((i start))
      (cond ((> (+ i nlen) hlen) #f)
            ((string=? (substring haystack i (+ i nlen)) needle) i)
            (else (loop (+ i 1)))))))

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

(define (json-error-code json)
  (json-int-field json "code"))

(define (has-error json)
  (find-substring json "\"error\":" 0))

;; --- RECTGTN actions: the primitives. Each returns (values ok? response). ---

(define (action-move x y)
  (let ((body (string-append "{\"x\":" (number->string x) ",\"y\":" (number->string y) "}")))
    (api-post (string-append "/my/" character-name "/action/move") body)))

(define (action-gather)
  (api-post (string-append "/my/" character-name "/action/gathering") ""))

;; --- state readers, queried fresh each time - never cached across steps ---

(define (character-state)
  (api-get (string-append "/characters/" character-name)))

(define (state-xy state)
  (list (json-int-field state "x") (json-int-field state "y")))

;; Where taskweft's own methods would look up a domain fact, this queries
;; the live map for the nearest tile carrying the given resource content
;; code - the "relationship" a method decomposes against is the current
;; world, not a precomputed table.
(define (nearest-resource-tile resource-code)
  (let ((response (api-get (string-append "/maps?content_code=" resource-code "&size=1"))))
    (let ((x (json-int-field response "x"))
          (y (json-int-field response "y")))
      (if (and x y) (list x y) #f))))

;; --- RECTGTN method: "harvest" decomposes a resource-code goal into
;; move (if needed) + gather, computed against fresh state - this is the
;; lazy, one-task-at-a-time decomposition the plan/execute/replan loop
;; below relies on, not a subtask list fixed at plan time. ---

(define (decompose-harvest resource-code)
  (let* ((tile (nearest-resource-tile resource-code))
         (state (character-state))
         (xy (state-xy state)))
    (if (not tile)
        (begin (display "   no known tile for ") (display resource-code) (newline) '())
        (if (equal? xy tile)
            (list (list 'gather))
            (list (list 'move (car tile) (cadr tile)) (list 'gather))))))

;; --- executor with replan-on-failure: runs one primitive action against
;; the live server; on cooldown (499) it waits and retries the SAME
;; action (the state that made this action valid hasn't changed, only
;; time has); on any other error it reports failure so the caller
;; re-decomposes from fresh state instead of pressing on with a stale plan. ---

(define (execute-action task)
  (display "   ") (display task) (display " ... ")
  (let* ((kind (car task))
         (ok (cond
               ((eq? kind 'move)
                (let ((response (action-move (cadr task) (caddr task))))
                  (execute-with-cooldown-retry response (lambda () (action-move (cadr task) (caddr task))))))
               ((eq? kind 'gather)
                (execute-with-cooldown-retry (action-gather) action-gather))
               (else (display "unknown action") (newline) #f))))
    (if ok (display "ok\n"))
    ok))

(define (execute-with-cooldown-retry response retry-thunk)
  (cond
    ((not (has-error response))
     (wait-out-cooldown response)
     #t)
    ((equal? (json-error-code response) 499)
     (let ((remaining (json-int-field response "remaining_seconds")))
       (display "   in cooldown (") (display remaining) (display "s) - waiting, then retrying\n")
       (agent-sleep (+ (if remaining remaining 5) 1))
       (execute-with-cooldown-retry (retry-thunk) retry-thunk)))
    (else
     (display "   action failed: ") (display response) (newline)
     #f)))

(define (wait-out-cooldown response)
  (let ((cd (json-int-field response "remaining_seconds")))
    (if (and cd (> cd 0))
        (agent-sleep (+ cd 1))
        #f)))

;; --- the RECTGTN loop itself: for each goal in the todo-list, decompose
;; against current state one task at a time, execute, and if a task
;; fails for a reason cooldown-retry doesn't resolve, re-decompose the
;; SAME goal against fresh state (the taskweft replan discipline) rather
;; than aborting the whole run over one stale assumption. ---

(define (run-goal resource-code attempts-left)
  (if (<= attempts-left 0)
      (begin (display "   giving up on ") (display resource-code) (display " - too many replans\n") #f)
      (let ((tasks (decompose-harvest resource-code)))
        (let loop ((remaining tasks))
          (if (null? remaining)
              #t
              (if (execute-action (car remaining))
                  (loop (cdr remaining))
                  (begin
                    (display "   replanning ") (display resource-code) (newline)
                    (run-goal resource-code (- attempts-left 1)))))))))

(define todo-list '("ash_tree" "copper_rocks" "sunflower_field" "gudgeon_spot"))

(define (run-agent)
  (display "=== RECTGTN loop for ") (display character-name) (display " ===\n")
  (for-each
    (lambda (resource-code)
      (display "--- goal: harvest ") (display resource-code) (display " ---\n")
      (run-goal resource-code 3))
    todo-list)
  (display "=== done ===\n"))

(run-agent)
