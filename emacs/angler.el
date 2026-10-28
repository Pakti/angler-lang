;;; angler.el --- Major mode and snippet commands for Angler -*- lexical-binding: t; -*-

;;; Commentary:
;; Load this file to associate .erlx with angler-mode.  The Erlang
;; distribution's erlang.el must be on load-path when enabling the mode.
;; The snippet helper also works independently of the major mode.

;;; Code:

(defgroup angler nil "Angler syntax extensions for Erlang." :group 'languages)

(defcustom angler-program "angler"
  "Angler executable used to transpile snippets."
  :type 'file :group 'angler)


(defface angler-directive-face
  '((t (:inherit font-lock-preprocessor-face)))
  "Face for a top-level Angler directive."
  :group 'angler)

(defface angler-operator-face
  '((t (:inherit font-lock-keyword-face)))
  "Face for Angler annotation and record shorthand operators."
  :group 'angler)

(defface angler-field-face
  '((t (:inherit font-lock-variable-name-face)))
  "Face for an abbreviated record field."
  :group 'angler)

(defun angler--code-p (position)
  "Whether POSITION is outside comments, strings and character literals."
  (let ((state (save-excursion (syntax-ppss position))))
    (not (or (nth 3 state) (nth 4 state)
             (eq (char-before position) ?$)))))

(defun angler--form-start-p (position)
  "Whether POSITION begins a lexical top-level form."
  (and (= (car (save-excursion (syntax-ppss position))) 0)
       (save-excursion
         (goto-char position)
         (forward-comment (- (point-max)))
         (or (bobp) (eq (char-before) ?.)))))

(defun angler--match-directive (limit)
  "Match a top-level _export before LIMIT."
  (catch 'found
    (while (re-search-forward "\\_<_export\\_>" limit t)
      (let ((start (match-beginning 0)) (data (match-data)))
        (when (and (angler--code-p start) (angler--form-start-p start))
          (set-match-data data)
          (throw 'found t))))))

(defun angler--type-end (start limit)
  "Find the end of a type after START, bounded by LIMIT.
Track delimiters, including binary types.  Incomplete types end at LIMIT."
  (save-excursion
    (goto-char start)
    (let ((stack nil) (done nil))
      (while (and (< (point) limit) (not done))
        (let ((char (char-after)))
          (cond
           ((eq char ?$)
            (forward-char)
            (when (< (point) limit)
              (when (eq (char-after) ?\\) (forward-char))
              (when (< (point) limit) (forward-char))))
           ((eq char ?%)
            (forward-comment 1)
            (when (> (point) limit) (goto-char limit)))
           ((memq char '(?\" ?'))
            (goto-char (min limit (or (ignore-errors (scan-sexps (point) 1)) limit))))
           ((looking-at "<<") (push 'binary stack) (forward-char 2))
           ((and (eq (car stack) 'binary) (looking-at ">>"))
            (pop stack) (forward-char 2))
           ((memq char '(?\( ?\[ ?\{))
            (push (cdr (assq char '((?\( . ?\)) (?\[ . ?\]) (?\{ . ?\})))) stack)
            (forward-char))
           ((memq char '(?\) ?\] ?\}))
            (if (eq char (car stack)) (progn (pop stack) (forward-char))
              (setq done t)))
           ((and (null stack)
                 (or (memq char '(?, ?\; ?=))
                     (looking-at "->\\|\\_<when\\_>")))
            (setq done t))
           ((and (null stack) (eq char ?.))
            (if (looking-at "\\.\\.") (forward-char 2) (setq done t)))
           (t (forward-char)))))
      (min (point) limit))))

(defun angler--match-annotation (limit)
  "Match an annotation operator and type text before LIMIT."
  (catch 'found
    (while (re-search-forward "::" limit t)
      (let ((start (match-beginning 0)) (type-start (point)))
        (when (angler--code-p start)
          (let ((end (angler--type-end type-start limit)))
            (set-match-data (list start end start type-start type-start end))
            (goto-char end)
            (when (save-match-data
                    (save-excursion (goto-char start) (search-forward "\n" end t)))
              (put-text-property start end 'font-lock-multiline t))
            (throw 'found t)))))))

(defconst angler--variable-regexp "\\_<[[:upper:]_][[:alnum:]_@]*\\_>"
  "An Erlang variable, for finding record shorthand.")

(defun angler--match-record (limit)
  "Match a shorthand record operator and optional field before LIMIT."
  (catch 'found
    (while (re-search-forward angler--variable-regexp limit t)
      (let ((start (match-beginning 0)) (variable-end (point)))
        (when (and (angler--code-p start) (not (eq (char-before start) ??)))
          (let ((suffix
                 (save-excursion
                   (goto-char variable-end)
                   (forward-comment (point-max))
                   (let ((operator (point)))
                     (when (< operator limit)
                       (cond
                        ((eq (char-after) ?\{)
                         (list operator (1+ operator) nil nil))
                        ((eq (char-after) ?.)
                         (forward-char)
                         ;; No whitespace after the dot: it would end a form.
                         (when (looking-at "[[:lower:]][[:alnum:]_@]*\\|'\\(?:\\\\.\\|[^'\\\\]\\)*'")
                           (when (<= (match-end 0) limit)
                             (list operator (1+ operator) (point) (match-end 0)))))))))))
            (when suffix
              (let ((end (or (nth 3 suffix) (nth 1 suffix))))
                (set-match-data (append (list start end) suffix))
                (goto-char end)
                (throw 'found t)))))))))

(defconst angler--font-lock-keywords
  '((angler--match-directive (0 'angler-directive-face t))
    (angler--match-annotation
     (1 'angler-operator-face t)
     ;; Syntax fontification has already marked comments and quoted literals.
     ;; Keep those faces while applying type faces before Erlang lexical rules.
     (2 'font-lock-type-face keep))
    (angler--match-record
     (1 'angler-operator-face t)
     (2 'angler-field-face t t)))
  "Additional syntax highlighting for Angler buffers.")

;; Editing uses a same-width parser view, never transpiles the source buffer.
(require 'imenu)
(require 'cl-lib)

(defvar erlang-indent-level)
(defvar erlang-mode-hook)
(defvar erlang-electric-commands)
(declare-function erlang-calculate-indent "erlang")
(declare-function erlang-comment-indent "erlang")
(declare-function erlang-beginning-of-function "erlang" (&optional arg))
(declare-function erlang-end-of-function "erlang" (&optional arg))
(declare-function erlang-beginning-of-clause "erlang" (&optional arg))
(declare-function erlang-end-of-clause "erlang" (&optional arg))

(defun angler--layout-view (function)
  "Call FUNCTION in a temporary Erlang view of the current buffer.
Positions and line lengths initially match the source.  FUNCTION receives
an alist of type-continuation line numbers and indentation anchors."
  (let* ((position (point)) (minimum (point-min)) (maximum (point-max))
         (text (save-restriction (widen) (buffer-substring-no-properties (point-min) (point-max))))
         (options (mapcar (lambda (name) (cons name (and (boundp name) (symbol-value name))))
                          '(erlang-indent-level erlang-indent-guard erlang-argument-indent
                            erlang-icr-indent indent-tabs-mode tab-width comment-column))))
    (with-temp-buffer
      (insert text)
      ;; Editing a source buffer must not run user mode hooks on hidden views.
      (let ((erlang-mode-hook nil) (prog-mode-hook nil)
            (after-change-major-mode-hook nil) (change-major-mode-hook nil))
        (erlang-mode))
      (dolist (option options) (set (make-local-variable (car option)) (cdr option)))
      (let ((case-fold-search nil) (masks nil) (continuations nil))
        (goto-char (point-min))
        (while (angler--match-annotation (point-max))
          (let* ((start (match-beginning 0)) (end (match-end 0))
                 (anchor (copy-marker
                          (save-excursion
                            (goto-char start)
                            (forward-comment (- (point-max)))
                            (if (and (eq (char-before) ?\)) (= (car (save-excursion (syntax-ppss start))) 0))
                                (progn (goto-char (or (ignore-errors (scan-sexps (point) -1)) start))
                                       (line-beginning-position))
                              start)))))
            (push (list start end ?\s) masks)
            (save-excursion
              (goto-char start)
              (forward-line 1)
              (while (< (point) end)
                (back-to-indentation)
                (when (< (point) end)
                  (let* ((opener (nth 1 (syntax-ppss)))
                         (inside (and opener (>= opener start)))
                         (close (memq (char-after) '(?\) ?\] ?\}))))
                    (push (cons (line-number-at-pos nil t)
                                (cons (if inside (copy-marker opener) anchor)
                                      (if inside (if close 0 1) 'level)))
                          continuations)))
                (forward-line 1)))))
        (goto-char (point-min))
        (while (angler--match-directive (point-max))
          (push (list (match-beginning 0) (match-end 0) ?\s) masks))
        (goto-char (point-min))
        (while (angler--match-record (point-max))
          (let ((start (match-beginning 0)) (operator (match-beginning 1)))
            (if (eq (char-after operator) ?.)
                (push (list operator (1+ operator) ?_) masks)
              ;; A same-width map prefix stands in for a shorthand update.
              (save-excursion
                (goto-char start)
                (skip-syntax-forward "w_")
                (push (list start (point) ?\s) masks)
                (push (list start (1+ start) ?#) masks)))))
        ;; Leading whitespace inside multiline strings/quoted atoms is data.
        (save-excursion
          (goto-char (point-min))
          (while (not (eobp))
            (when (nth 3 (syntax-ppss))
              (push (cons (line-number-at-pos nil t) (cons 'preserve (current-indentation)))
                    continuations))
            (forward-line 1)))
        ;; Compute comment positions against the original view before masking
        ;; types: preserve comments, whitespace, newlines, and all coordinates.
        (let ((changes (make-hash-table :test #'eql)))
          (dolist (mask (reverse masks))
            (let ((start (nth 0 mask)) (end (nth 1 mask)) (replacement (nth 2 mask)))
              (save-excursion
                (goto-char start)
                (while (< (point) end)
                  (unless (or (memq (char-after) '(?\s ?\t ?\n ?\r))
                              (nth 4 (syntax-ppss))
                              (and (eq (char-after) ?%) (nth 4 (save-excursion (syntax-ppss (1+ (point)))))))
                    (puthash (point) replacement changes))
                  (forward-char)))))
          (maphash (lambda (pos char)
                     (goto-char pos)
                     (delete-char 1)
                     (insert-char char)) changes))
        (narrow-to-region minimum maximum)
        (goto-char position)
        (funcall function continuations)))))

(defun angler--view-indentation (continuations)
  "Calculate indentation in a parser view using CONTINUATIONS."
  (let ((type-line (cdr (assq (line-number-at-pos nil t) continuations))))
    (cond
     ((eq (car type-line) 'preserve) (cdr type-line))
     (type-line
        (save-excursion
          (goto-char (car type-line))
          (if (eq (cdr type-line) 'level)
              (+ (current-indentation) erlang-indent-level)
            (+ (current-column) (cdr type-line)))))
     (t
      (condition-case nil
          (if (save-excursion (back-to-indentation) (eq (char-after) ?%))
              (erlang-comment-indent)
            (let ((value (save-excursion (back-to-indentation) (erlang-calculate-indent))))
              (if (integerp value) value (current-indentation))))
        (error (current-indentation)))))))

(defun angler-indent-region (begin end &optional column)
  "Indent source lines from BEGIN to END without changing Angler syntax.
Reuse Erlang indentation in a masked view.  If COLUMN is supplied, use it."
  (interactive "r")
  (let ((columns
         (save-excursion
           (goto-char begin)
           (angler--layout-view
            (lambda (continuations)
              (let ((stop (copy-marker end)) (result nil))
                (beginning-of-line)
                (while (< (point) stop)
                  (let ((indent (or column (angler--view-indentation continuations))))
                    (push indent result)
                    (delete-horizontal-space)
                    (indent-to indent))
                  (forward-line 1))
                (nreverse result)))))))
    (save-excursion
      (goto-char begin)
      (beginning-of-line)
      (dolist (indent columns)
        (delete-horizontal-space)
        (indent-to indent)
        (forward-line 1)))))

(defun angler-indent-line ()
  "Indent the current Angler line, preserving point relative to its text."
  (interactive)
  (let ((offset (- (point-max) (point)))
        (indent (angler--layout-view
                 (lambda (continuations)
                   (beginning-of-line)
                   (angler--view-indentation continuations)))))
    (save-excursion
      (beginning-of-line)
      (delete-horizontal-space)
      (indent-to indent))
    (goto-char (max (save-excursion (back-to-indentation) (point))
                    (- (point-max) offset)))))

(defvar erlang-atom-regexp)
(declare-function erlang-get-arity "erlang")

(defun angler--view-clauses (start end)
  "Find top-level clause pairs between START and END in an Erlang view."
  (save-excursion
    (goto-char start)
    (let ((clauses nil) (clause start) (blocks 0) (body nil))
      (while (re-search-forward "\\_<\\(?:case\\|if\\|receive\\|try\\|begin\\|maybe\\|fun\\|end\\)\\_>\\|->\\|;" end t)
        (let ((token (match-string-no-properties 0)) (pos (match-beginning 0)))
          (when (angler--code-p pos)
            (cond
             ((equal token "end") (setq blocks (max 0 (1- blocks))))
             ((member token '("case" "if" "receive" "try" "begin" "maybe"))
              (setq blocks (1+ blocks)))
             ((equal token "fun")
              (when (save-excursion
                      (forward-comment (point-max))
                      (or (eq (char-after) ?\()
                          (looking-at "[[:upper:]_][[:alnum:]_@]*[ \t\n]*(")))
                (setq blocks (1+ blocks))))
             ((and (= blocks 0) (= (car (save-excursion (syntax-ppss pos))) 0))
              (if (equal token "->") (setq body t)
                (when body
                  (push (cons clause (point)) clauses)
                  (forward-comment (point-max))
                  (setq clause (point) body nil))))))))
      (nreverse (cons (cons clause end) clauses)))))

(defun angler--view-functions ()
  "Describe lexical function forms in a masked Erlang buffer.
Form terminators distinguish functions from clauses and nested fun bodies,
without assuming that the source is already correctly indented."
  (save-excursion
    (goto-char (point-min))
    (let ((start (point-min)) (forms nil) (functions nil))
      (while (re-search-forward "\\.\\(?:[ \t\r\n%]\\|\\'\\)" nil t)
        (let ((dot (match-beginning 0)))
          (when (and (angler--code-p dot) (= (car (save-excursion (syntax-ppss dot))) 0))
            (push (cons start (1+ dot)) forms)
            (setq start (1+ dot)))))
      (when (< start (point-max)) (push (cons start (point-max)) forms))
      (dolist (form (nreverse forms))
        (goto-char (car form))
        (forward-comment (point-max))
        (let ((position (point)))
          (when (and (< position (cdr form))
                     (looking-at (concat erlang-atom-regexp "[ \t\n]*(")))
            (let ((name (match-string-no-properties 1))
                  (arguments (match-end 0)))
              (unless (equal name "fun")
                (goto-char arguments)
                (let ((arity (erlang-get-arity)))
                  (when (integerp arity)
                    (push (list :name (format "%s/%d" name arity)
                                :start position :end (cdr form)
                                :clauses (angler--view-clauses position (cdr form)))
                          functions))))))))
      (nreverse functions))))

(defun angler--navigate (kind count)
  "Move through KIND positions with COUNT using a masked parser view."
  (let* ((count (or count 1))
         (result
          (angler--layout-view
           (lambda (_)
             (let* ((functions (angler--view-functions))
                    (positions
                     (if (memq kind '(clause-start clause-end))
                         (let ((pairs (apply #'append (mapcar (lambda (f) (plist-get f :clauses)) functions))))
                           (mapcar (if (eq kind 'clause-start) #'car #'cdr) pairs))
                       (mapcar (lambda (f) (plist-get f (if (eq kind 'start) :start :end))) functions)))
                    (forward (if (memq kind '(start clause-start)) (< count 0) (> count 0)))
                    (remaining (abs count)) (found t))
               (while (and found (> remaining 0))
                 (let ((next (if forward
                                 (car (cl-member-if (lambda (p) (> p (point))) positions))
                               (car (cl-member-if (lambda (p) (< p (point))) (reverse positions))))))
                   (if next (goto-char next)
                     (goto-char (if forward (point-max) (point-min)))
                     (setq found nil)))
                 (setq remaining (1- remaining)))
               (cons found (point)))))))
    (goto-char (cdr result))
    (car result)))

(defun angler-beginning-of-function (&optional arg)
  "Move to an Angler function head, with optional repeat count ARG.
Negative ARG moves forward.  Directives and specs stay before the head."
  (interactive "p")
  (angler--navigate 'start arg))

(defun angler-end-of-function (&optional arg)
  "Move to an Angler function end, with optional repeat count ARG."
  (interactive "p")
  (angler--navigate 'end arg))

(defun angler-beginning-of-clause (&optional arg)
  "Move to an Angler clause beginning with repeat count ARG."
  (interactive "p")
  (angler--navigate 'clause-start arg))

(defun angler-end-of-clause (&optional arg)
  "Move to an Angler clause end with repeat count ARG."
  (interactive "p")
  (angler--navigate 'clause-end arg))

(defun angler-indent-function ()
  "Indent the current Angler function without rewriting extended syntax."
  (interactive)
  (let ((start (save-excursion
                 (unless (eobp) (forward-char))
                 (when (angler-beginning-of-function) (point)))))
    (unless start (user-error "No Angler function at point"))
    (save-excursion
      (goto-char start)
      (angler-end-of-function)
      (angler-indent-region start (point)))))

(defun angler-mark-clause ()
  "Select the current Angler clause."
  (interactive)
  (let ((start (save-excursion
                 (unless (eobp) (forward-char))
                 (when (angler-beginning-of-clause) (point)))))
    (unless start (user-error "No Angler clause at point"))
    (goto-char start)
    (let ((end (save-excursion (angler-end-of-clause) (point))))
      (push-mark end nil t))))

(defun angler-imenu-create-index ()
  "Index name/arity entries with live markers in the source buffer."
  (let ((index (angler--layout-view
                (lambda (_)
                  (mapcar (lambda (f) (cons (plist-get f :name) (plist-get f :start)))
                          (angler--view-functions))))))
    (mapcar (lambda (entry) (cons (car entry) (copy-marker (cdr entry)))) index)))

;; Load the parent on demand so copying a snippet does not require erlang.el.
(autoload 'erlang-mode "erlang" "Major mode for Erlang source." t)

;;;###autoload
(define-derived-mode angler-mode erlang-mode "Angler"
  "Major mode for Angler source, based on the installed Erlang mode.
Run `erlang-mode-hook' followed by `angler-mode-hook'.  This initial
mode adds Angler highlighting, indentation and navigation while reusing
Erlang mode on a temporary parser view.  Source syntax is never rewritten."
  (font-lock-add-keywords nil angler--font-lock-keywords 'prepend)
  (setq-local indent-line-function #'angler-indent-line)
  (setq-local indent-region-function #'angler-indent-region)
  (setq-local beginning-of-defun-function #'angler-beginning-of-function)
  (setq-local end-of-defun-function #'angler-end-of-function)
  (setq-local imenu-create-index-function #'angler-imenu-create-index)
  ;; Parent electric punctuation calls its parser directly, bypassing our
  ;; indentation functions and sometimes cloning invalid typed clause heads.
  ;; Keep ordinary insertion and bit-syntax pairing; use TAB/RET to indent.
  (setq-local erlang-electric-commands nil))

(define-key angler-mode-map (kbd "TAB") #'indent-for-tab-command)
(define-key angler-mode-map (kbd "RET") #'newline-and-indent)
(define-key angler-mode-map (kbd "C-c M-a") #'angler-beginning-of-clause)
(define-key angler-mode-map (kbd "C-c M-e") #'angler-end-of-clause)
(define-key angler-mode-map (kbd "C-c M-h") #'angler-mark-clause)
(define-key angler-mode-map (kbd "C-c C-q") #'angler-indent-function)

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.erlx\\'" . angler-mode))

;;;###autoload
(defun angler-copy-snippet (begin end)
  "Transpile the region from BEGIN to END and copy it to the kill ring.
Leave the source buffer unchanged.  On failure display diagnostics and
leave the kill ring unchanged.  Requires an active region interactively."
  (interactive (progn
                 (unless (use-region-p) (user-error "Select an Erlang region first"))
                 (list (region-beginning) (region-end))))
  (let ((source (current-buffer))
        (errors (make-temp-file "angler-errors-"))
        (coding-system-for-write 'utf-8-unix)
        (coding-system-for-read 'utf-8-unix))
    (unwind-protect
        (with-temp-buffer
          (let* ((output (current-buffer))
                 (status (with-current-buffer source
                           (call-process-region begin end angler-program nil
                                                (list output errors) nil "snippet"))))
            (if (and (integerp status) (zerop status))
                (progn (kill-new (buffer-string))
                       (message "Transpiled snippet copied"))
              (let ((diagnostics (get-buffer-create "*Angler diagnostics*")))
                (with-current-buffer diagnostics
                  (let ((inhibit-read-only t))
                    (erase-buffer)
                    (insert-file-contents errors)
                    (special-mode)))
                (display-buffer diagnostics)
                (user-error "Angler snippet failed (status %s)" status)))))
      (delete-file errors))))

(provide 'angler)
;;; angler.el ends here
