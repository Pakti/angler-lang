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
    (should (eq indent-line-function 'angler-indent-line))
    (let ((syntax (mapcar #'char-syntax '(?% ?\" ?_ ?\( ?\)))))
      (with-temp-buffer
        (erlang-mode)
        (should (eq indent-line-function 'erlang-indent-command))
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

(defun angler-test--indent (source mode)
  "Indent SOURCE with MODE using spaces and return its text."
  (with-temp-buffer
    (insert source)
    (funcall mode)
    (setq-local indent-tabs-mode nil)
    (indent-region (point-min) (point-max))
    (buffer-string)))

(ert-deftest angler-indents-typed-heads-and-clauses ()
  (let* ((source "    _export\nf(P :: #person{}) :: integer() when P.age > 0 ->\nP.age;\nf(P :: #person{}) :: integer() ->\nA :: #address{} = P.address,\nA.city.\n")
         (expected "_export\nf(P :: #person{}) :: integer() when P.age > 0 ->\n    P.age;\nf(P :: #person{}) :: integer() ->\n    A :: #address{} = P.address,\n    A.city.\n"))
    (should (equal expected (angler-test--indent source #'angler-mode)))
    (should (equal expected (angler-test--indent expected #'angler-mode)))))

(ert-deftest angler-indents-multiline-heads-and-nested-blocks ()
  (let* ((source "_export\nf(\nP :: #person{},\nN :: integer()\n) :: integer()\nwhen N > 0 ->\ncase P.age of\n0 -> N;\n_ -> 0\nend;\nf(P :: #person{}, N :: integer()) :: integer() ->\nN.\n")
         (expected "_export\nf(\n  P :: #person{},\n  N :: integer()\n ) :: integer()\n  when N > 0 ->\n    case P.age of\n        0 -> N;\n        _ -> 0\n    end;\nf(P :: #person{}, N :: integer()) :: integer() ->\n    N.\n"))
    (should (equal expected (angler-test--indent source #'angler-mode)))
    (should (equal expected (angler-test--indent expected #'angler-mode)))))

(ert-deftest angler-indents-multiline-types ()
  (let* ((source "f(P :: #person{\nage :: integer()\n}) ::\ninteger() ->\nP.age.\n")
         (once (angler-test--indent source #'angler-mode)))
    (should (string-match-p "\n    integer() ->\n    P.age" once))
    (should (equal once (angler-test--indent once #'angler-mode)))
    (should (equal (replace-regexp-in-string "^[ \t]+" "" source)
                   (replace-regexp-in-string "^[ \t]+" "" once)))))

(ert-deftest angler-preserves-erlang-indentation-for-native-code ()
  (dolist (source '("f() ->\nP = #person{\nage = 41\n},\ncase P#person.age of\n41 -> ok;\n_ -> error\nend.\n"
                    "f() ->\nF = fun(X) ->\nX + 1\nend,\nF(41).\n"))
    (should (equal (angler-test--indent source #'erlang-mode)
                   (angler-test--indent source #'angler-mode)))))

(ert-deftest angler-indentation-preserves-string-data ()
  (let* ((source "f(P :: #person{}) ->\nS = \"text\n  P.name :: #person{}\nend\",\n{S,P.name}.\n")
         (once (angler-test--indent source #'angler-mode)))
    (should (string-match-p (regexp-quote "\"text\n  P.name :: #person{}\nend\"") once))
    (should (equal once (angler-test--indent once #'angler-mode)))) )

(ert-deftest angler-indent-line-preserves-point-and-supports-empty-line ()
  (with-temp-buffer
    (insert "f(P :: #person{}) ->\nP.age.\n")
    (angler-mode)
    (setq-local indent-tabs-mode nil)
    (goto-char (point-min))
    (search-forward "P.a")
    (backward-char)
    (angler-indent-line)
    (should (looking-at "age"))
    (should (= (current-indentation) 4))
    (erase-buffer)
    (insert "f(P :: #person{}) ->\n")
    (angler-indent-line)
    (should (= (current-column) 4))))

(ert-deftest angler-indentation-respects-settings-without-extra-hooks ()
  (let* ((count 0) (erlang-mode-hook (list (lambda () (setq count (1+ count))))))
    (with-temp-buffer
      (insert "f(P :: #person{}) ->\nP.age.\n")
      (angler-mode)
      (setq-local erlang-indent-level 2)
      (setq-local indent-tabs-mode nil)
      (indent-region (point-min) (point-max))
      (goto-char (point-min))
      (forward-line 1)
      (should (= (current-indentation) 2))
      (angler-imenu-create-index)
      (should (= count 1)))))

(ert-deftest angler-layout-supports-narrowing-and-incomplete-input ()
  (with-temp-buffer
    (insert "before()->ok.\nf(P :: #person{}) ->\nP.age.\nafterward()->ok.\n")
    (angler-mode)
    (goto-char (point-min))
    (forward-line 1)
    (let ((start (point)))
      (forward-line 2)
      (narrow-to-region start (point)))
    (indent-region (point-min) (point-max))
    (goto-char (point-min))
    (forward-line 1)
    (should (= (current-indentation) 4)))
  (dolist (source '("_export\nf(P :: #person{" "f(X :: fun((integer()) ->" "f(P)->P{"))
    (with-temp-buffer
      (insert source)
      (angler-mode)
      (indent-region (point-min) (point-max))
      (angler-beginning-of-function)
      (angler-end-of-function)
      (angler-imenu-create-index))))

(defconst angler-test--navigation-source
  "-module(m).\n_export\nf(P :: #person{}) :: integer() ->\ncase P.age of 0 -> 0; _ -> 1 end;\nf(P :: #person{}) :: integer() ->\nP.age.\n\n'quoted name'(F :: fun((integer(), atom()) -> integer()), N :: integer()) ->\nF(N,ok).\ng() ->\nfun(X) -> X end.\n")

(ert-deftest angler-function-and-clause-navigation ()
  (with-temp-buffer
    (insert angler-test--navigation-source)
    (angler-mode)
    (goto-char (point-max))
    (should (angler-beginning-of-function))
    (should (looking-at "g()"))
    (should (angler-beginning-of-function))
    (should (looking-at "'quoted name'"))
    (should (angler-beginning-of-function))
    (should (looking-at "f(P"))
    (let ((first (point)))
      (search-forward "P.age.")
      (angler-beginning-of-clause)
      (should (> (point) first))
      (should (looking-at "f(P"))
      (beginning-of-defun)
      (should (= (point) first))
      (end-of-defun)
      (should (<= (point) (save-excursion (search-forward "'quoted name'") (point)))))
    (goto-char (point-min))
    (search-forward "f(P")
    (beginning-of-line)
    (angler-beginning-of-function -1)
    (should (looking-at "'quoted name'"))))

(ert-deftest angler-imenu-uses-source-markers-and-correct-arity ()
  (with-temp-buffer
    (insert angler-test--navigation-source)
    (angler-mode)
    (goto-char (point-min))
    (set-buffer-modified-p nil)
    (let* ((position (point)) (original (buffer-string))
           (index (angler-imenu-create-index)))
      (should (equal (mapcar #'car index) '("f/1" "'quoted name'/2" "g/0")))
      (should (= (point) position))
      (should (equal (buffer-string) original))
      (should-not (buffer-modified-p))
      (dolist (entry index)
        (should (eq (marker-buffer (cdr entry)) (current-buffer)))))))

(ert-deftest angler-layout-keybindings-are-local ()
  (with-temp-buffer
    (angler-mode)
    (should (eq (key-binding (kbd "TAB")) #'indent-for-tab-command))
    (should (eq (key-binding (kbd "RET")) #'newline-and-indent))
    (should (eq (key-binding (kbd "C-c M-a")) #'angler-beginning-of-clause)))
  (with-temp-buffer
    (erlang-mode)
    (should (eq indent-line-function #'erlang-indent-command))
    (should (eq (key-binding (kbd "RET")) #'erlang-electric-newline))
    (should (eq (key-binding (kbd "C-c M-a")) #'erlang-beginning-of-clause))))

(ert-deftest angler-interactive-layout-commands ()
  (with-temp-buffer
    (insert "f(P :: #person{}) ->\nP.name;\nf(P :: #person{}) ->\nP.age.\n")
    (angler-mode)
    (setq-local indent-tabs-mode nil)
    (goto-char (point-min))
    (search-forward "P.age")
    (angler-indent-function)
    (should (equal (buffer-string)
                   "f(P :: #person{}) ->\n    P.name;\nf(P :: #person{}) ->\n    P.age.\n"))
    (goto-char (point-min))
    (search-forward "P.age")
    (angler-mark-clause)
    (should (equal (buffer-substring (region-beginning) (region-end))
                   "f(P :: #person{}) ->\n    P.age."))
    (erase-buffer)
    (insert "f(P :: #person{}) ->")
    (call-interactively (key-binding (kbd "RET")))
    (should (= (current-column) 4))
    (should (equal (buffer-string) "f(P :: #person{}) ->\n    "))))

(ert-deftest angler-electric-punctuation-does-not-bypass-layout ()
  (with-temp-buffer
    (angler-mode)
    (insert "f(P :: #person{}) -> P.name")
    (let ((last-command-event ?\;))
      (call-interactively #'erlang-electric-semicolon))
    (should (equal (buffer-string) "f(P :: #person{}) -> P.name;"))))

(ert-deftest angler-layout-handles-trailing-annotation-comment ()
  (with-temp-buffer
    (insert "f(P :: %")
    (angler-mode)
    (angler-indent-line)
    (should (equal (buffer-string) "f(P :: %"))))

(defun angler-test--kill-buffer (buffer)
  "Kill test BUFFER and its process without interaction or history writes."
  (when (buffer-live-p buffer)
    (let ((process (get-buffer-process buffer)))
      (when process (set-process-query-on-exit-flag process nil) (delete-process process)))
    (with-current-buffer buffer
      (setq-local comint-input-ring-file-name nil)
      (let ((kill-buffer-query-functions nil)) (kill-buffer buffer)))))

(defun angler-test--wait (process predicate)
  "Wait briefly for PROCESS output until PREDICATE succeeds."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output process 0.05))
    (should (funcall predicate))))

(defun angler-test--shell (&optional program arguments)
  "Create a live isolated Erlang-mode shell, defaulting to an echo process."
  (let ((buffer (generate-new-buffer " *Angler test shell*")))
    (apply #'make-comint-in-buffer "angler-test" buffer (or program "cat") nil arguments)
    (with-current-buffer buffer
      (let ((erlang-input-ring-file-name nil)) (erlang-shell-mode))
      (setq-local comint-input-ring-file-name nil))
    buffer))

(ert-deftest angler-transpile-buffer-includes-unsaved-text ()
  (let ((angler-program (expand-file-name "bin/angler")))
    (with-temp-buffer
      (rename-buffer " *Angler source test*" t)
      (insert "-module(m). % café\n_export run()->P=#person{},P.age.")
      (setq-local buffer-file-coding-system 'iso-latin-1-unix)
      (let ((original (buffer-string)) (output nil))
        (unwind-protect
            (progn
              (setq output (angler-transpile-buffer))
              (should (equal (buffer-string) original))
              (should (buffer-modified-p))
              (with-current-buffer output
                (should buffer-read-only)
                (should (eq major-mode 'erlang-mode))
                (should (eq buffer-file-coding-system 'iso-latin-1-unix))
                (should (string-match-p "café" (buffer-string)))
                (should-not (buffer-modified-p))
                (should (string-match-p "-export" (buffer-string)))
                (should (string-match-p "P#person.age" (buffer-string)))))
          (angler-test--kill-buffer output))))))

(ert-deftest angler-transpile-failure-preserves-previous-output ()
  (let ((angler-program (expand-file-name "bin/angler")) (output nil))
    (unwind-protect
        (with-temp-buffer
          (rename-buffer " *Angler failure source*" t)
          (insert "-module(m). _export f()->ok.")
          (setq output (angler-transpile-buffer))
          (let ((before (with-current-buffer output (buffer-string))))
            (erase-buffer)
            (insert "_export")
            (should-error (angler-transpile-buffer) :type 'user-error)
            (should (equal (with-current-buffer output (buffer-string)) before))))
      (angler-test--kill-buffer output)
      (angler-test--kill-buffer (get-buffer "*Angler diagnostics*")))))

(ert-deftest angler-command-diagnostics-use-source-location ()
  (let ((angler-program (expand-file-name "bin/angler"))
        (file (make-temp-file "angler source " nil ".erlx")) (source nil))
    (unwind-protect
        (progn
          (setq source (find-file-noselect file))
          (with-current-buffer source
            (insert "% first\n% second\n\t P.name.")
            (goto-char (point-min))
            (search-forward "P.name.")
            (let ((end (point)) (begin (- (point) 7)))
              (should-error (angler-copy-snippet begin end) :type 'user-error))
            (should (buffer-modified-p)))
          (with-current-buffer "*Angler diagnostics*"
            (should (eq major-mode 'angler-compilation-mode))
            (should (string-match-p (regexp-quote (concat file ": 3:3:")) (buffer-string))))
          (save-window-excursion
            (with-current-buffer source (next-error 1 t))
            (with-current-buffer source
              (should (= (line-number-at-pos) 3))
              (should (= (current-column) 9))
              (should (looking-at "P.name"))))
          (with-temp-buffer (insert-file-contents file) (should (equal (buffer-string) ""))))
      (when (buffer-live-p source) (with-current-buffer source (set-buffer-modified-p nil)))
      (angler-test--kill-buffer source)
      (angler-test--kill-buffer (get-buffer "*Angler diagnostics*"))
      (delete-file file))))

(ert-deftest angler-transpile-shows-warnings-and-promotion ()
  (let ((angler-program (expand-file-name "bin/angler")) (output nil))
    (unwind-protect
        (with-temp-buffer
          (insert "-module(m). _export f(X :: integer())->X; f(X)->X.")
          (setq output (angler-transpile-buffer))
          (with-current-buffer "*Angler diagnostics*"
            (should (string-match-p "warning:" (buffer-string))))
          (let ((angler-warnings-as-errors t))
            (should-error (angler-transpile-buffer) :type 'user-error)))
      (angler-test--kill-buffer output)
      (angler-test--kill-buffer (get-buffer "*Angler diagnostics*")))))

(ert-deftest angler-command-missing-executable-preserves-kill-ring ()
  (let ((angler-program "/no/such/angler") (kill-ring '("keep")))
    (unwind-protect
        (with-temp-buffer
          (insert "42.")
          (should-error (angler-copy-snippet (point-min) (point-max)) :type 'user-error)
          (should (equal kill-ring '("keep")))
          (should (equal (buffer-string) "42.")))
      (angler-test--kill-buffer (get-buffer "*Angler diagnostics*")))))

(ert-deftest angler-send-snippet-selects-one-shell-and-preserves-source ()
  (let ((angler-program (expand-file-name "bin/angler"))
        (first (angler-test--shell)) (second (angler-test--shell))
        (kill-ring '("keep")))
    (unwind-protect
        (with-temp-buffer
          (insert "P=#person{},P.name.")
          (let ((original (buffer-string)) (angler-shell-buffer (buffer-name second)))
            (angler-send-snippet (point-min) (point-max))
            (should (equal (buffer-string) original))
            (should (equal kill-ring '("keep")))
            (with-current-buffer second (should (string-match-p "P#person.name" (buffer-string))))
            (with-current-buffer first (should (equal (buffer-string) "")))))
      (angler-test--kill-buffer first)
      (angler-test--kill-buffer second))))

(ert-deftest angler-send-snippet-failures-do-not-touch-shell ()
  (let ((angler-program (expand-file-name "bin/angler")) (shell (angler-test--shell)))
    (unwind-protect
        (with-temp-buffer
          (insert "_export f()->ok.")
          (should-error (angler-send-snippet (point-min) (point-max) shell) :type 'user-error)
          (with-current-buffer shell (should (equal (buffer-string) "")))
          (erase-buffer)
          (insert "42.")
          (with-current-buffer shell (insert "unfinished"))
          (should-error (angler-send-snippet (point-min) (point-max) shell) :type 'user-error)
          (with-current-buffer shell (should (equal (buffer-string) "unfinished"))))
      (angler-test--kill-buffer shell)
      (angler-test--kill-buffer (get-buffer "*Angler diagnostics*")))))

(ert-deftest angler-shell-selection-requires-live-unique-shell ()
  (let ((first (angler-test--shell)) (second (angler-test--shell)) (angler-shell-buffer nil))
    (unwind-protect
        (progn
          (should-error (angler--select-shell nil nil) :type 'user-error)
          (should (eq (angler--select-shell first nil) first))
          (delete-process (get-buffer-process first))
          (should-error (angler--select-shell first nil) :type 'user-error)
          (should (eq (angler--select-shell nil nil) second)))
      (angler-test--kill-buffer first)
      (angler-test--kill-buffer second))))

(ert-deftest angler-send-snippet-real-erlang-shell ()
  (let ((angler-program (expand-file-name "bin/angler"))
        (shell (angler-test--shell "erl" '("+S" "1:1"))))
    (unwind-protect
        (let ((process (get-buffer-process shell)))
          (angler-test--wait process (lambda () (with-current-buffer shell
                                                 (string-match-p "1>" (buffer-string)))))
          (with-current-buffer shell
            (goto-char (point-max))
            (insert "rd(person, {age}).")
            (comint-send-input nil t))
          (angler-test--wait process (lambda () (with-current-buffer shell
                                                 (string-match-p "2>" (buffer-string)))))
          (with-temp-buffer
            (insert "P=#person{age=41},P.age+1.")
            (angler-send-snippet (point-min) (point-max) shell))
          (angler-test--wait process (lambda () (with-current-buffer shell
                                                 (string-match-p "\n42" (buffer-string))))))
      (angler-test--kill-buffer shell))))

(ert-deftest angler-project-build-and-argument-quoting ()
  (let* ((angler-program (expand-file-name "bin/angler"))
         (root (make-temp-file "angler project ' $ " t))
         (input (expand-file-name "src_ex" root)) (build nil))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "nested" input) t)
          (with-temp-file (expand-file-name "m.erlx" input)
            (insert "-module(m). _export f()->ok."))
          (with-temp-buffer
            (setq default-directory (file-name-as-directory (expand-file-name "nested" input)))
            (setq buffer-file-name (expand-file-name "m.erlx" input))
            (insert "unsaved invalid source")
            (let ((angler-build-arguments '("--output" "generated files")))
              (setq build (angler-build)))
            (should (buffer-modified-p))
            (should (equal (buffer-string) "unsaved invalid source"))
            (set-buffer-modified-p nil))
          (let ((process (get-buffer-process build)))
            (angler-test--wait process (lambda () (not (process-live-p process))))
            (should (= (process-exit-status process) 0)))
          (should (file-exists-p (expand-file-name "generated files/m.erl" root)))
          (with-current-buffer build
            (should (eq major-mode 'angler-compilation-mode))
            (should (equal default-directory (file-name-as-directory root)))))
      (angler-test--kill-buffer build)
      (delete-directory root t))))

(ert-deftest angler-build-diagnostics-are-navigable ()
  (let* ((angler-program (expand-file-name "bin/angler"))
         (root (make-temp-file "angler-errors-" t))
         (file (expand-file-name "src_ex/bad.erlx" root)) (build nil) (visited nil))
    (unwind-protect
        (progn
          (make-directory (file-name-directory file) t)
          (with-temp-file file (insert "% first\n_export\n"))
          (with-temp-buffer (setq build (angler-build root)))
          (let ((process (get-buffer-process build)))
            (angler-test--wait process (lambda () (not (process-live-p process))))
            (should (= (process-exit-status process) 1)))
          (save-window-excursion
            (with-current-buffer build (compilation-next-error-function 1 t))
            (setq visited (get-file-buffer file))
            (should (buffer-live-p visited))
            (with-current-buffer visited (should (= (line-number-at-pos) 2)))))
      (angler-test--kill-buffer visited)
      (angler-test--kill-buffer build)
      (delete-directory root t))))

(defvar native-comp-enable-subr-trampolines)

(ert-deftest angler-shell-interactive-selection-and-no-shell-error ()
  (let ((first (angler-test--shell)) (second (angler-test--shell)) (angler-shell-buffer nil)
        (native-comp-enable-subr-trampolines nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt collection &rest _)
                       (should (member (buffer-name first) collection))
                       (should (member (buffer-name second) collection))
                       (buffer-name second))))
            (should (eq (angler--select-shell nil t) second)))
          (delete-process (get-buffer-process first))
          (delete-process (get-buffer-process second))
          (should-error (angler--select-shell nil nil) :type 'user-error))
      (angler-test--kill-buffer first)
      (angler-test--kill-buffer second))))
