;;;;  -*- Mode: Lisp; Syntax: Common-Lisp; Package: C -*-
;;;;
;;;;  CMPLET  Let and Let*.
;;;;
;;;;  Copyright (c) 1984, Taiichi Yuasa and Masami Hagiya.
;;;;  Copyright (c) 1990, Giuseppe Attardi.
;;;;
;;;;    ECL is free software; you can redistribute it and/or modify it
;;;;    under the terms of the GNU Library General Public License as
;;;;    published by the Free Software Foundation; either version 2 of
;;;;    the License, or (at your option) any later version.
;;;;
;;;;    See file '../Copyright' for full details.

(in-package "COMPILER")

(defun c1let (args)
  (check-args-number 'LET args 1)
  (let ((bindings (pop args)))
    (cond ((null bindings)
           (c1locally args))
          ((atom bindings)
           (invalid-let-bindings 'LET bindings))
          ((null (rest bindings))
           (c1let/let* 'let* bindings args))
          (t
           (c1let/let* 'let bindings args)))))

(defun c1let* (args)
  (check-args-number 'LET* args 1)
  (let ((bindings (pop args)))
    (cond ((null bindings)
           (c1locally args))
          ((atom bindings)
           (invalid-let-bindings 'LET bindings))
          (t
           (c1let/let* 'let* bindings args)))))

(defun c1let/let* (let/let* bindings body)
  (let* ((setjmps *setjmps*)
         (*cmp-env* (cmp-env-copy)))
    (multiple-value-bind (vars forms body)
        (process-let-bindings let/let* bindings body)
      ;; Try eliminating unused variables, replace constant ones, etc.
      (multiple-value-setq (vars forms)
        (c1let-optimize-read-only-vars vars forms body))
      ;; Verify that variables are referenced and assign final boxed / unboxed type
      (mapc #'check-vref vars)
      (let ((sp-change (some #'global-var-p vars)))
        (make-c1form* let/let*
                      :type (c1form-type body)
                      :volatile (not (eql setjmps *setjmps*))
                      :local-vars vars
                      :args vars forms body)))))

(defun invalid-let-bindings (let/let* bindings)
  (cmperr "Syntax error in ~A bindings:~%~4I~A"
          let/let* bindings))

(defun process-let-bindings (let/let* bindings body)
  (multiple-value-bind (body specials types ignoreds other-decls)
      (c1body body nil)
    (let ((vars '())
          (forms '()))
      (do ((b bindings)
           name form)
          ((atom b)
           (unless (null b)
             (invalid-let-bindings let/let* bindings)))
        (if (symbolp (setf form (pop b)))
            (setf name form form nil)
            (progn
              (check-args-number "LET/LET* binding" form 1 2)
              (setf name (first form) form (rest form))))
        (let* ((var (c1make-var name specials ignoreds types))
               (init (if form
                         (and-form-type (var-type var)
                                        (c1expr (setf form (first form)))
                                        form
                                        :unsafe
                                        "In LET/LET* bindings")
                         (default-init var))))
          ;; :read-only variable handling. Beppe
          (when (read-only-variable-p name other-decls)
            (setf (var-type var) (c1form-primary-type init)))
          (push var vars)
          (push init forms)
          (when (eq let/let* 'LET*) (push-vars var))))
      (setf vars (nreverse vars)
            forms (nreverse forms))
      (when (eq let/let* 'LET)
        (mapc #'push-vars vars))
      (check-vdecl (mapcar #'var-name vars) types ignoreds)
      (c1declare-specials specials)
      (values vars forms (c1decl-body other-decls body)))))

(defun c1let-optimize-read-only-vars (all-vars all-forms body)
  (loop with base = (list body)
     for vars on all-vars
     for forms on (nconc all-forms (list body))
     for var = (first vars)
     for form = (first forms)
     for rest-vars = (cdr vars)
     for rest-forms = (cdr forms)
     for read-only-p = (and (null (var-set-nodes var))
                            (null (var-functions-reading var))
                            (null (var-functions-setting var))
                            (not (global-var-p var)))
     when read-only-p
     do (fix-read-only-variable-type var form rest-forms)
     unless (and read-only-p
                (or (c1let-unused-variable-p var form)
                    (c1let-constant-value var form rest-vars rest-forms)
                    (c1let-can-move-variable-value-p var form rest-vars rest-forms)))
     collect var into used-vars and
     collect form into used-forms
     finally (return (values used-vars used-forms))))

(defun fix-read-only-variable-type (var form rest-forms)
  (and-form-type (var-type var) form (var-name var) :unsafe "In LET body")
  (let ((form-type (c1form-primary-type form)))
    (setf (var-type var) form-type)
    (update-var-type var form-type rest-forms)))

(defun c1let-unused-variable-p (var form)
  ;; * (let ((v2 e2)) e3 e4) => (let () e3 e4)
  ;;   provided
  ;;   - v2 does not appear in body
  ;;   - e2 produces no side effects
  (when (and (= 0 (var-ref var))
             (not (member (var-kind var) '(special global)))
             (not (form-causes-side-effect form)))
    (unless (var-ignorable var)
      (cmpdebug "Removing unused variable ~A" (var-name var)))
    (delete-c1forms form)
    t))

(defun c1let-constant-value (var form rest-vars rest-forms)
  ;;  (let ((v1 e1) (v2 e2) (v3 e3)) (expr e4 v2 e5))
  ;;  - v2 is a read only variable
  ;;  - the value of e2 is not modified in e3 nor in following expressions
  (when (and (notany #'(lambda (v) (var-referenced-in-form v form)) rest-vars)
             (c1form-unmodified-p form rest-forms))
    (cmpdebug "Replacing variable ~A by its value ~A" (var-name var) form)
    (nsubst-var var form)
    t))

(defun c1let-can-move-variable-value-p (var form rest-vars rest-forms)
  ;;  (let ((v1 e1) (v2 e2) (v3 e3)) (expr e4 v2 e5))
  ;;  can become
  ;;  (let ((v1 e1) (v3 e3)) (expr e4 e2 e5))
  ;;  provided
  ;;  - v2 appears only once
  ;;  - v2 appears only in body
  ;;  - e2 does not affect v1 nor e3, e3 does not affect e2
  ;;  - e4 does not affect e2
  (when (and (= 1 (var-ref var))
             (not (form-causes-side-effect form))
             ;; it does not refer to special variables which
             ;; are changed in the LET form
             (notany #'(lambda (v) (var-referenced-in-form v form)) rest-vars)
             (replaceable var rest-forms))
    (cmpdebug "Replacing variable ~A by its value ~A" (var-name var) form)
    (nsubst-var var form)
    t))

(defun update-var-type (var type x)
  (cond ((consp x)
	 (dolist (e x)
	   (update-var-type var type e)))
	((not (c1form-p x)))
	((eq (c1form-name x) 'VAR)
	 (when (eq var (c1form-arg 0 x))
	   (setf (c1form-type x) (type-and (c1form-primary-type x) type))))
	(t
	 (update-var-type var type (c1form-args x)))))

(defun read-only-variable-p (v other-decls)
  (dolist (i other-decls nil)
    (when (and (eq (car i) :READ-ONLY)
	       (member v (rest i)))
      (return t))))

(defun update-variable-type (var form)
  (unless (or (var-set-nodes var)
              (unboxed var))
    (setf (var-type var)
          (type-and (var-type var) (c1form-primary-type form)))))

(defun c2let (vars forms body
                   &aux (block-p nil) (bindings nil)
                   initials
                   (*unwind-exit* *unwind-exit*)
		   (*env* *env*)
                   (*env-lvl* *env-lvl*) env-grows)
  (declare (type boolean block-p))

  ;; FIXME! Until we switch on the type propagation phase we do
  ;; this little optimization here
  (mapc 'update-variable-type vars forms)

  ;; Allocation is needed for:
  ;; 1. each variable which is LOCAL and which is not REPLACED
  ;;    or whose value is not DISCARDED
  ;; 2. each init form for the remaining variables except last

  ;; Determine which variables are really necessary and create list of init's
  ;; and list of bindings. Bindings for specials must be done after all inits.
  (labels ((do-decl (var)
	     (declare (type var var))
	     (wt-nl)
	     (unless block-p
	       (wt "{") (setq block-p t))
	     (wt *volatile* (rep-type-name (var-rep-type var)) " " var ";")
	     (when (local var)
	       (wt-comment (var-name var))))
	   (do-init (var form fl)
	     (if (and (local var)
		      (not (args-cause-side-effect (cdr fl))))
		 ;; avoid creating temporary for init
		 (push (cons var form) initials)
		 (let* ((loc (make-lcl-var :rep-type (var-rep-type var)
					   :type (var-type var))))
		   (do-decl loc)
		   (push (cons loc form) initials)
		   (push (cons var loc) bindings)))))

    (do ((vl vars (rest vl))
         (fl forms (rest fl))
         (form) (var)
         (prev-ss nil) (used t t))
        ((endp vl))
      (declare (type var var))
      (setq form (first fl)
            var (first vl))
      (if (local var)
	  (if (setq used (not (discarded var form body)))
	    (progn
	      (setf (var-loc var) (next-lcl))
	      (do-decl var))
	    ;; The variable is discared, we simply replace it with
	    ;; a dummy value that will not get used.
	    (setf (var-kind var) 'REPLACED
		  (var-loc var) NIL)))
      (when used
	(if (unboxed var)
	    (push (cons var form) initials)	; nil (ccb)
	    ;; LEXICAL, SPECIAL, GLOBAL or :OBJECT
	    (case (c1form-name form)
	      (LOCATION
	       (if (can-be-replaced var body)
		   (setf (var-kind var) 'REPLACED
			 (var-loc var) (c1form-arg 0 form))
		   (push (cons var (c1form-arg 0 form)) bindings)))
	      (VAR
	       (let* ((var1 (c1form-arg 0 form)))
		 (cond ((or (var-changed-in-form-list var1 (cdr fl))
			    (and (member (var-kind var1) '(SPECIAL GLOBAL))
				 (member (var-name var1) prev-ss)))
			(do-init var form fl))
		       ((and ;; Fixme! We should be able to replace variable
			     ;; even if they are referenced across functions.
			     ;; We just need to keep track of their uses.
			     (member (var-kind var1) '(REPLACED :OBJECT))
			     (can-be-replaced var body)
			     (not (var-changed-in-form var1 body)))
			(setf (var-kind var) 'REPLACED
			      (var-loc var) var1))
		       (t (push (cons var var1) bindings)))))
	      (t (do-init var form fl))))
	(unless env-grows
	  (setq env-grows (var-ref-ccb var))))
      (when (eq (var-kind var) 'SPECIAL) (push (var-name var) prev-ss))))

  (when (env-grows env-grows)
    (unless block-p
      (wt-nl "{ ") (setq block-p t))
    (let ((env-lvl *env-lvl*))
      (wt "volatile cl_object env" (incf *env-lvl*) " = env" env-lvl ";")))

  ;; eval INITFORM's and bind variables
  (dolist (init (nreverse initials))
    (let ((*destination* (car init))
	  (*lcl* *lcl*))
      (c2expr* (cdr init))))
  ;; bind LET variables
  (dolist (binding (nreverse bindings))
    (bind (cdr binding) (car binding)))

  (if (policy-debug-variable-bindings)
      (let ((*unwind-exit* *unwind-exit*))
        (wt-nl "{")
        (let* ((env (build-debug-lexical-env vars)))
          (when env (push 'IHS-ENV *unwind-exit*))
          (c2expr body)
          (wt-nl "}")
          (when env (pop-debug-lexical-env))))
      (c2expr body))

  (when block-p (wt-nl "}"))
  )

(defun env-grows (possibily)
  ;; if additional closure variables are introduced and this is not
  ;; last form, we must use a new env.
  (and possibily
       (plusp *env*)
       (dolist (exit *unwind-exit*)
	 (case exit
	   (RETURN (return NIL))
	   (BDS-BIND)
	   (t (return T))))))

;; should check whether a form before var causes a side-effect
;; exactly one occurrence of var is present in forms
(defun replaceable (var form)
  (labels ((abort-on-side-effects (form)
             (if (eq (c1form-name form) 'VAR)
                 (when (eq var (first (c1form-args form)))
                   (return-from replaceable t))
                 (when (c1form-side-effects form)
                   (return-from replaceable nil)))))
    (traverse-c1form-tree form #'abort-on-side-effects)
    (baboon :format-control "In REPLACEABLE, variable ~A not found. Form:~%~A"
            :format-arguments (list (var-name var) *current-form*))))

(defun c2let* (vars forms body
                    &aux (block-p nil)
                    (*unwind-exit* *unwind-exit*)
		    (*env* *env*)
		    (*env-lvl* *env-lvl*) env-grows)
  (declare (type boolean block-p))

  ;; FIXME! Until we switch on the type propagation phase we do
  ;; this little optimization here
  (mapc 'update-variable-type vars forms)

  (do ((vl vars (cdr vl))
       (fl forms (cdr fl))
       (var) (form) (kind))
      ((endp vl))
    (declare (type var var))
    (setq form (car fl)
          var (car vl)
          kind (local var))
    (unless (unboxed var)
      ;; LEXICAL, CLOSURE, SPECIAL, GLOBAL or OBJECT
      (case (c1form-name form)
        (LOCATION
         (when (can-be-replaced* var body (cdr fl))
	   (cmpdebug "Replacing variable ~a by its value" (var-name var))
           (setf (var-kind var) 'REPLACED
                 (var-loc var) (c1form-arg 0 form))))
        (VAR
         (let* ((var1 (c1form-arg 0 form)))
           (declare (type var var1))
           (when (and ;; Fixme! We should be able to replace variable
		      ;; even if they are referenced across functions.
		      ;; We just need to keep track of their uses.
		      (member (var-kind var1) '(REPLACED :OBJECT))
		      (can-be-replaced* var body (cdr fl))
		      (not (var-changed-in-form-list var1 (rest fl)))
		      (not (var-changed-in-form var1 body)))
	     (cmpdebug "Replacing variable ~a by its value" (var-name var))
             (setf (var-kind var) 'REPLACED
                   (var-loc var) var1)))))
      (unless env-grows
	(setq env-grows (var-ref-ccb var))))
    (when (and kind (not (eq (var-kind var) 'REPLACED)))
      (bind (next-lcl) var)
      (wt-nl) (unless block-p (wt "{") (setq block-p t))
      (wt *volatile* (rep-type-name kind) " " var ";")
      (wt-comment (var-name var)))
    )

  (when (env-grows env-grows)
    (unless block-p
      (wt-nl "{ ") (setq block-p t))
    (let ((env-lvl *env-lvl*))
      (wt *volatile* "cl_object env" (incf *env-lvl*) " = env" env-lvl ";")))

  (do ((vl vars (cdr vl))
       (fl forms (cdr fl))
       (var nil) (form nil))
      ((null vl))
    (declare (type var var))
    (setq var (car vl)
	  form (car fl))
    (case (var-kind var)
      (REPLACED)
      ((LEXICAL CLOSURE SPECIAL GLOBAL)
       (case (c1form-name form)
	 (LOCATION (bind (c1form-arg 0 form) var))
	 (VAR (bind (c1form-arg 0 form) var))
	 (t (bind-init form var))))
      (t ; local var
       (let ((*destination* var)) ; nil (ccb)
	 (c2expr* form)))
      )
    )
  (if (policy-debug-variable-bindings)
      (let ((*unwind-exit* *unwind-exit*))
        (wt-nl "{")
        (let* ((env (build-debug-lexical-env vars)))
          (when env (push 'IHS-ENV *unwind-exit*))
          (c2expr body)
          (wt-nl "}")
          (when env (pop-debug-lexical-env))))
      (c2expr body))

  (when block-p (wt-nl "}"))
  )

(defun discarded (var form body &aux last)
  (labels ((last-form (x &aux (args (c1form-args x)))
	     (case (c1form-name x)
	       (PROGN
		 (last-form (car (last (first args)))))
	       ((LET LET* FLET LABELS BLOCK CATCH)
		(last-form (car (last args))))
	       (VAR (c1form-arg 0 x))
	       (t x))))
    (and (not (form-causes-side-effect form))
	 (or (< (var-ref var) 1)
	     (and (= (var-ref var) 1)
		  (eq var (last-form body))
		  (eq 'TRASH *destination*))))))

(defun can-be-replaced (var body)
  (declare (type var var))
  (and (eq (var-kind var) :OBJECT)
       (not (var-changed-in-form var body))))

(defun can-be-replaced* (var body forms)
  (declare (type var var))
  (and (can-be-replaced var body)
       (not (var-changed-in-form-list var forms))))

;; should check whether a form before var causes a side-effect
;; exactly one occurrence of var is present in forms
(defun delete-c1forms (form)
  (flet ((eliminate-references (form)
           (if (eq (c1form-name form) 'VAR)
               (let ((var (c1form-arg 0 form)))
                 (when var
                   (decf (var-ref var))
                   (setf (var-ref var) (1- (var-ref var))
                         (var-read-nodes var)
                         (delete form (var-read-nodes var))))))))
    (traverse-c1form-tree form #'eliminate-references)))

(defun nsubst-var (var form)
  (when (var-set-nodes var)
    (baboon :format-control "Cannot replace a variable that is to be changed"))
  (when (var-functions-reading var)
    (baboon :format-control "Cannot replace a variable that is closed over"))
  (dolist (where (var-read-nodes var))
    (unless (and (eql (c1form-name where) 'VAR)
                 (eql (c1form-arg 0 where) var))
      (baboon :format-control "VAR-READ-NODES are only C1FORMS of type VAR"))
    (c1form-replace-with where form))
  (setf (var-read-nodes var) nil
        (var-ref var) 0
        (var-ignorable var) t))

(defun member-var (var list)
  (let ((kind (var-kind var)))
    (if (member kind '(SPECIAL GLOBAL))
	(member var list :test
		#'(lambda (v1 v2)
		    (and (member (var-kind v2) '(SPECIAL GLOBAL))
			 (eql (var-name v1) (var-name v2)))))
	(member var list))))

;;; ----------------------------------------------------------------------

(put-sysprop 'LET 'C1SPECIAL 'c1let)
(put-sysprop 'LET 'C2 'c2let)
(put-sysprop 'LET* 'C1SPECIAL 'c1let*)
(put-sysprop 'LET* 'C2 'c2let*)
