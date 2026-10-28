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

;; Load the parent on demand so copying a snippet does not require erlang.el.
(autoload 'erlang-mode "erlang" "Major mode for Erlang source." t)

;;;###autoload
(define-derived-mode angler-mode erlang-mode "Angler"
  "Major mode for Angler source, based on the installed Erlang mode.
Run `erlang-mode-hook' followed by `angler-mode-hook'.  This initial
mode adds Angler highlighting and inherits Erlang indentation, navigation
and bindings.  Angler-specific indentation/navigation adjustments are planned."
  (font-lock-add-keywords nil angler--font-lock-keywords 'prepend))

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
