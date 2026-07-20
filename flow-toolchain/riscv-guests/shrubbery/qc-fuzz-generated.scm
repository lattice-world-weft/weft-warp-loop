(define (qc-u32 x) (logand x #xFFFFFFFF))
(define (qc-xorshift32-next s0) (let* ((s1 (qc-u32 (logxor s0 (qc-u32 (ash s0 13))))) (s2 (qc-u32 (logxor s1 (ash s1 -17)))) (s3 (qc-u32 (logxor s2 (qc-u32 (ash s2 5)))))) s3))
(define (qc-search-loop pred bound remaining state) (cond ((= remaining 0) #f) (else (let* ((state2 (qc-xorshift32-next state)) (w (modulo state2 bound))) (cond ((pred w) w) (else (qc-search-loop pred bound (- remaining 1) state2)))))))
(define (qc-certify candidate-is-witness bound num-inst seed) (cond ((qc-search-loop candidate-is-witness bound num-inst seed) #t) (else #f)))
