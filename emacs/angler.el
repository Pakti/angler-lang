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

(require 'compile)
(require 'comint)
(require 'project)
(require 'subr-x)

(defcustom angler-shell-buffer nil
  "Preferred live Erlang shell buffer name, or nil to select a shell.
This may be set buffer-locally for projects using different shells."
  :type '(choice (const :tag "Select automatically" nil) string) :group 'angler)

(defcustom angler-project-root nil
  "Explicit root for project builds, or nil to discover it.
Discovery prefers a containing src_ex directory, then the Emacs project
root, a containing rebar.config, and finally default-directory."
  :type '(choice (const :tag "Discover" nil) directory) :group 'angler)

(defcustom angler-build-arguments nil
  "Additional CLI arguments for project builds, e.g. --input or --delete.
Arguments are passed separately and shell quoted, never interpreted as code."
  :type '(repeat string) :group 'angler)

(defcustom angler-warnings-as-errors nil
  "Whether editor commands should pass --warnings-as-errors to Angler."
  :type 'boolean :group 'angler)

(defconst angler--diagnostic-regexp
  "^\\(.+?\\):[ \t]*\\([0-9]+\\):\\([0-9]+\\):[ \t]*\\(warning:\\)?"
  "Source diagnostic format emitted by Angler.")

(add-to-list 'compilation-error-regexp-alist-alist
             `(angler ,angler--diagnostic-regexp 1 2 3 (4)))
(add-to-list 'compilation-error-regexp-alist-alist
             '(angler-build "^\\(.+?\\):[ \t]*{\\([0-9]+\\),\\([0-9]+\\)}:" 1 2 3))

(define-compilation-mode angler-compilation-mode "Angler compilation"
  "Compilation mode for Angler source diagnostics and build output."
  (setq-local compilation-error-regexp-alist
              (append '(angler angler-build) compilation-error-regexp-alist))
  ;; erl_scan reports character columns, not expanded screen/tab columns.
  (setq-local compilation-error-screen-columns nil))

(defun angler--active-region ()
  "Return active region bounds or signal an actionable error."
  (unless (use-region-p) (user-error "Select an Angler expression region first"))
  (list (region-beginning) (region-end)))

(defun angler--diagnostics (text source)
  "Display diagnostic TEXT associated with SOURCE without editing it."
  (let ((buffer (get-buffer-create "*Angler diagnostics*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        ;; Leave next-error before the first message, as compilation buffers do.
        (insert "Angler diagnostics\n\n" text)
        (goto-char (point-min)))
      (if (buffer-local-value 'buffer-file-name source)
          (progn
            (angler-compilation-mode)
            (setq-local default-directory (buffer-local-value 'default-directory source))
            (setq next-error-last-buffer buffer))
        ;; Unsaved buffers have no file for next-error to visit.
        (special-mode)))
    (display-buffer buffer)))

(defun angler--source-diagnostics (text input source begin)
  "Map INPUT diagnostics in TEXT to SOURCE starting at BEGIN."
  (let* ((label (or (buffer-local-value 'buffer-file-name source)
                    (format "<buffer %s>" (buffer-name source))))
         (line (with-current-buffer source (line-number-at-pos begin t)))
         (column (with-current-buffer source
                   (save-restriction
                     (widen)
                     (save-excursion (goto-char begin) (- begin (line-beginning-position)))))))
    (replace-regexp-in-string
     (concat "^" (regexp-quote input) ":[ \t]*\\([0-9]+\\):\\([0-9]+\\):")
     (lambda (match)
       (save-match-data
       (string-match ":[ \t]*\\([0-9]+\\):\\([0-9]+\\):\\'" match)
       (let ((relative-line (string-to-number (match-string 1 match)))
             (relative-column (string-to-number (match-string 2 match))))
         (format "%s: %d:%d:" label (+ line relative-line -1)
                 (+ relative-column (if (= relative-line 1) column 0))))))
     text t t)))

(defun angler--transform-region (command begin end)
  "Run Angler COMMAND on BEGIN..END and return successful output.
Keep source, kill ring, and output buffers unchanged on failure."
  (let* ((source (current-buffer))
         (errors (make-temp-file "angler-errors-"))
         (input (when (equal command "transpile") (make-temp-file "angler-buffer-" nil ".erlx")))
         (coding-system-for-write 'utf-8-unix)
         (coding-system-for-read 'utf-8-unix)
         (arguments (append (list command "--encoding" "utf8")
                            (when angler-warnings-as-errors '("--warnings-as-errors"))
                            (when input (list input)))))
    (unwind-protect
        (condition-case err
            (with-temp-buffer
              (let* ((output (current-buffer))
                     (status (with-current-buffer source
                               (if input
                                   (progn
                                     (write-region begin end input nil 'silent)
                                     (apply #'call-process angler-program nil (list output errors) nil arguments))
                                 (apply #'call-process-region begin end angler-program nil
                                        (list output errors) nil arguments))))
                     (stderr (with-temp-buffer (insert-file-contents errors) (buffer-string)))
                     (diagnostics (angler--source-diagnostics stderr (or input "<stdin>") source begin)))
                (if (string-empty-p diagnostics)
                    (when-let ((old (get-buffer "*Angler diagnostics*")))
                      (with-current-buffer old
                        (let ((inhibit-read-only t)) (erase-buffer))
                        (special-mode)))
                  (angler--diagnostics diagnostics source))
                (unless (and (integerp status) (zerop status))
                  (when (string-empty-p diagnostics)
                    (angler--diagnostics (format "Angler %s failed (status %s)\n" command status) source))
                  (user-error "Angler %s failed (status %s)" command status))
                (buffer-string)))
          (file-error
           (angler--diagnostics (concat (error-message-string err) "\n") source)
           (user-error "Cannot run Angler: %s" (error-message-string err))))
      (delete-file errors)
      (when input (delete-file input)))))

;;;###autoload
(defun angler-copy-snippet (begin end)
  "Transpile BEGIN..END as expressions and copy output to the kill ring.
Leave the source unchanged, and preserve the kill ring on failure."
  (interactive (angler--active-region))
  (kill-new (angler--transform-region "snippet" begin end))
  (message "Transpiled snippet copied"))

;;;###autoload
(defun angler-transpile-buffer ()
  "Transpile current buffer text into a separate read-only Erlang buffer.
Unsaved edits are included without saving or changing the source file."
  (interactive)
  (let* ((name (format "*Angler transpilation: %s*" (buffer-name)))
         (coding buffer-file-coding-system)
         (output (save-restriction
                   (widen)
                   (angler--transform-region "transpile" (point-min) (point-max))))
         (buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert output)
        (erlang-mode)
        (setq-local buffer-file-coding-system coding)
        (setq buffer-read-only t)
        (set-buffer-modified-p nil)
        (goto-char (point-min))))
    (display-buffer buffer)
    buffer))

(defun angler--shell-buffers ()
  "Return live Erlang comint buffers; never start a process implicitly."
  (cl-remove-if-not
   (lambda (buffer)
     (with-current-buffer buffer
       (and (derived-mode-p 'erlang-shell-mode) (comint-check-proc buffer))))
   (buffer-list)))

(defun angler--read-shell ()
  "Read the name of an existing live Erlang shell."
  (let ((buffers (angler--shell-buffers)))
    (unless buffers (user-error "No live Erlang shell; start one with M-x erlang-shell"))
    (completing-read "Erlang shell: " (mapcar #'buffer-name buffers) nil t)))

(defun angler--select-shell (requested interactivep)
  "Choose REQUESTED shell, or a configured/live one, respecting INTERACTIVEP."
  (let* ((candidates (angler--shell-buffers))
         (choice (or requested angler-shell-buffer
                     (when (= (length candidates) 1) (car candidates)))))
    (unless choice
      (cond
       ((null candidates) (user-error "No live Erlang shell; start one with M-x erlang-shell"))
       (interactivep
        (setq choice (completing-read "Erlang shell: " (mapcar #'buffer-name candidates) nil t)))
       (t (user-error "Several Erlang shells are running; specify a shell buffer"))))
    (let ((buffer (get-buffer choice)))
      (unless (memq buffer candidates) (user-error "Not a live Erlang shell: %s" choice))
      buffer)))

;;;###autoload
(defun angler-send-snippet (begin end &optional shell-buffer)
  "Transpile BEGIN..END as expressions and send to SHELL-BUFFER.
With a prefix argument, choose the shell explicitly.  Refuse pending shell
input and never send anything if transpilation fails."
  (interactive (append (angler--active-region)
                       (list (when current-prefix-arg
                               (angler--read-shell)))))
  (let* ((output (angler--transform-region "snippet" begin end))
         (shell (angler--select-shell shell-buffer (called-interactively-p 'interactive))))
    (with-current-buffer shell
      (let ((process (get-buffer-process shell)))
        (unless (and process (process-live-p process)) (user-error "Erlang shell exited"))
        (unless (= (marker-position (process-mark process)) (point-max))
          (user-error "Erlang shell has pending input; finish or clear it first"))
        (goto-char (point-max))
        (insert output)
        (comint-send-input nil t)))
    (display-buffer shell)))

(defun angler--build-root ()
  "Find the root to use for a project build."
  (file-name-as-directory
   (expand-file-name
    (or angler-project-root
        (locate-dominating-file default-directory
                                (lambda (dir) (file-directory-p (expand-file-name "src_ex" dir))))
        (when-let ((project (project-current nil))) (project-root project))
        (locate-dominating-file default-directory "rebar.config")
        default-directory))))

;;;###autoload
(defun angler-build (&optional directory)
  "Run a project build asynchronously through compilation-mode.
With a prefix argument, choose DIRECTORY.  Builds read files on disk;
this command does not save buffers or add deletion flags automatically."
  (interactive (list (when current-prefix-arg (read-directory-name "Angler project: "))))
  (let* ((default-directory (or (and directory (file-name-as-directory (expand-file-name directory)))
                                (angler--build-root)))
         (arguments (append '("build") angler-build-arguments
                            (when angler-warnings-as-errors '("--warnings-as-errors"))))
         (command (mapconcat #'shell-quote-argument (cons angler-program arguments) " ")))
    (compilation-start command #'angler-compilation-mode)))

(define-key angler-mode-map (kbd "C-c C-r") #'angler-copy-snippet)
(define-key angler-mode-map (kbd "C-c C-e") #'angler-send-snippet)
(define-key angler-mode-map (kbd "C-c C-t") #'angler-transpile-buffer)
(define-key angler-mode-map (kbd "C-c C-k") #'angler-build)

(provide 'angler)
;;; angler.el ends here
