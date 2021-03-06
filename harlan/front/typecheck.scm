(library
  (harlan front typecheck)
  (export typecheck free-regions-type)
  (import
    (rnrs)
    (only (chezscheme) make-parameter parameterize
          pretty-print printf trace-define trace-let trace)
    (elegant-weapons match)
    (elegant-weapons helpers)
    (elegant-weapons sets)
    (harlan compile-opts)
    (util color))

  (define (typecheck m)
    (let-values (((m s) (infer-module m)))
      (ground-module `(module . ,m) s)))

  (define-record-type tvar (fields name))
  (define-record-type rvar (fields name))

  (define (gen-tvar x) (make-tvar (gensym x)))
  (define (gen-rvar x) (make-rvar (gensym x)))
  
  (define type-tag (gensym 'type))
  
  ;; Walks type and region variables in a substitution
  (define (walk x s)
    (let ((x^ (assq x s)))
      ;; TODO: We will probably need to check for cycles.
      (if x^
          (let ((x^ (cdr x^)))
            (cond 
              ((or (tvar? x^) (rvar? x^))
               (walk x^ s))
              ((eq? x^ 'Numeric)
               x)
              (else x^)))
          x)))
              
  (define (walk-type t s)
    (match t
      (,t (guard (symbol? t)) t)
      ((vec ,r ,[t]) `(vec ,(walk r s) ,t))
      ((ptr ,[t]) `(ptr ,t))
      ((adt ,[t]) `(adt ,t))
      ((adt ,[t] ,r) `(adt ,t ,(walk r s)))
      ((closure ,r (,[t*] ...) -> ,[t])
       `(closure ,(walk r s) ,t* -> ,t))
      ((fn (,[t*] ...) -> ,[t]) `(fn (,t* ...) -> ,t))
      (,x (guard (or (tvar? x) (rvar? x)))
          (let ((x^ (walk x s)))
            (if (equal? x x^)
                x
                (walk-type x^ s))))
      (,else (error 'walk-type "Unknown type" else))))
  
  ;; Unifies types a and b. s is an a-list containing substitutions
  ;; for both type and region variables. If the unification is
  ;; successful, this function returns a new substitution. Otherwise,
  ;; this functions returns #f.
  (define (unify-types a b s)
    (define (maybe-subst a b s)
      (let ((t (or (tvar? a) (rvar? a))))
        (if t
            (and s `((,a . ,b) . ,s))
            (error 'maybe-subst
                   "You don't want to put this in the substitution."
                   a b))))
    (let ((s
           (match `(,(walk-type a s) ,(walk-type b s))
             ;; Obviously equal types unify.
             ((,a ,b) (guard (equal? a b)) s)
      
             ((int Numeric)
              (if (tvar? b)
                  (maybe-subst b 'int s)
                  s))
             ((float Numeric)
              (if (tvar? b)
                  (maybe-subst b 'float s)
                  s))
             ((u64 Numeric)
              (if (tvar? b)
                  (maybe-subst b 'u64 s)
                  s))
             ;;((Numeric float) (guard (tvar? a)) `((,a . float) . ,s))

             ((,a ,b) (guard (tvar? a)) (maybe-subst a b s))
             ((,a ,b) (guard (tvar? b)) (maybe-subst b a s))
             ((,a ,b) (guard (and (rvar? a) (rvar? b))) (maybe-subst a b s))
             (((vec ,ra ,a) (vec ,rb ,b))
              (let ((s (unify-types a b s)))
                (if (eq? ra rb)
                    s
                    (maybe-subst ra rb s))))

             (((ptr ,a) (ptr ,b))
              (unify-types a b s))
             
             (((adt ,ta ,ra) (adt ,tb ,rb))
              (let ((s (unify-types ta tb s)))
                (if (eq? ra rb)
                           s
                           (maybe-subst ra rb s))))
             (((closure ,r1 ,a* -> ,a)
               (closure ,r2 ,b* -> ,b))
              (let loop ((a* a*)
                         (b* b*)
                         (s s))
                (match `(,a* ,b*)
                  ((() ())
                   (let ((s (unify-types a b s)))
                     (if (eq? r1 r2)
                         s
                         (maybe-subst r1 r2 s))))
                  (((,a ,a* ...) (,b ,b* ...))
                   (let ((s (unify-types a b s)))
                     (and s (loop a* b* s))))
                  (,else #f))))
             (((fn (,a* ...) -> ,a) (fn (,b* ...) -> ,b))
              (let loop ((a* a*)
                         (b* b*)
                         (s s))
                (match `(,a* ,b*)
                  ((() ()) (unify-types a b s))
                  (((,a ,a* ...) (,b ,b* ...))
                   (let ((s (unify-types a b s)))
                     (and s (loop a* b* s))))
                  (,else #f))))
             (,else #f))))
      (if s
          (if (not (andmap (lambda (s)
                             (or (tvar? (car s)) (rvar? (car s))))
                           s))
              (begin
                (pretty-print s)
                (error 'unify-types "invalid substitution created"
                       a b s
                       (walk-type a s)
                       (walk-type b s)))))
      s))

  (define (type-error e expected found)
    (display "In expression...\n")
    (pretty-print e)
    (display "Expected type...\n")
    (pretty-print expected)
    (display "But found...\n")
    (pretty-print found)
    (error 'typecheck
           "Could not unify types"))

  (define (return e t)
    (lambda (_ r s)
      (values e t s)))

  (define (bind m seq)
    (lambda (e^ r s)
      (let-values (((e t s) (m e^ r s)))
        ((seq e t) e^ r s))))

  (define (unify a b seq)
    (lambda (e r s)
      (let ((s^ (unify-types a b s)))
        ;;(printf "Unifying ~a and ~a => ~a\n" a b s)
        (if s^
            ((seq) e r s^)
            (type-error e (walk-type a s) (walk-type b s))))))

  (define (== a b)
    (unify a b (lambda () (return #f a))))
    
  (define (require-type e env t)
    (let ((tv (make-tvar (gensym 'tv))))
      (do* (((e t^) (infer-expr e env))
            ((_ __)  (== tv t))
            ((_ __)  (== tv t^)))
           (return e tv))))

  (define (unify-return-type t seq)
    (lambda (e r s)
      ((unify r t seq) e r s)))

  (define-syntax with-current-expr
    (syntax-rules ()
      ((_ e b)
       (lambda (e^ r s)
         (b e r s)))))
  
  ;; you can use this with bind too!
  (define (infer-expr* e* env)
    (if (null? e*)
        (return '() '())
        (let ((e (car e*))
              (e* (cdr e*)))
          (bind
           (infer-expr* e* env)
           (lambda (e* t*)
             (bind (infer-expr e env)
                   (lambda (e t)
                     (return `(,e . ,e*)
                             `(,t . ,t*)))))))))

  (define (require-all e* env t)
    (if (null? e*)
        (return '() t)
        (let ((e (car e*))
              (e* (cdr e*)))
          (do* (((e* t) (require-all e* env t))
                ((e  t) (require-type e env t)))
               (return `(,e . ,e*) t)))))

  ;; Here env is just a list of formal parameters and internally bound
  ;; variables.
  (define (free-var-types e env)
    (match e
      ((num ,i) '())
      ((float ,f) '())
      ((var ,t ,x)
       (if (memq x env)
           '()
           (list (cons x t))))
      ((lambda ,t ((,x* ,t*) ...) ,b)
       (free-var-types b (append x* env)))
      ((let ((,x* ,t* ,[e*]) ...) ,b)
       (apply append (free-var-types b (append x* env)) e*))
      ((if ,[t] ,[c] ,[a]) (append t c a))
      ((vector-ref ,t ,[x] ,[i])
       (append x i))
      ((match ,t ,[e]
         ((,tag ,x ...) ,b) ...)
       (apply append e
              (map (lambda (x b) (free-var-types b (append x env))) x b)))
      ((call ,[e*] ...)
       (apply append e*))
      ((invoke ,[e*] ...)
       (apply append e*))
      ((,op ,t ,[a] ,[b])
       (guard (or (binop? op) (relop? op)))
       (append a b))
      (,else (error 'free-var-types
                    "Unexpected expression" else))))
  
  (define-syntax do*
    (syntax-rules ()
      ((_ (((x ...) e) ((x* ...) e*) ...) b)
       (bind e (lambda (x ...)
                 (do* (((x* ...) e*) ...) b))))
      ((_ () b) b)))

  (define (unify-regions* r r*)
    (if (null? r*)
        (return '() '())
        (do* (((a b) (unify-regions* r (cdr r*)))
              ((a b) (== r (car r*))))
             (return a b))))

  (define (infer-expr e env)
    ;(display `(,e :: ,env)) (newline)
    (with-current-expr
     e
     (match e
       ((int ,n)
        (return `(int ,n) 'int))
       ((float ,f)
        (return `(float ,f) 'float))
       ((num ,n)
        (let ((t (make-tvar (gensym 'num))))
          (do* (((_ t) (== t 'Numeric)))
               (return `(num ,n) t))))
       ((char ,c) (return `(char ,c) 'char))
       ((bool ,b)
        (return `(bool ,b) 'bool))
       ((str ,s)
        (return `(str ,s) 'str))
       ((var ,x)
        (let ((t (lookup x env)))
          (return `(var ,t ,x) t)))
       ((int->float ,e)
        (do* (((e _) (require-type e env 'int)))
             (return `(int->float ,e) 'float)))
       ((float->int ,e)
        (do* (((e _) (require-type e env 'float)))
             (return `(float->int ,e) 'int)))
       ((return)
        (unify-return-type
         'void
         ;; Returning a free type variable is better so we can return
         ;; from any context, but that gives us problems with free
         ;; type variables at the end.
         (lambda () (return `(return) 'void))))
       ((return ,e)
        (bind (infer-expr e env)
              (lambda (e t)
                (unify-return-type
                 t
                 (lambda ()
                   (return `(return ,e) t))))))
       ((print ,e)
        (do* (((e t) (infer-expr e env)))
             (return `(print ,t ,e) 'void)))
       ((print ,e ,f)
        (do* (((e t) (infer-expr e env))
              ((f _) (require-type f env '(ptr ofstream))))
             (return `(print ,t ,e ,f) 'void)))
       ((println ,e)
        (do* (((e t) (infer-expr e env)))
             (return `(println ,t ,e) 'void)))
       ((iota ,e)
        (do* (((e t) (require-type e env 'int)))
             (let ((r (make-rvar (gensym 'r))))
               (return `(iota-r ,r ,e)
                       `(vec ,r int)))))
       ((iota-r ,r ,e)
        (do* (((e t) (require-type e env 'int)))
             (return `(iota-r ,r ,e)
                     `(vec ,r int))))
       ((vector ,e* ...)
        (let ((t (make-tvar (gensym 'tvec)))
              (r (make-rvar (gensym 'rv))))
          (do* (((e* t) (require-all e* env t)))
               (return `(vector (vec ,r ,t) ,e* ...) `(vec ,r ,t)))))
       ((vector-r ,r ,e* ...)
        (let ((t (make-tvar (gensym 'tvec))))
          (do* (((e* t) (require-all e* env t)))
               (return `(vector (vec ,r ,t) ,e* ...) `(vec ,r ,t)))))
       ((make-vector ,len ,val)
        (do* (((len _) (require-type len env 'int))
              ((val t) (infer-expr val env)))
             (let ((t `(vec ,(make-rvar (gensym 'rmake-vector)) ,t)))
               (return `(make-vector ,t ,len ,val) t))))
       ((length ,v)
        (let ((t (make-tvar (gensym 'tveclength)))
              (r (make-rvar (gensym 'rvl))))
          (do* (((v _) (require-type v env `(vec ,r ,t))))
               (return `(length ,v) 'int))))
       ((vector-ref ,v ,i)
        (let ((t (make-tvar (gensym 'tvecref)))
              (r (make-rvar (gensym 'rvref))))
          (do* (((v _) (require-type v env `(vec ,r ,t)))
                ((i _) (require-type i env 'int)))
               (return `(vector-ref ,t ,v ,i) t))))
       ((unsafe-vector-ref ,v ,i)
        (let ((t (make-tvar (gensym 'tvecref)))
              (r (make-rvar (gensym 'rvref))))
          (do* (((v _) (require-type v env `(vec ,r ,t)))
                ((i _) (require-type i env 'int)))
               (return `(unsafe-vector-ref ,t ,v ,i) t))))
       ((unsafe-vec-ptr ,v)
        (let ((t (make-tvar (gensym 'tvecref)))
              (r (make-rvar (gensym 'rvref))))
          (do* (((v _) (require-type v env `(vec ,r ,t))))
               (return `(unsafe-vec-ptr (ptr ,t) ,v) `(ptr ,t)))))
       ((,+ ,a ,b) (guard (binop? +))
        (do* (((a t) (infer-expr a env))
              ((b t) (require-type b env t))
              ((_ __) (== t 'Numeric)))
             (return `(,+ ,t ,a ,b) t)))
       ((= ,a ,b)
        (do* (((a t) (infer-expr a env))
              ((b t) (require-type b env t)))
             (return `(= ,t ,a ,b) 'bool)))
       ((,< ,a ,b)
        (guard (relop? <))
        (do* (((a t) (infer-expr a env))
              ((b t) (require-type b env t))
              ((_ __) (== t 'Numeric)))
             (return `(,< bool ,a ,b) 'bool)))
       ((assert ,e)
        (do* (((e t) (require-type e env 'bool)))
             (return `(assert ,e) t)))
       ((set! ,x ,e)
        (do* (((x t) (infer-expr x env))
              ((e t) (require-type e env t)))
             (return `(set! ,x ,e) 'void)))
       ((begin ,s* ... ,e)
        (do* (((s* _) (infer-expr* s* env))
              ((e t) (infer-expr e env)))
             (return `(begin ,s* ... ,e) t)))
       ((if ,test ,c ,a)
        (do* (((test tt) (require-type test env 'bool))
              ((c t) (infer-expr c env))
              ((a t) (require-type a env t)))
             (return `(if ,test ,c ,a) t)))
       ((if ,test ,c)
        (do* (((test tt) (require-type test env 'bool))
              ((c t) (require-type c env 'void)))
             (return `(if ,test ,c) t)))
       ((lambda (,x* ...) ,body)
        ;; Lambda is a little tricky because of regions in the free
        ;; variables. First we infer the type based on the usual way
        ;; of inferring lambda, but then we determine the regions for
        ;; the free variables in the body. We create a new region
        ;; variable and unify this with all of the regions of free
        ;; variables.
        (let* ((arg-types (map (lambda (x) (make-tvar (gensym x))) x*))
               (env (append (map cons x* arg-types) env))
               (r (gen-rvar 'lambda)))
          (do* (((body tbody)
                 (infer-expr body env)))
               (let* ((fv (free-var-types body x*))
                      (regions (apply union
                                      (map (lambda (x)
                                             (free-regions-type (cdr x)))
                                           fv))))
                 (do* (((_ __) (unify-regions* r regions)))
                      (return
                       `(lambda (closure ,r ,arg-types -> ,tbody)
                          ((,x* ,arg-types) ...)
                          ,body)
                       `(closure ,r ,arg-types -> ,tbody)))))))
       ((let ((,x ,e) ...) ,body)
        (do* (((e t*) (infer-expr* e env))
              ((body t) (infer-expr body (append (map cons x t*) env))))
             (return `(let ((,x ,t* ,e) ...) ,body) t)))
       ((let-region (,r* ...) ,b)
        (do* (((b t) (infer-expr b env)))
             (return `(let-region (,r* ...) ,b) t)))
       ((while ,t ,b)
        (do* (((t _) (require-type t env 'bool))
              ((b _) (infer-expr b env)))
             (return `(while ,t ,b) 'void)))
       ((reduce + ,e)
        (let ((r (make-rvar (gensym 'r)))
              (t (make-tvar (gensym 'reduce-t))))
          (do* (((_ __) (== t 'Numeric))
                ((e t)  (require-type e env `(vec ,r ,t))))
               (return `(reduce ,t + ,e) 'int))))
       ((kernel ((,x ,e) ...) ,b)
        (do* (((e t*) (let loop ((e e))
                       (if (null? e)
                           (return '() '())
                           (let ((e* (cdr e))
                                 (e (car e))
                                 (t (make-tvar (gensym 'kt)))
                                 (r (make-rvar (gensym 'rkt))))
                             (do* (((e* t*) (loop e*))
                                   ((e _) (require-type e env `(vec ,r ,t))))
                                  (return (cons e e*)
                                          (cons (list r t) t*)))))))
              ((b t) (infer-expr b (append
                                    (map (lambda (x t) (cons x (cadr t))) x t*)
                                    env))))
             (let ((r (make-rvar (gensym 'rk))))
               (return `(kernel-r (vec ,r ,t) ,r
                          (((,x ,(map cadr t*))
                            (,e (vec . ,t*))) ...)
                          ,b)
                       `(vec ,r ,t)))))
       ((kernel-r ,r ((,x ,e) ...) ,b)
        (do* (((e t*) (let loop ((e e))
                        (if (null? e)
                            (return '() '())
                            (let ((e* (cdr e))
                                  (e (car e))
                                  (t (make-tvar (gensym 'kt)))
                                  (r (make-rvar (gensym 'rkt))))
                              (do* (((e* t*) (loop e*))
                                    ((e _) (require-type e env `(vec ,r ,t))))
                                   (return (cons e e*)
                                           (cons (list r t) t*)))))))
              ((b t) (infer-expr b (append
                                    (map (lambda (x t) (cons x (cadr t))) x t*)
                                    env))))
             (return `(kernel-r (vec ,r ,t) ,r
                                (((,x ,(map cadr t*))
                                  (,e (vec . ,t*))) ...)
                                ,b)
                     `(vec ,r ,t))))
       ((call ,f ,e* ...) (guard (ident? f))
        (let ((t  (make-tvar (gensym 'rt)))
              (ft (lookup f env)))
          (do* (((e* t*) (infer-expr* e* env))
                ((_  __) (require-type `(var ,f) env `(fn ,t* -> ,t))))
               (return `(call (var (fn ,t* -> ,t) ,f) ,e* ...) t))))
       ((invoke ,rator ,rand* ...)
        (let ((t (gen-tvar 'invoke))
              (r (gen-rvar 'invoke)))
          (do* (((rand* randt*) (infer-expr* rand* env))
                ((rator fty) (require-type rator env
                                           `(closure ,r ,randt* -> ,t))))
               (return `(invoke ,rator . ,rand*) t))))
       ((do ,e)
        (do* (((e t) (infer-expr e env)))
             (return `(do ,e) t)))
       ((match ,e
          ((,tag ,x* ...) ,e*) ...)
        ;; This might be a little tricky, depending on how much
        ;; information we have to start with. If the type of e is
        ;; known at this point, it's easy. However, if we don't know
        ;; if yet (for example, the value was passed in as a
        ;; parameter), we might have to infer the type based on the
        ;; constructors given.
        (match (lookup-type-tags tag env)
          ((,te . ,typedef)
           (do* (((e _) (require-type e env te))
                 ((e* t)
                  (let check-arms ((tag tag)
                                   (x* x*)
                                   (e* e*)
                                   (typedef typedef))
                    (match `(,tag ,x* ,e*)
                      (((,tag . ,tag*) (,x* . ,x**) (,e* . ,e**))
                       (let-values (((constructor rest)
                                     (partition (lambda (x)
                                                  (eq? (car x) tag))
                                                typedef)))
                         (match constructor
                           (((,_ ,t* ...))
                            (do* (((e**^ t) (check-arms tag* x** e** rest))
                                  ((e^ _) (require-type e* (append
                                                            (map cons x* t*)
                                                            env)
                                                        t)))
                                 (return (cons e^ e**^) t))))))
                      ((() () ()) (return '() (make-tvar (gensym 'tmatch))))))))
                (return `(match ,t ,e ((,tag ,x* ...) ,e*) ...) t)))))
        )))
  
  (define infer-body infer-expr)

  (define (make-top-level-env decls adt-graph)
    (append
     (apply append
            (map (lambda (d)
                   (match d
                     ((fn ,name (,[make-tvar -> var*] ...) ,body)
                      `((,name fn (,var* ...) -> ,(make-tvar name))))
                     ((define-datatype ,t
                        (,c ,t* ...) ...)
                      (let* ((end (if (recursive-adt? t adt-graph)
                                      (list (make-rvar (gensym t)))
                                      '()))
                             (t* (map (lambda (t*)
                                        (map (lambda (t*)
                                               (match t*
                                                 ((vec ,[t])
                                                  `(vec ,@end ,t))
                                                 ((closure (,[t*] ...) -> ,[t])
                                                  `(closure ,@end ,t* -> ,t))
                                                 ((adt ,t^)
                                                  (guard
                                                   (recursive-adt? t^
                                                                   adt-graph))
                                                  `(adt ,t^ . ,end))
                                                 (,else else))) t*))
                                      t*)))
                        `((,type-tag (adt ,t . ,end) (,c ,t* ...) ...)
                          (,c fn (,t* ...)
                              -> ,(map (lambda (_) `(adt ,t . ,end)) c)) ...)))
                     ((extern ,name . ,t)
                      (list (cons name (cons 'fn t))))))
                decls))
     ;; Add some primitives
     '((harlan_sqrt fn (float) -> float)
       (floor fn (float) -> float)
       (atan2 fn (float float) -> float))))

  (define (recursive-adt? name graph)
    (let loop ((path (list name)))
      (let ((node (assq (car path) graph)))
        (if node
            (ormap (lambda (n)
                     (or (memq n path)
                         (loop (cons n path))))
                   (cdr node))
            #f))))

  ;; A graph of which types are referenced by each adt. Used by
  ;; recursive-adt?
  (define (make-adt-graph decl*)
    (apply append
           (map (lambda (d)
                  (match d
                    ((define-datatype ,t (,c ,t* ...) ...)
                     `((,t . ,(apply union
                                     (map
                                      (lambda (t^)
                                        (map (lambda (t^)
                                               (match t^
                                                 ;; if we contain a
                                                 ;; vector or closure,
                                                 ;; then the type is
                                                 ;; always
                                                 ;; recursive. We
                                                 ;; trick the type
                                                 ;; checker into
                                                 ;; thinking this by
                                                 ;; putting in a
                                                 ;; self-link if we
                                                 ;; encounter one of
                                                 ;; these types.
                                                 ((vec . ,_) t)
                                                 ((closure . ,_) t)
                                                 ((adt ,t) t)
                                                 (,else else)))
                                             t^))
                                        t*)))))
                    (,else '())))
                decl*)))
  
  (define (infer-module m)
    (match m
      ((module . ,decls)
       (let* ((adt-graph (make-adt-graph decls))
              ;;(_ (pretty-print adt-graph))
              (env (make-top-level-env decls adt-graph)))
         ;;(pretty-print env)
         (infer-decls decls env adt-graph)))))

  (define (infer-decls decls env adt-graph)
    (match decls
      (() (values '() '()))
      ((,d . ,d*)
       (let-values (((d* s) (infer-decls d* env adt-graph)))
         (let-values (((d s) (infer-decl d env s adt-graph)))
           (values (cons d d*) s))))))

  (define (infer-decl d env s adt-graph)
    (match d
      ((extern . ,whatever)
       (values `(extern . ,whatever) s))
      ((define-datatype ,t (,c ,t* ...) ...)
       (values
        (if (recursive-adt? t adt-graph)
            (let* ((r (make-rvar (gensym t)))
                   (t* (map (lambda (t*)
                              (map (lambda (t*)
                                     (match t*
                                       ((closure (,[t*] ...) -> ,[t])
                                        `(closure ,r ,t* -> ,t))
                                       ((adt ,t^)
                                        (guard (recursive-adt? t^ adt-graph))
                                        `(adt ,t^ ,r))
                                       (,else else))) t*))
                            t*)))
              `(define-datatype (,t ,r) (,c ,t* ...)))
            `(define-datatype ,t (,c ,t* ...)))
        s))
      ((fn ,name (,var* ...) ,body)
       ;; find the function definition in the environment, bring the
       ;; parameters into scope.
       (match (lookup name env)
         ((fn (,t* ...) -> ,t)
          (let-values (((b t s)
                        ((infer-body body (append (map cons var* t*) env))
                         body t s)))
            (values
             `(fn ,name (,var* ...) (fn (,t* ...) -> ,t) ,b)
             s)))))))

  (define (lookup x e)
    (let ((t (assq x e)))
      (if t
          (cdr t)
          (error 'lookup "Variable not found" x e))))

  (define (lookup-type-tags tags e)
    (match e
       (()
        (error 'lookup-type-tags "Could not find type from constructors" tags))
       (((,tag (adt ,name . ,end) (,tag* . ,t) ...) . ,rest)
        (guard (and (eq? tag type-tag)
                    (set-equal? tags tag*)))
        `((adt ,name . ,end) (,tag* . ,t) ...))
       ((,e . ,e*) (lookup-type-tags tags e*))))
  
  (define (ground-module m s)
    (if (verbose) (begin (pretty-print m) (newline)
                         (pretty-print s) (newline)))
    
    (match m
      ((module ,[(lambda (d) (ground-decl d s)) -> decl*] ...)
       `(module ,decl* ...))))

  (define (ground-decl d s)
    (match d
      ((extern . ,whatever) `(extern . ,whatever))
      ((define-datatype (,t ,r) (,c ,t* ...) ...)
       `(define-datatype (,t ,(rvar-name r))
          . ,(car (map (lambda (c t*)
                         (map (lambda (c t*)
                                `(,c . ,(map (lambda (t) (ground-type t s)) t*)))
                              c t*)) c t*))))
      ((define-datatype ,t (,c ,t* ...) ...)
       `(define-datatype ,t
          . ,(car (map (lambda (c t*)
                         (map (lambda (c t*)
                                `(,c . ,(map (lambda (t) (ground-type t s)) t*)))
                              c t*)) c t*))))
      ;;((define-datatype ,t (,c ,t* ...) ...)
      ;; `(define-datatype ,t (,c ,t* ...) ...))
      ((fn ,name (,var ...)
           ,[(lambda (t) (ground-type t s)) -> t]
           ,[(lambda (e) (ground-expr e s)) -> body])
       (let* ((region-params (free-regions-type t))
              (body-regions (free-regions-expr body))
              (local-regions (difference body-regions region-params)))
       `(fn ,name (,var ...) ,t (let-region ,local-regions ,body))))))

  (define (region-name r)
    (if (rvar? r)
        (rvar-name r)
        r))
  
  (define (ground-type t s)
    (let ((t (walk-type t s)))
      (if (tvar? t)
          (let ((t^ (assq t s)))
            (if t^
                (case (cdr t^)
                  ;; We have a free variable that's constrained as
                  ;; Numeric, so ground it as an integer.
                  ((Numeric) 'int))
                (error 'ground-type "free type variable" t)))
          (match t
            (,prim (guard (symbol? prim)) prim)
            ((vec ,r ,t) `(vec ,(region-name r) ,(ground-type t s)))
            ((ptr ,t) `(ptr ,(ground-type t s)))
            ((adt ,t) `(adt ,(ground-type t s)))
            ((adt ,t ,r) `(adt ,(ground-type t s) ,(region-name r)))
            ((closure ,r (,[(lambda (t) (ground-type t s)) -> t*] ...) -> ,t)
             `(closure ,(region-name r) ,t* -> ,(ground-type t s)))
            ((fn (,[(lambda (t) (ground-type t s)) -> t*] ...) -> ,t)
             `(fn ,t* -> ,(ground-type t s)))
            (,else (error 'ground-type "unsupported type" else))))))

  (define (ground-expr e s)
    (let ((ground-type (lambda (t) (ground-type t s))))
      (match e
        ((int ,n) `(int ,n))
        ((float ,f) `(float ,f))
        ;; This next line is cheating, but it should get us through
        ;; the rest of the compiler.
        ((num ,n) `(int ,n))
        ((char ,c) `(char ,c))
        ((str ,s) `(str ,s))
        ((bool ,b) `(bool ,b))
        ((var ,[ground-type -> t] ,x) `(var ,t ,x))
        ((int->float ,[e]) `(int->float ,e))
        ((float->int ,[e]) `(float->int ,e))
        ((,op ,[ground-type -> t] ,[e1] ,[e2])
         (guard (or (relop? op) (binop? op)))
         `(,op ,t ,e1 ,e2))
        ((print ,[ground-type -> t] ,[e]) `(print ,t ,e))
        ((print ,[ground-type -> t] ,[e] ,[f]) `(print ,t ,e ,f))
        ((println ,[ground-type -> t] ,[e]) `(println ,t ,e))
        ((assert ,[e]) `(assert ,e))
        ((iota-r ,r ,[e]) `(iota-r ,(region-name (walk r s)) ,e))
        ((iota ,[e]) `(iota ,e))
        ((make-vector ,[ground-type -> t] ,[len] ,[val])
         `(make-vector ,t ,len ,val))
        ((lambda ,[ground-type -> t0] ((,x ,[ground-type -> t]) ...) ,[b])
         `(lambda ,t0 ((,x ,t) ...) ,b))
        ((let ((,x ,[ground-type -> t] ,[e]) ...) ,[b])
         `(let ((,x ,t ,e) ...) ,b))
        ((for (,x ,[start] ,[end] ,[step]) ,[body])
         `(for (,x ,start ,end ,step) ,body))
        ((while ,[t] ,[b]) `(while ,t ,b))
        ((vector ,[ground-type -> t] ,[e*] ...)
         `(vector ,t ,e* ...))
        ((length ,[e]) `(length ,e))
        ((vector-ref ,[ground-type -> t] ,[v] ,[i])
         `(vector-ref ,t ,v ,i))
        ((unsafe-vector-ref ,[ground-type -> t] ,[v] ,[i])
         `(unsafe-vector-ref ,t ,v ,i))
        ((unsafe-vec-ptr ,[ground-type -> t] ,[v])
         `(unsafe-vec-ptr ,t ,v))
        ((kernel-r ,[ground-type -> t] ,r
           (((,x ,[ground-type -> ta*]) (,[e] ,[ground-type -> ta**])) ...)
           ,[b])
         `(kernel-r ,t ,(region-name (walk r s))
                    (((,x ,ta*) (,e ,ta**)) ...) ,b))
        ((reduce ,[ground-type -> t] + ,[e]) `(reduce ,t + ,e))
        ((set! ,[x] ,[e]) `(set! ,x ,e))
        ((begin ,[e*] ...) `(begin ,e* ...))
        ((if ,[t] ,[c] ,[a]) `(if ,t ,c ,a))
        ((if ,[t] ,[c]) `(if ,t ,c))
        ((return) `(return))
        ((return ,[e]) `(return ,e))
        ((call ,[f] ,[e*] ...) `(call ,f ,e* ...))
        ((invoke ,[rator] ,[rand*] ...) `(invoke ,rator . ,rand*))
        ((do ,[e]) `(do ,e))
        ((let-region (,r* ...) ,[e]) `(let-region (,r* ...) ,e))
        ((match ,[ground-type -> t] ,[e]
                ((,tag . ,x) ,[e*]) ...)
         `(match ,t ,e ((,tag . ,x) ,e*) ...))
        (,else (error 'ground-expr "Unrecognized expression" else))
        )))

  (define-match free-regions-expr
    ((var ,[free-regions-type -> t] ,x) t)
    ((int ,n) '())
    ((float ,f) '())
    ((char ,c) '())
    ((bool ,b) '())
    ((str ,s) '())
    ((int->float ,[e]) e)
    ((float->int ,[e]) e)
    ((assert ,[e]) e)
    ((print ,[free-regions-type -> t] ,[e]) (union t e))
    ((print ,[free-regions-type -> t] ,[e] ,[f]) (union t e f))
    ((println ,[free-regions-type -> t] ,[e]) (union t e))
    ((,op ,[free-regions-type -> t] ,[rhs] ,[lhs])
     (guard (or (binop? op) (relop? op)))
     (union t lhs rhs))
    ((vector ,[free-regions-type -> t] ,[e*] ...)
     (union t (apply union e*)))
    ((length ,[e]) e)
    ((vector-ref ,[free-regions-type -> t] ,[x] ,[i]) (union t x i))
    ((unsafe-vector-ref ,[free-regions-type -> t] ,[x] ,[i]) (union t x i))
    ((unsafe-vec-ptr ,[free-regions-type -> t] ,[v])
     (union t v))
    ((iota-r ,r ,[e]) (set-add e r))
    ((make-vector ,[free-regions-type -> t] ,[len] ,[val])
     (union t len val))
    ((kernel-r ,[free-regions-type -> t] ,r
       (((,x ,[free-regions-type -> t*]) (,xs ,[free-regions-type -> ts*])) ...)
       ,[b])
     (set-add (union b t (apply union (append t* ts*))) r))
    ((reduce ,[free-regions-type -> t] ,op ,[e]) (union t e))
    ((set! ,[x] ,[e]) (union x e))
    ((begin ,[e*] ...) (apply union e*))
    ((lambda ,[free-regions-type -> t0]
       ((,x ,[free-regions-type -> t]) ...) ,b)
     ;; The type inferencer is designed so that each lambda should
     ;; have no free regions other than the type-inferencer supplied
     ;; region.
     (apply union t0 t))
    ((let ((,x ,[free-regions-type -> t] ,[e]) ...) ,[b])
     (union b (apply union (append t e))))
    ((for (,x ,[start] ,[end] ,[step]) ,[body])
     (union start end step body))
    ((while ,[t] ,[e]) (union t e))
    ((if ,[t] ,[c] ,[a]) (union t c a))
    ((if ,[t] ,[c]) (union t c))
    ((call ,[e*] ...) (apply union e*))
    ((invoke ,[e*] ...) (apply union e*))
    ((do ,[e]) e)
    ((let-region (,r* ...) ,[e])
     (difference e r*))
    ((match ,[free-regions-type -> t] ,[e]
            (,p ,[e*]) ...)
     (apply union `(,t ,e . ,e*)))
    ((return) '())
    ((return ,[e]) e))

  (define-match free-regions-type
    ;; This isn't fantastic... what if this later unifies to a type
    ;; that contains a region? We might need some sort of lazy
    ;; suspension thingy.
    (,x (guard (tvar? x)) '())
    ((vec ,r ,[t]) (set-add t r))
    ((adt ,[t] ,r) (set-add t r))
    ((adt ,[t]) t)
    ((closure ,r (,[t*] ...) -> ,[t])
     (set-add (apply union t t*) r))
    ((fn (,[t*] ...) -> ,[t]) (union t (apply union t*)))
    ((ptr ,[t]) t)
    (() '())
    (,else (guard (symbol? else)) '()))
  )
