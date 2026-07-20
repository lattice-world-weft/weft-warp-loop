; SPDX-License-Identifier: MIT
; Copyright (c) 2026 K. S. Ernest (iFire) Lee
;
; Hand-ported from v-sekai-multiplayer-fabric/progression's
; core/ProgressionCore/Core.lean (translated line-for-line) - the
; inventory/affinity-gate/credit reducer.
;
; Source of truth: v-sekai-multiplayer-fabric/progression is upstream
; and authoritative. This file is a pinned, one-time translation, not
; an ongoing mirror - ADR 0032. Ported from commit
; 659d52239ba50ab313614bf3aa6233165eb89788. If that repo's Core.lean
; changes, this file is stale until re-ported by hand against the new
; commit - nothing here re-checks upstream automatically.
;
; Profile is a 4-slot vector: #(credits affinity items arts).
; items/arts are plain Scheme lists of (item . count) pairs / art ids -
; this is the real content ADR 0026 found combat/progression/loot
; leaning on (map/filter/assoc over lists), now handled for free by
; s7's interpreter instead of needing new compiler engineering.

; `filter` is not a builtin in this s7 build (verified: map/assoc/member
; all resolve fine, filter alone throws "unbound variable") - defined
; locally rather than assuming a library load path exists for it.
(define (filter pred lst)
  (cond ((null? lst) '())
        ((pred (car lst)) (cons (car lst) (filter pred (cdr lst))))
        (else (filter pred (cdr lst)))))

(define (make-profile credits affinity items arts) (vector credits affinity items arts))
(define (pr-credits p) (vector-ref p 0))
(define (pr-affinity p) (vector-ref p 1))
(define (pr-items p) (vector-ref p 2))
(define (pr-arts p) (vector-ref p 3))

(define initial-profile (make-profile 200 15 '() '()))

(define (art-cost a) (cond ((= a 1) 100) ((= a 2) 250) (else 500)))
(define (art-affinity-req a) (cond ((= a 1) 10) ((= a 2) 25) (else 40)))

; ProgressionCore.countOf
(define (count-of p item)
  (let ((e (assoc item (pr-items p))))
    (if e (cdr e) 0)))

; ProgressionCore.addItem
(define (add-item p item d)
  (if (assoc item (pr-items p))
      (make-profile (pr-credits p) (pr-affinity p)
                     (map (lambda (e) (if (= (car e) item) (cons (car e) (+ (cdr e) d)) e)) (pr-items p))
                     (pr-arts p))
      (make-profile (pr-credits p) (pr-affinity p)
                     (append (pr-items p) (list (cons item d)))
                     (pr-arts p))))

; ProgressionCore.removeItem
(define (remove-item p item)
  (make-profile (pr-credits p) (pr-affinity p)
                (filter (lambda (e) (> (cdr e) 0))
                        (map (lambda (e) (if (= (car e) item) (cons (car e) (- (cdr e) 1)) e)) (pr-items p)))
                (pr-arts p)))

; ProgressionCore.step - events are (list 'grant item), (list 'sell item price),
; (list 'buyArt art), or the bare symbol 'train.
(define (progression-step p event)
  (cond
    ((and (pair? event) (eq? (car event) 'grant))
     (list (add-item p (cadr event) 1) (list (list 'granted (cadr event)))))
    ((and (pair? event) (eq? (car event) 'sell))
     (let ((item (cadr event)) (price (caddr event)))
       (if (= (count-of p item) 0)
           (list p (list (list 'refusedNoItem item)))
           (list (remove-item (make-profile (+ (pr-credits p) price) (pr-affinity p) (pr-items p) (pr-arts p)) item)
                 (list (list 'sold item price))))))
    ((and (pair? event) (eq? (car event) 'buyArt))
     (let ((art (cadr event)))
       (cond
         ((member art (pr-arts p)) (list p (list (list 'refusedDup art))))
         ((< (pr-affinity p) (art-affinity-req art)) (list p (list (list 'refusedGate art))))
         ((< (pr-credits p) (art-cost art)) (list p (list (list 'refusedPoor art))))
         (else (list (make-profile (- (pr-credits p) (art-cost art)) (pr-affinity p) (pr-items p) (append (pr-arts p) (list art)))
                     (list (list 'learned art)))))))
    ((eq? event 'train)
     (let ((a (+ (pr-affinity p) 1)))
       (list (make-profile (pr-credits p) a (pr-items p) (pr-arts p)) (list (list 'trained a)))))
    (else (list p '()))))

; ProgressionCore.replay
(define (progression-replay events)
  (let loop ((evs events) (acc (list initial-profile '())))
    (if (null? evs)
        acc
        (let ((r (progression-step (car acc) (car evs))))
          (loop (cdr evs) (list (car r) (append (cadr acc) (cadr r))))))))
