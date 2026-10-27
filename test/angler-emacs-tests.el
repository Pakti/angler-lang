;;; angler-emacs-tests.el --- Emacs integration tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'angler)

(ert-deftest angler-copy-success ()
  (let ((angler-program (expand-file-name "bin/angler"))
        (kill-ring '("before")))
    (with-temp-buffer
      (insert "X = 40, X + 2.\n")
      (let ((original (buffer-string)))
        (angler-copy-snippet (point-min) (point-max))
        (should (equal original (car kill-ring)))
        (should (equal original (buffer-string)))))))

(ert-deftest angler-copy-unicode ()
  (let ((angler-program (expand-file-name "bin/angler"))
        (kill-ring nil))
    (with-temp-buffer
      (insert "\"café 🐟\".\n")
      (angler-copy-snippet (point-min) (point-max))
      (should (equal (buffer-string) (car kill-ring))))))

(ert-deftest angler-copy-failure ()
  (let ((angler-program (expand-file-name "bin/angler"))
        (kill-ring '("before")))
    (unwind-protect
        (with-temp-buffer
          (insert "P :: #person{} = get_person(), P.name.")
          (should-error (angler-copy-snippet (point-min) (point-max)) :type 'user-error)
          (should (equal kill-ring '("before")))
          (should (string-match-p "syntax error" (with-current-buffer "*Angler diagnostics*"
                                                  (buffer-string)))))
      (when (get-buffer "*Angler diagnostics*") (kill-buffer "*Angler diagnostics*")))))
