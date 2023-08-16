;;; Scheme in Common Lisp

(defconstant +command-line-args+
  (or #+SBCL (cdr *posix-argv*)
      nil))

(defconstant +quasiquote-symbol+
  (or #+SBCL 'sb-int:quasiquote
      nil))

(defparameter *special-forms*
  `(define
    if
    cond
    case ; TODO: implement
    and
    or
    let
    let* ; TODO: implement
    letrec ; TODO: implement
    begin
    lambda
    quote
    quasiquote
    ,+quasiquote-symbol+
    unquote
    define-macro
    unquote-splicing
    ;; delay
    ;; cons-stream
    set!)
  "Scheme special forms.")

;; Until `#t` and `#f` is implemented correclty
(set-dispatch-macro-character #\# #\t #'(lambda (&rest _)
					  (declare (ignore _)) t))
(set-dispatch-macro-character #\# #\f #'(lambda (&rest _)
					  (declare (ignore _)) nil))

(declaim (ftype function evaluate))

;; TODO
;; set-car!, set-cdr!
;; closures

(defvar *global-env* nil
  "Interpreter's global environment.")

(defun push-cdr (obj place)
  (setf (cdr place) (cons obj (cdr place))))

(defun lookup (sym env)
  (cdr (assoc sym env)))

(defun update-env (sym value env)
  (setf (cdr (assoc sym env)) value))

(defstruct Procedure
  "Scheme function defined with lambda and define special forms."
  params body env)

(defstruct Macro
  "Scheme macro defined with define-macro special form."
  params body env)

(defun create-env (bindings env)
  (loop
    for bind in bindings
    collect (cons (car bind) (funcall #'evaluate (cadr bind) env))))

(defun extend-env (params args env)
  (cons nil
	(append (loop
		  for sym in params
		  for val in args
		  collect (cons sym val))
		(cdr env))))

(defun evaluate-body (body env)
  (dolist (expression (butlast body)
	   (funcall #'evaluate
		    (car (last body))
		    env))
    (funcall #'evaluate expression env)))

(defun contains-comma-at-p (sexp)
  (some #'(lambda (x)
	    (and (consp x) (eq 'unquote-splicing (car x))))
	sexp))

(defun sym-position (sym sexp)
  (position sym
	    sexp
	    :test #'(lambda (item x)
		      (and (consp x) (eq item (car x))))))

(defun traverse-quasiquoted (tree env)
  (if (atom tree)
      tree
      (cond ((eq 'unquote (car tree)) ; TODO: Figure out how to add , reader macro
	     (funcall #'evaluate (cadr tree) env))
	    ((contains-comma-at-p tree)
	     (let* ((pos (sym-position 'unquote-splicing tree))
		    (before (subseq tree 0 pos))
		    (after (subseq tree (1+ pos)))
		    (tosplice (funcall #'evaluate (cadr (nth pos tree)))))
	       (append (traverse-quasiquoted before env)
		       tosplice
		       (traverse-quasiquoted after env))))
	    (t (cons (traverse-quasiquoted (car tree) env)
		     (traverse-quasiquoted (cdr tree) env))))))

(defun evaluate-special-form (form args env)
  (case form
    ((if) ; TODO: Should work without else
     (if (= 3 (length args))
	 (if (funcall #'evaluate (car args) env)
	     (funcall #'evaluate (cadr args) env)
	     (funcall #'evaluate (caddr args) env))
	 (error "malformed if special form")))
    ((or)
     (let ((frst (funcall #'evaluate (car args) env)))
       (if frst
	   frst
	   (when (consp (cdr args))
	     (funcall #'evaluate
		      `(or ,@(cdr args)) env)))))
    ((and)
     (let ((frst (funcall #'evaluate (car args) env)))
       (if (null frst)
	   frst
	   (if (consp (cdr args))
	       (funcall #'evaluate `(and ,@(cdr args)) env)
	       frst))))
    ((define)
     (if (consp (car args))
	 (progn
	   (push-cdr
	    (cons (caar args)
		  (make-Procedure :params (cdar args)
				  :body (cdr args)
				  :env env))
	    env)
	   (caar args))
	 (progn
	   (push-cdr (cons (car args)
			   (funcall #'evaluate
				    (cadr args)
				    env))
		     env)
	   (car args))))
    ((cond) ; TODO: Add `else` and `=>`
     (let ((result nil))
       (loop
	 named cond-loop
	 for pair in args
	 ;; TODO: Maybe this can be rewritten
	 do (when (funcall #'evaluate (car pair) env)
	      (setq result (funcall #'evaluate (cadr pair) env))
	      (return-from cond-loop)))
       result))
    ((let)
     (let ((current-env (cons nil
			      (append
			       (create-env (car args) env)
			       (cdr env))))
	   (body (cdr args)))
       (evaluate-body body current-env)))
    ((begin)
     (evaluate-body args env))
    ((lambda) ; TODO: Add argument destructuring
     (make-Procedure :params (car args)
		     :body (cdr args)
		     :env env))
    ((quote)
     (if (> (length args) 1)
	 (error "wrong number of args ~a" (length args)) ; TODO: if-let macro
	 (car args)))
    (`(or quasiquote ,+quasiquote-symbol+)
     (if (> (length args) 1)
	 (error "wrong number of args ~a" (length args)) ; TODO: if-let macro
	 (traverse-quasiquoted (car args) env)))
    ((define-macro)
     (progn
       (push-cdr
	(cons (caar args)
	      (make-Macro :params (cdar args)
			  :body (cdr args)
			  :env env))
	env)
       (caar args)))
    ((set!)
     (if (null (assoc (car args) env))
	 (error "~a undefined~%" (car args))
	 (progn
	   (update-env (car args) (funcall #'evaluate (cadr args) env) env)
	   (car args))))
    ))

(defun evaluate (expr &optional (env *global-env*))
  (if (consp expr)
      (let ((root     (car expr))
	    (branches (cdr expr)))
	(if (member root *special-forms*)
	    (evaluate-special-form root branches env)
	    (let ((callable (if (consp root)
			       (evaluate root env)
			       (lookup root env))))
	      (cond
		((functionp callable)
		 (apply callable
			(mapcar #'(lambda (form)
				    (funcall #'evaluate form env))
				branches)))
		((Procedure-p callable)
		 (let* ((args (mapcar #'(lambda (form)
					  (funcall #'evaluate form env))
				      branches))
			(body (Procedure-body callable))
			(scope (extend-env (Procedure-params callable)
					   args
					   (or (Procedure-env callable) *global-env*))))
		   (evaluate-body body scope)))
		((Macro-p callable)
		 (let ((scope (extend-env (Macro-params callable)
					  branches
					  (Macro-env callable))))
		   ;; (evaluate-body (Macro-body callable) scope)
		   (evaluate
		    (evaluate-body (Macro-body callable) scope)
		    scope)
		   )) ; TODO: Probably separate macro-expansion from evaluation
		(t (error "~a not callable" root))))))
      (cond
	((keywordp expr) expr)
	((symbolp expr)
	 (lookup expr env))
	(t expr))))

(setq *global-env*
      (list nil ; So we can descructively push inside function
	    ;; Numeric operations
	    (cons '+ #'+)
	    (cons '- #'-)
	    (cons '* #'*)
	    (cons '/ #'/)
	    (cons '= #'=)
	    (cons 'abs #'abs)
	    (cons 'expt #'expt)
	    (cons 'modulo #'mod)
	    (cons 'quotient #'floor)
	    (cons 'remainder #'rem)
	    (cons 'min #'min)
	    (cons 'max #'max)
	    (cons '< #'<)
	    (cons '> #'>)
	    (cons '>= #'>=)
	    (cons '<= #'<=)
	    (cons 'even? #'evenp)
	    (cons 'odd? #'oddp)
	    (cons 'zero? #'zerop)
	    ;; List operations
	    (cons 'cons #'cons)
	    (cons 'car #'car)
	    (cons 'cdr #'cdr)
	    (cons 'list #'list)
	    (cons 'append #'append)
	    (cons 'length #'length)
	    (cons 'apply #'apply)
	    ;; Printing
	    (cons 'print #'print)
	    (cons 'display #'princ) ; TODO: It also prints output
	    (cons 'displayln #'print)
	    (cons 'newline #'(lambda () (format t "~%")))
	    (cons 'print #'print)
	    ;; Type cheking
	    (cons 'atom? #'atom)
	    (cons 'boolean? #'(lambda (x) (or (null x) (eq x t))))
	    (cons 'integer? #'integerp)
	    (cons 'list? #'listp)
	    (cons 'number? #'numberp)
	    (cons 'null? #'null)
	    (cons 'pair? #'(lambda (x) (and (car x) (cdr x) t)))
	    (cons 'string? #'stringp)
	    (cons 'symbol? #'symbolp)
	    (cons 'char? #'characterp)
	    (cons 'vector? #'vectorp)
	    ;; (cons 'port? nil)
	    ;; General
	    (cons 'eq? #'eq)
	    (cons 'equal? #'equal)
	    (cons 'not #'not)
	    (cons 'string=? #'string=)
	    (cons 'error #'error)
	    (cons 'exit (constantly :quit))
	    ;;
	    (cons '#t t)
	    (cons '#f nil)
	    ;;
	    (cons 'eval #'evaluate)
	    (cons 'procedure? #'Procedure-p)
	    ))

(evaluate
 '(define (map op seq)
   (if (null? seq)
       seq
       (cons (op (car seq)) (map op (cdr seq))))))

(evaluate
 '(define (filter pred seq)
   (if (null? seq)
       seq
       (if (pred (car seq))
           (cons (car seq) (filter pred (cdr seq)))
           (myfilter pred (cdr seq))))))

(evaluate
 '(define (reduce op initial seq)
   (if (null? seq)
       initial
       (reduce op (op initial (car seq)) (cdr seq)))))

(defun prompt-expr ()
  (format *query-io* "λ> ")
  (force-output *query-io*)
  (read t t))

(defun repl ()
  (loop
    (handler-case
	(let ((result (evaluate (prompt-expr) *global-env*)))
	  (if (equal result :quit)
	      (return)
	      (format t "~a~%" result)))
      (end-of-file () (return))
      (error (err) (format t "~a~%" err))))
  (format t "Bye!"))

(defun load-script (filename)
  (with-open-file (script filename)
    (let ((result nil))
      (loop
	(let ((sexp (read script nil :eof)))
	  (if (eq sexp :eof)
	      (progn
		(format t "~a~%" result)
		(return))
	      (handler-case
		  (setq result (evaluate sexp *global-env*))
		(error (err) (format t "~a~%" err)))))))))

(defun main ()
  (if (>= (length +command-line-args+) 1)
      (load-script (car +command-line-args+))
      (repl)))

(main)
