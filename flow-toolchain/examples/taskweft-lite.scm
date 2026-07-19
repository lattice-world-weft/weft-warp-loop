;; taskweft-lite: a minimal forward-decomposition HTN planner in s7 Scheme.
;;
;; Reimplements the core planning algorithm the `mcp__taskweft__plan` tool
;; already runs against this repo's plan/bootstrap-domain.json - not the
;; full taskweft/nif (C++20, temporal reasoning, ReBAC, HRR) - just the
;; HTN forward-decomposition core, operating on the same domain shape
;; (variables/actions/methods/todo_list), so it can run as native s7
;; devtool content per ADR 0006's item 10 (native host build, no sandbox,
;; no shrubbery reader yet - plain s-expressions until that reader exists).
;;
;; Domain representation (a direct transcription of the JSON shape, not a
;; JSON parser - see the note at the bottom of this file):
;;   actions: alist of name -> (params . body), body is a list of
;;     (pointer-set PATH VALUE) effects, PATH a list of keys, e.g.
;;     '(milestone stack) for JSON-LD's "/milestone/stack".
;;   methods: alist of name -> alternatives, each alternative a list of
;;     subtask-lists (a method decomposes into the first alternative whose
;;     subtasks all decompose/execute successfully - no preconditions in
;;     this minimal core, matching bootstrap-domain.json's own domain,
;;     which has exactly one alternative per method today).
;;   state: an alist-of-alists tree; pointer-set walks/creates nested
;;     alists along PATH and sets the leaf.

;; s7's core does not autoload a `filter` (it lives in an optional
;; library, not the base interpreter this file was tested against) -
;; a tiny hand-written one avoids pulling in extra s7 library files
;; for a single three-line function.
(define (filter pred lst)
  (if (null? lst)
      '()
      (if (pred (car lst))
          (cons (car lst) (filter pred (cdr lst)))
          (filter pred (cdr lst)))))

(define (state-ref state path)
  (if (null? path)
      state
      (let ((entry (assoc (car path) state)))
        (if entry (state-ref (cdr entry) (cdr path)) #f))))

(define (state-set state path value)
  (if (null? (cdr path))
      (cons (cons (car path) value)
            (let ((rest (assoc (car path) state)))
              (if rest (filter (lambda (kv) (not (equal? (car kv) (car path)))) state) state)))
      (let* ((key (car path))
             (existing (let ((e (assoc key state))) (if e (cdr e) '())))
             (updated (state-set existing (cdr path) value))
             (without-key (filter (lambda (kv) (not (equal? (car kv) key))) state)))
        (cons (cons key updated) without-key))))

(define (apply-effect state effect)
  (if (eq? (car effect) 'pointer-set)
      (state-set state (cadr effect) (caddr effect))
      (error 'taskweft-lite "unknown effect" effect)))

(define (apply-body state body)
  (if (null? body)
      state
      (apply-body (apply-effect state (car body)) (cdr body))))

;; decompose: try to reduce `task` (a bare task-name symbol - this
;; minimal core has no task arguments, matching bootstrap-domain.json's
;; own actions, which all take zero params) all the way down to
;; primitive actions, threading state through, accumulating a flat plan.
(define (decompose-task domain state task plan)
  (let* ((name task)
         (action (assoc name (cdr (assoc 'actions domain)))))
    (if action
        ;; Primitive action: apply its body's effects, append to plan.
        (let* ((body (cdr (cdr action)))
               (new-state (apply-body state body)))
          (cons (append plan (list task)) new-state))
        (let ((method (assoc name (cdr (assoc 'methods domain)))))
          (if (not method)
              (error 'taskweft-lite "no action or method for task" name)
              (decompose-alternatives domain state (cdr method) plan task))))))

(define (decompose-alternatives domain state alternatives plan original-task)
  (if (null? alternatives)
      (error 'taskweft-lite "no alternative decomposed" original-task)
      (let ((result (decompose-tasklist domain state (car alternatives) plan)))
        (if result
            result
            (decompose-alternatives domain state (cdr alternatives) plan original-task)))))

(define (decompose-tasklist domain state tasks plan)
  (if (null? tasks)
      (cons plan state)
      (let ((step (decompose-task domain state (car tasks) plan)))
        (decompose-tasklist domain (cdr step) (cdr tasks) (car step)))))

;; Each entry in todo-list is its own tasklist that decomposes down to a
;; flat list of primitive actions; that flat list becomes one group in
;; the output plan - matching plan/bootstrap-plan.json's shape, where
;; "plan": [["bridge_fanout_via_lean_core"]] is one group (one todo-list
;; entry's worth of decomposition) containing one primitive action.
(define (htn-plan domain state todo-list)
  (let loop ((todo todo-list) (plan '()) (st state))
    (if (null? todo)
        (list 'ok plan st)
        (let ((result (decompose-tasklist domain st (car todo) '())))
          (loop (cdr todo) (append plan (list (car result))) (cdr result))))))

;; --- Transcription of this repo's plan/bootstrap-domain.json ---
;; (JSON "/milestone/stack" -> path '(milestone stack); the JSON-LD
;; @context/@type header carries no planning-relevant data, so it is
;; dropped here.)

(define bootstrap-domain
  (list
   (cons 'actions
         (list
          (cons 'vendor_picoquic_stack
                (cons '() (list (list 'pointer-set '(milestone stack) "picoquic_vendored_standalone"))))
          (cons 'bridge_fanout_via_lean_core
                (cons '() (list (list 'pointer-set '(milestone stack) "picoquic_fanout_server_bridged"))))))
   (cons 'methods
         (list
          (cons 'bootstrap
                (list (list 'bridge_fanout_via_lean_core)))))))

(define bootstrap-state
  (list (cons 'milestone (list (cons 'stack "flow_toolchain_ready")))))

(define bootstrap-todo '((bootstrap)))

;; --- Self-test, run at load time: must match plan/bootstrap-plan.json ---
;; ("plan": [["bridge_fanout_via_lean_core"]], milestone.stack ends at
;; "picoquic_fanout_server_bridged")

(let ((result (htn-plan bootstrap-domain bootstrap-state bootstrap-todo)))
  (let ((plan (cadr result))
        (final-state (caddr result)))
    (display "plan: ") (display plan) (newline)
    (display "milestone.stack: ") (display (state-ref final-state '(milestone stack))) (newline)
    (if (and (equal? plan '((bridge_fanout_via_lean_core)))
             (equal? (state-ref final-state '(milestone stack)) "picoquic_fanout_server_bridged"))
        (display "SELF-TEST OK: matches plan/bootstrap-plan.json\n")
        (begin (display "SELF-TEST FAILED\n") (exit 1)))))

;; Not done here: parsing plan/bootstrap-domain.json's actual JSON-LD text
;; into this same domain shape (this file hand-transcribes it above),
;; method preconditions (bootstrap-domain.json has none to model yet -
;; every method here has exactly one alternative), and the shrubbery
;; surface syntax ADR 0006 calls for (this file is plain s7 s-expressions).
