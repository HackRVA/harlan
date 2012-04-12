(library
  (harlan middle uglify-vectors)
  (export uglify-vectors)
  (import (rnrs) (elegant-weapons helpers)
    (harlan helpers))

(define-match uglify-vectors
  ((module ,[uglify-decl -> fn*] ...)
   `(module
      (global g_region (ptr region)
        (call
         (c-expr ((int) -> (ptr region))
           create_region)
         ;; 16MB
         (int 16777216))) . ,fn*)))

(define-match uglify-decl
  ((fn ,name ,args ,t ,[uglify-stmt -> stmt])
   `(fn ,name ,args ,t ,stmt))
  ((extern ,name ,args -> ,t)
   `(extern ,name ,args -> ,t)))

(define-match extract-expr-type
  ((int ,n) 'int)
  ((var ,t ,x) t))

(define uglify-let-vec
  (lambda (t e n)
    (match e
      ((int ,y)
       (let-values (((dim t^ sz)
                     (decode-vector-type `(vec ,t ,n))))
         `(call
           (c-expr (((ptr region) int) -> (vec ,t ,n))
            alloc_in_region)
           (var (ptr region) g_region) ,sz)))
      ((var int ,y)
       (let-values (((dim t sz)
                     (decode-vector-type `(vec ,t ,y))))
         `(call
           (c-expr (((ptr region) int) -> region_ptr)
            alloc_in_region)
           (var (ptr region) g_region) ,sz)))
      ((var ,tv ,y)
       ;; TODO: this probably needs a copy instead.
       `(var ,tv ,y))
      ;; Otherwise, just hope it works! We should use more type
      ;; information here.
      (,else else))))

(define-match (uglify-let finish)
  (() finish)
  (((,x ,xt (make-vector ,t (int ,n))) .
    ,[(uglify-let finish) -> rest])
   (let ((vv (uglify-let-vec t `(int ,n) n)))
     `(let ((,x ,xt ,vv)) ,rest)))
  (((,x ,t ,[uglify-expr -> e])
    . ,[(uglify-let finish) -> rest])
   `(let ((,x ,t ,e)) ,rest)))

(define-match uglify-stmt
  ((let ((,x ,xt ,e) ...) ,[stmt])
   ((uglify-let stmt) `((,x ,xt ,e) ...)))
  ((begin ,[uglify-stmt -> stmt*] ...)
   (make-begin stmt*))
  ((if ,[uglify-expr -> test] ,conseq)
   `(if ,test ,conseq))
  ((if ,[uglify-expr -> test] ,conseq ,alt)
   `(if ,test ,conseq ,alt))
  ((while ,[uglify-expr -> e] ,[uglify-stmt -> stmt])
   `(while ,e ,stmt))
  ((for (,i ,[uglify-expr -> start] ,[uglify-expr -> end])
     ,[uglify-stmt -> stmt])
   `(for (,i ,start ,end) ,stmt))
  ((set! ,[uglify-expr -> lhs] ,[uglify-expr -> rhs])
   `(set! ,lhs ,rhs))
  ((return) `(return))
  ((return ,[uglify-expr -> e])
   `(return ,e))
  ((assert ,[uglify-expr -> e])
   `(assert ,e))
  ((vector-set! ,t ,[uglify-expr -> x] ,[uglify-expr -> i]
     ,[uglify-expr -> v])
   (uglify-vector-set! t x i v))
  ((print ,[uglify-expr -> e])
   `(print ,e))
  ((kernel ,t ,dims ,iters ,[stmt])
   `(kernel ,dims ,iters ,stmt))
  ((do ,[uglify-expr -> e])
   `(do ,e)))

(define uglify-vector-set!
  (lambda (t x i v)
    `(set! ,(uglify-vector-ref t x i) ,v)))

(define-match expr-type
  ((var ,t ,x) t)
  ((vector-ref ,t ,v ,i) t))

(define-match uglify-expr
  ((,t ,n) (guard (scalar-type? t)) `(,t ,n))
  ((var ,tx ,x) `(var ,tx ,x))
  ((int->float ,[e]) `(cast float ,e))
  ((call ,[name] ,[args] ...)
   `(call ,name . ,args))
  ((c-expr ,t ,name)
   `(c-expr ,t ,name))
  ((if ,[test] ,[conseq] ,[alt])
   `(if ,test ,conseq ,alt))
  ((,op ,[lhs] ,[rhs])
   (guard (or (binop? op) (relop? op)))
   `(,op ,lhs ,rhs))
  ((vector-ref ,t ,[e] ,[i])
   (uglify-vector-ref t e i))
  ((length ,e)
   (match (expr-type e)
     ((vec ,n ,t)
      `(int ,n))
     (,else
      (error 'uglify-expr "Took length of non-vector"
        else (expr-type e)))))
  ((addressof ,[expr])
   `(addressof ,expr))
  ((deref ,[expr])
   `(deref ,expr)))

(define uglify-vector-ref
  (lambda (t e i)
    `(vector-ref
      ,t
      (cast (ptr ,t)
       (call
        (c-expr (((ptr region) region_ptr) -> (ptr void))
         get_region_ptr) (var (ptr region) g_region) ,e))
      ,i)))

)
