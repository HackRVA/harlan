(library
  (harlan middle remove-nested-kernels)
  (export remove-nested-kernels)
  (import
    (rnrs)
    (elegant-weapons helpers)
    (elegant-weapons match))

;; This pass takes a nest of kernels and turns all but the innermost
;; one into for loops. This isn't the best way to do this, but it's
;; the easiest way to support nested kernels and will give us
;; something to build off of.

(define-match remove-nested-kernels
  ((module ,[Decl -> decl*] ...)
   `(module . ,decl*)))

(define-match Decl
  ((fn ,name ,args ,type ,[Stmt -> stmt _])
   `(fn ,name ,args ,type . ,stmt))
  ((extern . ,rest)
   `(extern . ,rest)))

(define (any? ls)
  (if (null? ls)
      #f
      (or (car ls) (any? (cdr ls)))))

(define-match Stmt
  ((let ,x (vector ,t ,n)
        (kernel (vector ,t ,n) (((,x* ,t*) (,xs* ,ts*)) ...)
          ,[Expr -> e kernel]))
   (values
     (if kernel
         (let ((i (gensym 'i)))
           `((let ,x (vector ,t ,n) (int ,n))
             (for (,i (int 0) (int ,n))
               (begin
                 ,@(map (lambda (x t xs ts)
                          `(let ,x ,t (vector-ref ,t ,xs (var int ,i))))
                     x* t* xs* ts*)
                 ,((set-kernel-return
                     (lambda (e) `(vector-set! ,t (var (vector ,t ,n) ,x) (var int ,i) ,e)))
                   e)
                 ))))
         `((let ,x (vector ,t ,n)
                (kernel (vector ,t ,n) (((,x* ,t*) (,xs* ,ts*)) ...) ,e))))
     #t))
  ((let ,x ,t ,e) (values `((let ,x ,t ,e)) #f))
  ((begin ,[stmt* has-kernel*] ...)
   (values `(,(make-begin (apply append stmt*))) (any? has-kernel*)))
  ((for (,i ,start ,end) ,[stmt has-kernel])
   (values `((for (,i ,start ,end) ,(make-begin stmt))) has-kernel))
  ((while ,t ,[stmt has-kernel])
   (values `((while ,t ,(make-begin stmt))) has-kernel))
  ((if ,test ,[conseq chas-kernel])
   (values `((if ,test ,(make-begin conseq))) chas-kernel))
  ((if ,test ,[conseq chas-kernel] ,[alt ahas-kernel])
   (values `((if ,test ,(make-begin conseq) ,(make-begin alt)))
     (or chas-kernel ahas-kernel)))
  ((set! ,lhs ,rhs)
   (values `((set! ,lhs ,rhs)) #f))
  ((vector-set! ,t ,v ,i ,e)
   (values `((vector-set! ,t ,v ,i ,e)) #f))
  ((do . ,e) (values `((do . ,e)) #f))
  ((print ,e) (values `((print ,e)) #f))
  ((assert ,e) (values `((assert ,e)) #f))
  ((return ,e) (values `((return ,e)) #f)))

(define-match Expr
  ((begin ,[Stmt -> stmt* kernel*] ... ,[e has-kernel])
   (values `(begin ,@(apply append stmt*) ,e)
     (or has-kernel (any? kernel*))))
  (,else (values else #f)))

(define-match (set-kernel-return finish)
  ((begin ,stmt* ... ,[(set-kernel-return finish) -> expr])
   `(begin ,@stmt* ,expr))
  (,else (finish else)))

;;end library
)
