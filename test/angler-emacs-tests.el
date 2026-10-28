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

(defun angler-test--faces (text &optional offset)
  "Return faces on TEXT in the current buffer, at optional OFFSET."
  (save-excursion
    (goto-char (point-min))
    (search-forward text)
    (let ((face (get-text-property (+ (- (point) (length text)) (or offset 0)) 'face)))
      (if (listp face) face (list face)))))

(ert-deftest angler-highlights-directives-only-at-form-start ()
  (with-temp-buffer
    (insert "-module(m).\n% comment\n_export\nf()-> _export = ok, _export.\n_export\ng()->ok.")
    (angler-mode)
    (font-lock-ensure)
    (should (memq 'angler-directive-face (angler-test--faces "_export")))
    (should-not (memq 'angler-directive-face (angler-test--faces "_export =")))
    (should-not (memq 'angler-directive-face (angler-test--faces "_export.")))
    (should (memq 'angler-directive-face (angler-test--faces "_export\ng")))))

(ert-deftest angler-highlights-annotations-and-boundaries ()
  (with-temp-buffer
    (insert "f(P :: #person{}, N :: integer() | undefined) :: {ok, remote:t()}\n"
            "  when is_integer(N) -> A :: #address{} = P.address, {A.city,N}.")
    (angler-mode)
    (font-lock-ensure)
    (should (memq 'angler-operator-face (angler-test--faces "::")))
    (dolist (text '("person" "undefined" "remote" "address{}"))
      (should (memq 'font-lock-type-face (angler-test--faces text))))
    (should-not (memq 'font-lock-type-face (angler-test--faces "when")))
    (should-not (memq 'font-lock-type-face (angler-test--faces "is_integer")))
    (should (memq 'angler-field-face (angler-test--faces "address,")))
    (should (memq 'angler-field-face (angler-test--faces "city")))))

(ert-deftest angler-highlights-multiline-nested-types ()
  (with-temp-buffer
    (insert "f(F :: fun((integer(), <<_:8, _:_*8>>) -> {ok, atom()}),\n"
            "  P :: % comment :: P.name\n"
            "  #person{age :: 0..120}) :: integer() when true -> 42.")
    (angler-mode)
    ;; Exercise chunked fontification starting in the middle of a type.
    (font-lock-ensure (point-min) 20)
    (font-lock-ensure 20 (point-max))
    ;; Erlang mode gives predefined types their inherited builtin face.
    (should (cl-intersection '(font-lock-type-face font-lock-builtin-face)
                             (angler-test--faces "atom()")))
    (should (memq 'font-lock-type-face (angler-test--faces "person")))
    (should (memq 'font-lock-comment-face (angler-test--faces "comment")))
    (should-not (memq 'angler-field-face (angler-test--faces "name")))
    (should-not (memq 'font-lock-type-face (angler-test--faces "42")))))

(ert-deftest angler-highlighting-skips-comments-strings-and-atoms ()
  (with-temp-buffer
    (insert "% _export P.name P{age=1} :: integer()\n"
            "f()->\"_export Q.name Q{age=1} :: atom()\", '_export', '$::'.")
    (angler-mode)
    (font-lock-ensure)
    (dolist (text '("_export P" "P.name" "P{age" ":: integer" "_export Q" "Q.name" "Q{age" ":: atom" "'_export'"))
      (dotimes (offset (length text))
        (let ((faces (angler-test--faces text offset)))
          (should-not (memq 'angler-directive-face faces))
          (should-not (memq 'angler-operator-face faces))
          (should-not (memq 'angler-field-face faces)))))))

(ert-deftest angler-highlights-record-shorthand ()
  (with-temp-buffer
    (insert "f(P) -> P.name, P{age = P.age + 1}, P.'display name',\n"
            "P % access comment\n .city, P#person.age, P?RECORD.age, ?VALUE.age.")
    (angler-mode)
    (font-lock-ensure)
    (should (memq 'angler-operator-face (angler-test--faces ".name")))
    (should (memq 'angler-field-face (angler-test--faces "name")))
    (should (memq 'angler-operator-face (angler-test--faces "P{age" 1)))
    (should (memq 'angler-field-face (angler-test--faces "'display name'")))
    (should (memq 'angler-field-face (angler-test--faces "city")))
    (dolist (text '("P#person.age" "P?RECORD.age" "?VALUE.age"))
      (should-not (memq 'angler-field-face (angler-test--faces text (1- (length text))))))))

(ert-deftest angler-highlighting-is-local-to-mode ()
  (let ((source "_export\nf(P :: #person{}) -> P.name."))
    (with-temp-buffer
      (insert source)
      (angler-mode)
      (font-lock-ensure)
      (should (memq 'angler-directive-face (angler-test--faces "_export"))))
    (with-temp-buffer
      (insert source)
      (erlang-mode)
      (font-lock-ensure)
      (should-not (memq 'angler-directive-face (angler-test--faces "_export")))
      (should-not (memq 'angler-field-face (angler-test--faces "name"))))))

(ert-deftest angler-highlighting-updates-after-editing ()
  (with-temp-buffer
    (insert "f(P :: #person{}) -> P.name.")
    (angler-mode)
    (font-lock-ensure)
    (should (memq 'angler-field-face (angler-test--faces "name")))
    (goto-char (point-min))
    (insert "% ")
    (font-lock-flush)
    (font-lock-ensure)
    (should (memq 'font-lock-comment-face (angler-test--faces "name")))
    (should-not (memq 'angler-field-face (angler-test--faces "name")))
    (delete-region (point-min) (+ (point-min) 2))
    (font-lock-flush)
    (font-lock-ensure)
    (should (memq 'angler-field-face (angler-test--faces "name")))))

(ert-deftest angler-highlighting-handles-incomplete-code ()
  (dolist (source '("_export\nf(P :: #person{" "f(X :: fun((integer()) ->" "f(P)->P{" "f(X :: $)) -> X."))
    (with-temp-buffer
      (insert source)
      (angler-mode)
      (set-buffer-modified-p nil)
      (font-lock-ensure)
      (should (equal source (buffer-string)))
      (should-not (buffer-modified-p)))))
