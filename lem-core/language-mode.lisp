(defpackage :lem.language-mode
  (:use :cl :lem :lem.sourcelist)
  (:export
   :*language-mode-keymap*
   :beginning-of-defun-function
   :end-of-defun-function
   :line-comment
   :insertion-line-comment
   :find-definitions-function
   :find-references-function
   :completion-function
   :language-mode
   :go-to-location
   :indent
   :newline-and-indent
   :indent-region
   :make-xref-location
   :make-xref-references
   :xref-location-filespec
   :xref-location-position
   :xref-location-title
   :xref-references-type
   :xref-references-locations
   :filespec-to-buffer
   :filespec-to-filename))
(in-package :lem.language-mode)

(define-editor-variable beginning-of-defun-function nil)
(define-editor-variable end-of-defun-function nil)
(define-editor-variable line-comment nil)
(define-editor-variable insertion-line-comment nil)
(define-editor-variable find-definitions-function nil)
(define-editor-variable find-references-function nil)
(define-editor-variable completion-function nil)

(defun prompt-for-symbol (prompt history-name)
  (prompt-for-line prompt "" nil nil history-name))

(define-major-mode language-mode ()
    (:keymap *language-mode-keymap*)
  nil)

(define-key *language-mode-keymap* "C-M-a" 'beginning-of-defun)
(define-key *language-mode-keymap* "C-M-e" 'end-of-defun)
(define-key *language-mode-keymap* "C-i" 'indent-line-and-complete-symbol)
(define-key *language-mode-keymap* "C-j" 'newline-and-indent)
(define-key *language-mode-keymap* "M-j" 'newline-and-indent)
(define-key *language-mode-keymap* "C-M-\\" 'indent-region)
(define-key *language-mode-keymap* "M-;" 'comment-or-uncomment-region)
(define-key *language-mode-keymap* "M-." 'find-definitions)
(define-key *language-mode-keymap* "M-_" 'find-references)
(define-key *language-mode-keymap* "M-?" 'find-references)
(define-key *language-mode-keymap* "M-," 'pop-definition-stack)

(defun beginning-of-defun-1 (n)
  (alexandria:when-let ((fn (variable-value 'beginning-of-defun-function :buffer)))
    (when fn (funcall fn (current-point) n))))

(define-command beginning-of-defun (n) ("p")
  (if (minusp n)
      (end-of-defun (- n))
      (beginning-of-defun-1 n)))

(define-command end-of-defun (n) ("p")
  (if (minusp n)
      (beginning-of-defun (- n))
      (alexandria:if-let ((fn (variable-value 'end-of-defun-function :buffer)))
        (funcall fn (current-point) n)
        (beginning-of-defun-1 (- n)))))

(define-command indent (&optional (n 1)) ("p")
  (if (variable-value 'calc-indent-function)
      (indent-line (current-point))
      (self-insert n)))

(define-command newline-and-indent (n) ("p")
  (newline n)
  (indent))

(define-command indent-region (start end) ("r")
  (save-excursion
    (apply-region-lines start end 'indent-line)))

(defun space*-p (point)
  (with-point ((point point))
    (skip-whitespace-forward point t)
    (end-line-p point)))

(defun indentation-point-p (point)
  (with-point ((p point))
    (back-to-indentation p)
    (point<= point p)))

(define-command comment-or-uncomment-region () ()
  (if (commented-region-p)
      (uncomment-region)
      (comment-region)))

(defun set-region-point (start end)
  (cond
    ((buffer-mark-p (current-buffer))
     (move-point start (region-beginning))
     (move-point end (region-end)))
    (t
     (line-start start)
     (line-end end))))

(defun commented-region-p ()
  (let ((line-comment (variable-value 'line-comment :buffer)))
    (with-point ((start (current-point))
                 (end (current-point)))
      (set-region-point start end)
      (loop
        (skip-whitespace-forward start)
        (when (point>= start end)
          (return t))
        (unless (looking-at start line-comment)
          (return nil))
        (unless (line-offset start 1)
          (return t))))))

(define-command comment-region () ()
  (let ((line-comment (or (variable-value 'insertion-line-comment :buffer)
                          (variable-value 'line-comment :buffer))))
    (when line-comment
      (save-excursion
        (with-point ((start (current-point) :right-inserting)
                     (end (current-point) :left-inserting))
          (set-region-point start end)
          (skip-whitespace-forward start)
          (when (point>= start end)
            (insert-string (current-point) line-comment)
            (return-from comment-region))
          (let ((charpos (point-charpos start)))
            (loop
              (when (same-line-p start end)
                (cond ((space*-p start))
                      ((indentation-point-p end))
                      (t
                       (insert-string start line-comment)
                       (unless (space*-p end)
                         (insert-character end #\newline))))
                (return))
              (unless (space*-p start)
                (insert-string start line-comment))
              (line-offset start 1 charpos))))))))

(define-command uncomment-region () ()
  (let ((line-comment (variable-value 'line-comment :buffer))
        (insertion-line-comment (variable-value 'insertion-line-comment :buffer)))
    (when line-comment
      (with-point ((start (current-point) :right-inserting)
                   (end (current-point) :right-inserting))
        (set-region-point start end)
        (let ((p start))
          (loop
            (parse-partial-sexp p end nil t)
            (when (looking-at p line-comment)
              (let ((res (looking-at p insertion-line-comment)))
                (if res
                    (delete-character p (length res))
                    (loop :while (looking-at p line-comment)
                          :do (delete-character p (length line-comment))))))
            (unless (line-offset p 1) (return))))))))

(define-attribute xref-headline-attribute
  (t :bold-p t))

(define-attribute xref-title-attribute
  (:dark :foreground "cyan" :bold-p t)
  (:light :foreground "blue" :bold-p t))

(defstruct xref-location
  (filespec nil :read-only t :type (or buffer string pathname))
  (position 1 :read-only t :type integer)
  (title "" :read-only t :type string))

(defstruct xref-references
  (type nil :read-only t)
  (locations nil :read-only t))

(defun filespec-to-buffer (filespec)
  (etypecase filespec
    (buffer filespec)
    (string (find-file-buffer filespec))
    (pathname (find-file-buffer filespec))))

(defun filespec-to-filename (filespec)
  (etypecase filespec
    (buffer (buffer-filename filespec))
    (string filespec)
    (pathname (namestring filespec))))

(defun go-to-location (location &optional pop-to-buffer)
  (let ((buffer (filespec-to-buffer (xref-location-filespec location))))
    (if pop-to-buffer
        (setf (current-window) (pop-to-buffer buffer))
        (switch-to-buffer buffer))
    (move-to-position (current-point) (xref-location-position location))))

(define-command find-definitions () ()
  (alexandria:when-let (fn (variable-value 'find-definitions-function :buffer))
    (let ((locations (funcall fn)))
      (unless locations
        (editor-error "No definitions found"))
      (push-location-stack (current-point))
      (if (null (rest locations))
          (go-to-location (first locations))
          (let ((prev-file nil))
            (with-sourcelist (sourcelist "*definitions*")
              (dolist (location locations)
                (let ((file (filespec-to-filename (xref-location-filespec location)))
                      (title (xref-location-title location)))
                  (append-sourcelist sourcelist
                                     (lambda (p)
                                       (unless (equal prev-file file)
                                         (insert-string p file :attribute 'xref-headline-attribute)
                                         (insert-character p #\newline))
                                       (insert-string p (format nil "  ~A" title)
                                                      :attribute 'xref-title-attribute))
                                     (let ((location location))
                                       (lambda ()
                                         (go-to-location location))))
                  (setf prev-file file)))))))))

(define-command find-references () ()
  (alexandria:when-let (fn (variable-value 'find-references-function :buffer))
    (let ((refs (funcall fn)))
      (unless refs
        (editor-error "No references found"))
      (push-location-stack (current-point))
      (with-sourcelist (sourcelist "*references*")
        (dolist (ref refs)
          (let ((type (xref-references-type ref)))
            (append-sourcelist sourcelist
                               (lambda (p)
                                 (insert-string p (princ-to-string type)
                                                :attribute 'xref-headline-attribute))
                               nil)
            (dolist (location (xref-references-locations ref))
              (let ((title (xref-location-title location)))
                (append-sourcelist sourcelist
                                   (lambda (p)
                                     (insert-string p (format nil "  ~A" title)
                                                    :attribute 'xref-title-attribute))
                                   (let ((location location))
                                     (lambda ()
                                       (go-to-location location))))))))))))

(defvar *xref-stack-table* (make-hash-table :test 'equal))

(defun push-location-stack (point)
  (let ((buffer (point-buffer point)))
    (push (list (buffer-name buffer)
                (line-number-at-point point)
                (point-charpos point))
          (gethash (buffer-major-mode buffer) *xref-stack-table*))))

(define-command pop-definition-stack () ()
  (let ((elt (pop (gethash (buffer-major-mode (current-buffer))
                           *xref-stack-table*))))
    (when elt
      (destructuring-bind (buffer-name line-number charpos) elt
        (select-buffer buffer-name)
        (move-to-line (current-point) line-number)
        (line-offset (current-point) 0 charpos)))))

(defun complete-symbol ()
  (alexandria:when-let (fn (variable-value 'completion-function :buffer))
    (alexandria:when-let (completion-items (funcall fn))
      (run-completion completion-items
                      :auto-insert nil
                      :restart-function #'complete-symbol))))

(define-command indent-line-and-complete-symbol () ()
  (if (variable-value 'calc-indent-function :buffer)
      (let* ((p (current-point))
             (old (point-charpos p)))
        (let ((charpos (point-charpos p)))
          (handler-case (indent-line p)
            (editor-condition ()
              (line-offset p 0 charpos))))
        (when (= old (point-charpos p))
          (complete-symbol)))
      (complete-symbol)))
