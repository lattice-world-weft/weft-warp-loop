(define (node-lifecycle-step n) (cond ((equal? (solution-node-status n) 'open) (record-with make-solution-node '(node-id content status tag shadow-state tried-methods-idx) n (status 'closed) (tag "new"))) (else n)))
(define (extract-plan-loop nodes) (cond ((null? nodes) '()) (else (let* ((n (car nodes)) (rest (extract-plan-loop (cdr nodes)))) (cond ((and (equal? (solution-node-tag n) "new") (equal? (car (solution-node-content n)) 'task)) (cons (cons 'action (cdr (solution-node-content n))) rest)) (else rest))))))
(define (extract-plan tree) (extract-plan-loop (solution-tree-nodes tree)))
