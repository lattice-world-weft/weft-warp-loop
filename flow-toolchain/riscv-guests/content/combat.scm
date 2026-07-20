; SPDX-License-Identifier: MIT
; Copyright (c) 2026 K. S. Ernest (iFire) Lee
;
; Hand-ported from v-sekai-multiplayer-fabric/combat's
; core/CombatCore/Core.lean (fetched via gh api, translated
; line-for-line) - the combo/invulnerability/damage reducer.
;
; State is a Lean structure (6 UInt32/Bool fields); ported as a 6-slot
; vector with named accessors rather than an assoc-list, so field
; access is O(1) and typo'd field names fail loudly (vector-ref out of
; range) rather than silently returning #f. Every `{ s with f := v }`
; site becomes an explicit make-state call listing all six fields
; (unchanged ones via the accessor, changed ones with the new value) -
; verbose, but each site is directly checkable against its Lean source
; line rather than trusting a generic field-updater helper.
;
; (State x List Effect) pairs are represented as 2-element lists
; (list new-state effects), accessed via car/cadr.

(define combo-min-gap 6)
(define combo-max-gap 18)
(define invuln-ticks 30)
(define enemy-max-hp 100)

(define (damage-of stage)
  (cond ((= stage 0) 10)
        ((= stage 1) 15)
        (else 25)))

(define (make-state tick combo last-attack hp spawn alive)
  (vector tick combo last-attack hp spawn alive))
(define (st-tick s) (vector-ref s 0))
(define (st-combo s) (vector-ref s 1))
(define (st-last-attack s) (vector-ref s 2))
(define (st-hp s) (vector-ref s 3))
(define (st-spawn s) (vector-ref s 4))
(define (st-alive s) (vector-ref s 5))

(define initial-state (make-state 0 0 0 0 0 #f))

; CombatCore.resolveSwing
(define (resolve-swing s stage)
  (cond
    ((not (st-alive s))
     (list s (list (list 'swing stage))))
    ((< (st-tick s) (+ (st-spawn s) invuln-ticks))
     (list s (list (list 'swing stage) 'blocked)))
    (else
     (let ((dmg (damage-of stage)))
       (if (<= (st-hp s) dmg)
           (list (make-state (st-tick s) (st-combo s) (st-last-attack s) 0 (st-spawn s) #f)
                 (list (list 'swing stage) (list 'hit dmg) 'death))
           (list (make-state (st-tick s) (st-combo s) (st-last-attack s) (- (st-hp s) dmg) (st-spawn s) (st-alive s))
                 (list (list 'swing stage) (list 'hit dmg))))))))

; CombatCore.step
(define (combat-step s event)
  (cond
    ((eq? event 'tick)
     (let ((s1 (make-state (+ (st-tick s) 1) (st-combo s) (st-last-attack s) (st-hp s) (st-spawn s) (st-alive s))))
       (if (and (> (st-combo s1) 0) (> (st-tick s1) (+ (st-last-attack s1) combo-max-gap)))
           (list (make-state (st-tick s1) 0 (st-last-attack s1) (st-hp s1) (st-spawn s1) (st-alive s1)) (list 'comboDrop))
           (list s1 '()))))
    ((eq? event 'spawn)
     (list (make-state (st-tick s) (st-combo s) (st-last-attack s) enemy-max-hp (st-tick s) #t) '()))
    ((eq? event 'attack)
     (if (= (st-combo s) 0)
         (resolve-swing (make-state (st-tick s) 1 (st-tick s) (st-hp s) (st-spawn s) (st-alive s)) 0)
         (let ((gap (- (st-tick s) (st-last-attack s))))
           (if (and (<= combo-min-gap gap) (<= gap combo-max-gap))
               (let* ((stage (st-combo s))
                      (next (if (>= stage 2) 0 (+ stage 1))))
                 (resolve-swing (make-state (st-tick s) next (st-tick s) (st-hp s) (st-spawn s) (st-alive s)) stage))
               (list (make-state (st-tick s) 0 (st-last-attack s) (st-hp s) (st-spawn s) (st-alive s)) (list 'whiff))))))
    (else (list s '()))))

; CombatCore.replay
(define (combat-replay events)
  (let loop ((evs events) (acc (list initial-state '())))
    (if (null? evs)
        acc
        (let* ((r (combat-step (car acc) (car evs))))
          (loop (cdr evs) (list (car r) (append (cadr acc) (cadr r))))))))
