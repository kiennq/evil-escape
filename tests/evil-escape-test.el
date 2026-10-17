;;; evil-escape-test.el --- Tests for evil-escape -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'evil-escape)

(defmacro evil-escape-test--with-buffer (&rest body)
  (declare (indent 0) (debug t))
  `(let ((evil-was-enabled evil-mode)
         (escape-was-enabled evil-escape-mode)
         (evil-escape-key-sequence "jk")
         (evil-escape-delay 0.01)
         (evil-escape-unordered-key-sequence nil)
         (evil-escape-case-insensitive-key-sequence nil)
         (evil-escape-inhibit nil)
         (evil-escape-inhibit-functions nil)
         (evil-escape-excluded-major-modes nil)
         (evil-escape-excluded-states nil)
         (evil-escape-enable-only-for-major-modes nil)
         (unread-command-events nil)
         (unread-post-input-method-events nil))
     (unwind-protect
         (progn
           (evil-mode 1)
           (evil-escape-mode 1)
           (save-window-excursion
             (with-temp-buffer
               (switch-to-buffer (current-buffer))
               (evil-insert-state)
               ,@body)))
       (unless escape-was-enabled (evil-escape-mode -1))
       (unless evil-was-enabled (evil-mode -1)))))

(ert-deftest evil-escape-test-queued-input ()
  (dolist (case '(("jk" nil nil "" normal 0)
                  ("jx" nil nil "jx" insert 2)
                  ("jxy" nil nil "jxy" insert 3)
                  ("jjk" nil nil "j" normal 1)
                  ("jkiX" nil nil "X" insert 1)
                  ("kj" t nil "" normal 0)
                  ("JK" nil t "" normal 0)
                  ("Jk" nil t "" normal 0)
                  ("jK" nil t "" normal 0)
                  ("Kj" t t "" normal 0)
                  ("kJ" t t "" normal 0)
                  ("KJ" t t "" normal 0)))
    (ert-info ((format "Input %S" (car case)))
      (evil-escape-test--with-buffer
        (let ((evil-escape-unordered-key-sequence (nth 1 case))
              (evil-escape-case-insensitive-key-sequence (nth 2 case))
              (changes 0)
              (insertions 0))
          (add-hook 'after-change-functions
                    (lambda (&rest _) (setq changes (1+ changes))) nil t)
          (add-hook 'post-self-insert-hook
                    (lambda () (setq insertions (1+ insertions))) nil t)
          (execute-kbd-macro (car case))
          (should (equal (buffer-string) (nth 3 case)))
          (should (eq evil-state (nth 4 case)))
          (should (= changes (nth 5 case)))
          (should (= insertions (nth 5 case))))))))

(ert-deftest evil-escape-test-defers-editing-until-after-read ()
  (dolist (event '(nil ?k ?x))
    (evil-escape-test--with-buffer
      (let ((changes 0)
            (insertions 0)
            observed)
        (add-hook 'after-change-functions
                  (lambda (&rest _) (setq changes (1+ changes))) nil t)
        (add-hook 'post-self-insert-hook
                  (lambda () (setq insertions (1+ insertions))) nil t)
        (cl-letf (((symbol-function 'read-event)
                   (lambda (_prompt _inherit-input-method seconds)
                     (setq observed
                           (list seconds (buffer-string) changes insertions))
                     event)))
          (execute-kbd-macro "j"))
        (should (equal observed (list evil-escape-delay "" 0 0)))
        (should (equal (buffer-string)
                       (pcase event (?k "") (?x "jx") (_ "j"))))
        (should (= changes (if (eq event ?k) 0 (if event 2 1))))
        (should (= insertions changes))))))

(ert-deftest evil-escape-test-escape-does-not-run-insertion-side-effects ()
  (evil-escape-test--with-buffer
    (add-hook 'post-self-insert-hook (lambda () (insert "!")) nil t)
    (execute-kbd-macro "jk")
    (should (equal (buffer-string) ""))
    (should-not (buffer-modified-p))
    (should (eq evil-state 'normal))))

(ert-deftest evil-escape-test-read-only-escape ()
  (dolist (case '((insert buffer) (insert text)
                  (emacs buffer) (emacs text)
                  (motion buffer) (motion text)))
    (ert-info ((format "Read-only %S" case))
      (evil-escape-test--with-buffer
        (insert "read only")
        (goto-char 3)
        (if (eq (cadr case) 'buffer)
            (setq buffer-read-only t)
          (put-text-property (point-min) (point-max) 'read-only t))
        (set-buffer-modified-p nil)
        (buffer-enable-undo)
        (setq buffer-undo-list nil)
        (evil-change-state (car case))
        (add-hook 'before-change-functions
                  (lambda (&rest _) (ert-fail "Escape must not edit")) nil t)
        (add-hook 'post-self-insert-hook
                  (lambda () (ert-fail "Escape must not self-insert")) nil t)
        (execute-kbd-macro "jk")
        (should (equal (buffer-string) "read only"))
        (should-not (buffer-modified-p))
        (should-not buffer-undo-list)
        (should (eq evil-state 'normal))))))

(ert-deftest evil-escape-test-replays-non-character-event ()
  (evil-escape-test--with-buffer
    (insert "abc")
    (goto-char (point-min))
    (execute-kbd-macro (vector ?j 'right))
    (should (equal (buffer-string) "jabc"))
    (should (= (point) 3))
    (should (eq evil-state 'insert))))

(ert-deftest evil-escape-test-preserves-prefix-command-on-timeout ()
  (evil-escape-test--with-buffer
    (let ((calls 0))
      (use-local-map (make-sparse-keymap))
      (evil-local-set-key 'insert "j"
                          (lambda () (interactive) (setq calls (1+ calls))))
      (cl-letf (((symbol-function 'read-event) (lambda (&rest _) nil)))
        (execute-kbd-macro "j"))
      (should (= calls 1))
      (should (equal (buffer-string) "")))))

(ert-deftest evil-escape-test-inhibited-input-does-not-wait ()
  (dolist (setting '(inhibit major-mode state predicate))
    (evil-escape-test--with-buffer
      (let ((evil-escape-inhibit (eq setting 'inhibit))
            (evil-escape-excluded-major-modes
             (when (eq setting 'major-mode) (list major-mode)))
            (evil-escape-excluded-states
             (when (eq setting 'state) '(insert)))
            (evil-escape-inhibit-functions
             (when (eq setting 'predicate) (list (lambda () t)))))
        (cl-letf (((symbol-function 'read-event)
                   (lambda (&rest _) (ert-fail "Inhibited input must not wait"))))
          (execute-kbd-macro "jk"))
        (should (equal (buffer-string) "jk"))
        (should (eq evil-state 'insert))))))

;;; evil-escape-test.el ends here
