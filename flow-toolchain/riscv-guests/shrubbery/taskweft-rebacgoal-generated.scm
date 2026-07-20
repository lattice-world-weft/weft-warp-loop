(define-record uni-goal subj expr obj)
(define (uni-satisfied graph fuel g) (check-relation-expr graph (uni-goal-subj g) (uni-goal-expr g) (uni-goal-obj g) fuel))
(define (list-all pred lst) (cond ((null? lst) #t) ((pred (car lst)) (list-all pred (cdr lst))) (else #f)))
(define (multi-satisfied graph fuel gs) (list-all (lambda (g) (uni-satisfied graph fuel g)) gs))
