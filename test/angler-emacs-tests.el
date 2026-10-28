;;; angler-emacs-tests.el --- Emacs integration tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'angler)
(require 'erlang)

(ert-deftest angler-mode-inherits-erlang ()
  (with-temp-buffer
    (angler-mode)
    (should (eq major-mode 'angler-mode))
    (should (derived-mode-p 'erlang-mode))
    (should (derived-mode-p 'prog-mode))
    (should (equal mode-name "Angler"))
    (should (eq (keymap-parent (current-local-map)) erlang-mode-map))
    (let ((indent indent-line-function)
          (syntax (mapcar #'char-syntax '(?% ?\" ?_ ?\( ?\)))))
      (with-temp-buffer
        (erlang-mode)
        (should (eq indent-line-function indent))
        (should (equal syntax (mapcar #'char-syntax '(?% ?\" ?_ ?\( ?\)))))))))

(ert-deftest angler-mode-file-association ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/example.erlx")
    (set-auto-mode)
    (should (eq major-mode 'angler-mode)))
  (with-temp-buffer
    (setq buffer-file-name "/tmp/example.erl")
    (set-auto-mode)
    (should (eq major-mode 'erlang-mode))))

(ert-deftest angler-mode-hooks-and-local-settings ()
  (let* ((events nil)
         (default-indent (default-value 'erlang-indent-level))
         (erlang-mode-hook (list (lambda ()
                                   (setq events (append events '(erlang)))
                                   (setq-local erlang-indent-level 6))))
         (angler-mode-hook (list (lambda ()
                                   (setq events (append events '(angler)))
                                   (setq-local angler-program "buffer-specific-angler"))))
         (default-program (default-value 'angler-program)))
    (with-temp-buffer
      (angler-mode)
      (should (equal events '(erlang angler)))
      (should (local-variable-p 'erlang-indent-level))
      (should (= erlang-indent-level 6))
      (should (equal angler-program "buffer-specific-angler")))
    (should (= (default-value 'erlang-indent-level) default-indent))
    (should (equal (default-value 'angler-program) default-program))
    (setq events nil)
    (with-temp-buffer
      (erlang-mode)
      (should (equal events '(erlang)))
      (should (equal angler-program default-program)))))

(ert-deftest angler-mode-preserves-buffer ()
  (with-temp-buffer
    (insert "_export\nstart(P :: #person{}) -> P.name.\n")
    (set-buffer-modified-p nil)
    (let ((before (buffer-string)))
      (angler-mode)
      (should (equal (buffer-string) before))
      (should-not (buffer-modified-p)))))

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
          (insert "P.name.")
          (should-error (angler-copy-snippet (point-min) (point-max)) :type 'user-error)
          (should (equal kill-ring '("before")))
          (should (string-match-p "explicit record annotation" (with-current-buffer "*Angler diagnostics*"
                                                  (buffer-string)))))
      (when (get-buffer "*Angler diagnostics*") (kill-buffer "*Angler diagnostics*")))))

(ert-deftest angler-copy-record-snippet ()
  (let ((angler-program (expand-file-name "bin/angler"))
        (kill-ring nil))
    (with-temp-buffer
      (insert "P :: #person{} = get_person(), P.name.")
      (let ((original (buffer-string)))
        (angler-copy-snippet (point-min) (point-max))
        (should (string-match-p "P#person.name" (car kill-ring)))
        (should-not (string-match-p "::" (car kill-ring)))
        (should (equal original (buffer-string)))))))
