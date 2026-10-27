;;; angler.el --- Copy transpiled Erlang regions -*- lexical-binding: t; -*-

;;; Commentary:
;; Load this file from Erlang mode and run M-x angler-copy-snippet.

;;; Code:

(defgroup angler nil "Angler syntax extensions for Erlang." :group 'languages)

(defcustom angler-program "angler"
  "Angler executable used to transpile snippets."
  :type 'file :group 'angler)

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
