(define-record plan-solution-tree complete-tree failure-node recovery-point verified)
(define (mark-verified st node-id) (record-with make-plan-solution-tree '(complete-tree failure-node recovery-point verified) st (verified (append (plan-solution-tree-verified st) (list node-id)))))
(define (replan st new-tree) (record-with make-plan-solution-tree '(complete-tree failure-node recovery-point verified) st (complete-tree new-tree) (failure-node #f)))
