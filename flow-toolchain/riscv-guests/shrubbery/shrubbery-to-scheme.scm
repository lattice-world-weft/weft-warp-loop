; SPDX-License-Identifier: MIT
; Copyright (c) 2026 K. S. Ernest (iFire) Lee
;
; s7 port of shrubbery_to_scheme.py (ADR 0033) - per user direction,
; the reader itself moves to s7 once proven, removing the Python
; toolchain dependency for content authoring. Same grammar, same
; explicit-subset scope, same error-over-guess discipline; a faithful
; line-for-line structural translation, not a reinterpretation -
; verified against the Python version's own output on the same real
; input (loot.shrub) for semantic equivalence, not just "it runs."
;
; Plain s7 Scheme, not shrubbery notation itself - bootstrapping a
; reader written in the notation it reads would need the reader to
; already exist. This file stays hand-written Scheme permanently.

(define (strip-comment line)
  (let ((len (string-length line)))
    (let loop ((i 0) (in-str #f) (out '()))
      (if (>= i len)
          (list->string (reverse out))
          (let ((c (string-ref line i)))
            (cond
              ((char=? c #\") (loop (+ i 1) (not in-str) (cons c out)))
              (in-str (loop (+ i 1) in-str (cons c out)))
              ((and (char=? c #\/) (< (+ i 1) len) (char=? (string-ref line (+ i 1)) #\/))
               (list->string (reverse out)))
              (else (loop (+ i 1) in-str (cons c out)))))))))

(define (rstrip s)
  (let loop ((i (- (string-length s) 1)))
    (if (and (>= i 0) (or (char=? (string-ref s i) #\space) (char=? (string-ref s i) #\tab)))
        (loop (- i 1))
        (substring s 0 (+ i 1)))))

(define (leading-space-count s)
  (let ((len (string-length s)))
    (let loop ((i 0))
      (if (and (< i len) (char=? (string-ref s i) #\space))
          (loop (+ i 1))
          i))))

(define (strip s)
  (let* ((n (leading-space-count s)))
    (rstrip (substring s n (string-length s)))))

(define (split-lines text)
  (let ((port (open-input-string text)))
    (let loop ((acc '()))
      (let ((line (read-line port #f)))
        (if (eof-object? line)
            (reverse acc)
            (loop (cons line acc)))))))

; -> list of (indent . content) for non-blank, comment-stripped lines
(define (parse-shrub-lines text)
  (let loop ((lines (split-lines text)) (acc '()))
    (if (null? lines)
        (reverse acc)
        (let* ((line (rstrip (strip-comment (car lines))))
               (trimmed (strip line)))
          (if (string=? trimmed "")
              (loop (cdr lines) acc)
              (loop (cdr lines) (cons (cons (leading-space-count line) trimmed) acc)))))))

; -> (siblings . next-index); siblings = list of (header child-or-#f)
(define (build-block-tree lines start min-indent)
  (if (>= start (length lines))
      (cons '() start)
      (let ((indent (car (list-ref lines start))))
        (if (< indent min-indent)
            (cons '() start)
            (let loop ((i start) (siblings '()))
              (if (and (< i (length lines)) (= (car (list-ref lines i)) indent))
                  (let* ((header (cdr (list-ref lines i)))
                         (next-i (+ i 1))
                         (has-child (and (< next-i (length lines)) (> (car (list-ref lines next-i)) indent))))
                    (if has-child
                        (let* ((sub (build-block-tree lines next-i (+ indent 1))))
                          (loop (cdr sub) (cons (list header (car sub)) siblings)))
                        (loop next-i (cons (list header #f) siblings))))
                  (cons (reverse siblings) i)))))))

(define (split-args s)
  (let ((len (string-length s)))
    (let loop ((i 0) (depth 0) (in-str #f) (cur '()) (args '()))
      (if (>= i len)
          (let ((last (strip (list->string (reverse cur)))))
            (reverse (if (string=? last "") args (cons last args))))
          (let ((c (string-ref s i)))
            (cond
              ((char=? c #\") (loop (+ i 1) depth (not in-str) (cons c cur) args))
              (in-str (loop (+ i 1) depth in-str (cons c cur) args))
              ((or (char=? c #\() (char=? c #\[)) (loop (+ i 1) (+ depth 1) in-str (cons c cur) args))
              ((or (char=? c #\)) (char=? c #\])) (loop (+ i 1) (- depth 1) in-str (cons c cur) args))
              ((and (char=? c #\,) (= depth 0))
               (loop (+ i 1) depth in-str '() (cons (strip (list->string (reverse cur))) args)))
              (else (loop (+ i 1) depth in-str (cons c cur) args))))))))

; -> (before . after) split at the first depth-0 ':', or (s . #f) if none
(define (split-first-colon-at-depth-0 s)
  (let ((len (string-length s)))
    (let loop ((i 0) (depth 0) (in-str #f))
      (if (>= i len)
          (cons s #f)
          (let ((c (string-ref s i)))
            (cond
              ((char=? c #\") (loop (+ i 1) depth (not in-str)))
              (in-str (loop (+ i 1) depth in-str))
              ((or (char=? c #\() (char=? c #\[)) (loop (+ i 1) (+ depth 1) in-str))
              ((or (char=? c #\)) (char=? c #\])) (loop (+ i 1) (- depth 1) in-str))
              ((and (char=? c #\:) (= depth 0))
               (cons (substring s 0 i) (substring s (+ i 1) len)))
              (else (loop (+ i 1) depth in-str))))))))

(define (id-start-char? c)
  (or (char-alphabetic? c) (memv c (list #\+ #\- #\* #\/ #\< #\> #\= #\! #\? #\_))))

; -> (name args) or #f if not call syntax
(define (parse-call text0)
  (let* ((text (strip text0)) (len (string-length text)))
    (if (or (= len 0) (char=? (string-ref text 0) #\") (char=? (string-ref text 0) #\'))
        #f
        (let loop ((i 0) (depth 0))
          (if (>= i len)
              #f
              (let ((c (string-ref text i)))
                (cond
                  ((and (char=? c #\() (= depth 0))
                   (if (not (char=? (string-ref text (- len 1)) #\)))
                       #f
                       (let ((name (strip (substring text 0 i))))
                         (if (or (string=? name "") (not (id-start-char? (string-ref name 0))))
                             #f
                             (list name (split-args (substring text (+ i 1) (- len 1))))))))
                  ((or (char=? c #\() (char=? c #\[)) (loop (+ i 1) (+ depth 1)))
                  ((or (char=? c #\)) (char=? c #\])) (loop (+ i 1) (- depth 1)))
                  ((or (char=? c #\space) (char=? c #\tab)) #f)
                  (else (loop (+ i 1) depth)))))))))

(define (term->sexpr text0)
  (let* ((text (strip text0)) (call (parse-call text)))
    (if (not call)
        text
        (let* ((name (car call)) (args (cadr call)) (parts (map term->sexpr args)))
          (string-append "(" (apply string-append name (map (lambda (p) (string-append " " p)) parts)) ")")))))

(define (join-space parts)
  (if (null? parts) "" (apply string-append (car parts) (map (lambda (p) (string-append " " p)) (cdr parts)))))

(define (parse-binding-list inner)
  (map (lambda (part)
         (let ((sp (split-first-colon-at-depth-0 part)))
           (if (not (cdr sp))
               (error 'shrubbery-error (string-append "expected 'name: value' in binding list, got: " part))
               (list (strip (car sp)) (term->sexpr (strip (cdr sp)))))))
       (split-args inner)))

(define (block->body block)
  (map (lambda (entry) (line->sexpr (car entry) (cadr entry))) block))

(define block-keyword-prefixes (list "define " "let " "let(" "let*(" "cond"))

(define (starts-with? s prefix)
  (and (>= (string-length s) (string-length prefix))
       (string=? (substring s 0 (string-length prefix)) prefix)))

(define (looks-like-block-keyword? s)
  (or (string=? s "cond")
      (let loop ((ps block-keyword-prefixes))
        (and (pair? ps) (or (starts-with? s (car ps)) (loop (cdr ps)))))))

(define (line->sexpr header child)
  (if (char=? (string-ref header (- (string-length header) 1)) #\:)
      (block-header->sexpr (strip (substring header 0 (- (string-length header) 1))) child)
      (if child
          (error 'shrubbery-error (string-append "line has an indented block but no trailing ':': " header))
          (if (looks-like-block-keyword? header)
              (error 'shrubbery-error
                (string-append "line looks like a block header but has no trailing ':' "
                  "(inline single-line bodies are not supported): " header))
              (term->sexpr header)))))

(define (block-header->sexpr header child)
  (if (not child)
      (error 'shrubbery-error (string-append "block header with no indented body: " header ":"))
      (cond
        ((starts-with? header "define ")
         (let* ((call (parse-call (substring header 7 (string-length header)))))
           (if (not call)
               (error 'shrubbery-error (string-append "expected 'define name(params):', got: " header))
               (string-append "(define (" (car call) " " (join-space (cadr call)) ") "
                              (join-space (block->body child)) ")"))))
        ; Two structurally different cases, matching shrubbery_to_scheme.py's
        ; own two separate branches exactly - do not merge them (a prior
        ; version of this port did, and broke the plain let*(...) case:
        ; parse-call needs "name(args)" shape, and for the plain-let case
        ; the header's own "let"/"let*" prefix IS the name parse-call
        ; extracts - stripping it first before calling parse-call, as the
        ; named-let branch correctly does, leaves nothing for parse-call
        ; to recognize as a name).
        ((starts-with? header "let ")
         ; let name(p: v, ...):  - named let (loop)
         (let* ((rest (strip (substring header 4 (string-length header))))
                (call (parse-call rest)))
           (if (not call)
               (error 'shrubbery-error (string-append "expected 'let name(p: v, ...):', got: " header))
               (let* ((name (car call))
                      (bindings (if (null? (cadr call)) '() (parse-binding-list (join-space-comma (cadr call))))))
                 (string-append "(let " name " ("
                   (join-space (map (lambda (b) (string-append "(" (car b) " " (cadr b) ")")) bindings))
                   ") " (join-space (block->body child)) ")")))))
        ((or (starts-with? header "let(") (starts-with? header "let*("))
         ; let(p: v, ...):  or  let*(p: v, ...):  - plain (unnamed) let/let*
         (let* ((is-star (starts-with? header "let*("))
                (call (parse-call header)))
           (if (not call)
               (error 'shrubbery-error (string-append "expected 'let(...)' binding list, got: " header))
               (let* ((bindings (if (null? (cadr call)) '() (parse-binding-list (join-space-comma (cadr call))))))
                 (string-append "(" (if is-star "let*" "let") " ("
                   (join-space (map (lambda (b) (string-append "(" (car b) " " (cadr b) ")")) bindings))
                   ") " (join-space (block->body child)) ")")))))
        ((string=? header "cond")
         (string-append "(cond "
           (join-space
             (map (lambda (entry)
                    (let* ((line (car entry)) (sub (cadr entry)))
                      (if (not (char=? (string-ref line 0) #\|))
                          (error 'shrubbery-error (string-append "expected '| test: result' inside cond:, got: " line))
                          (let* ((clause (strip (substring line 1 (string-length line))))
                                 (sp (split-first-colon-at-depth-0 clause)))
                            (if (not (cdr sp))
                                (error 'shrubbery-error (string-append "expected '| test: result', got: " line))
                                (let* ((test-sexpr (term->sexpr (strip (car sp))))
                                       (result-body (line->sexpr (strip (cdr sp)) sub)))
                                  (string-append "(" test-sexpr " " result-body ")")))))))
                  child))
           ")"))
        (else (error 'shrubbery-error
                (string-append "unsupported block header (only 'define name(...):', 'let ...:', "
                  "and 'cond:' open a block): " header ":"))))))

; parse-binding-list expects one comma-joined string (matching the Python
; port's own '","-joined args before re-splitting) - args here are
; already split by parse-call's own split-args, so rejoin with ", ".
(define (join-space-comma parts)
  (if (null? parts) "" (apply string-append (car parts) (map (lambda (p) (string-append ", " p)) (cdr parts)))))

; Matches shrubbery_to_scheme.py's check_no_avoidable_raw_toplevel exactly
; (see that function's comment for why this is scoped to the top level
; only, not every raw-parens use anywhere in a file).
(define (check-no-avoidable-raw-toplevel header child)
  (if (and (not child) (> (string-length (strip header)) 0)
           (char=? (string-ref (strip header) 0) #\())
      (error 'shrubbery-error
        (string-append "raw parenthesized top-level statement not allowed - shrubbery "
          "source should read like a normal language, not Lisp: rewrite " (strip header)
          " as call syntax, e.g. 'name(a, b, c)' instead of '(name a b c)'"))
      #t))

(define (shrubbery->scheme text)
  (let* ((lines (parse-shrub-lines text))
         (tree-result (build-block-tree lines 0 0))
         (tree (car tree-result))
         (end (cdr tree-result)))
    (if (not (= end (length lines)))
        (error 'shrubbery-error "unexpected indentation")
        (begin
          (for-each (lambda (entry) (check-no-avoidable-raw-toplevel (car entry) (cadr entry))) tree)
          (join-newline (map (lambda (entry) (line->sexpr (car entry) (cadr entry))) tree))))))

(define (join-newline parts)
  (if (null? parts) "" (apply string-append (car parts) (map (lambda (p) (string-append "\n" p)) (cdr parts)))))
