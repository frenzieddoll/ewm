;;; ewm-skk-tests.el --- ERT tests for DDSKK in Wayland fields -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Drives the real DDSKK through `ewm--handle-key' and the queued
;; `ewm-skk-key' events, with a small fixture dictionary, and records what
;; reaches the client: commits, preedits and keys forwarded raw.
;;
;; DDSKK is not part of EWM.  The suite skips unless `skk' loads; point
;; EWM_TEST_LOAD_PATH (colon separated) at the ddskk and ccc directories,
;; or let `package-activate-all' find them:
;;   emacs -Q -batch -L lisp -l tests/ewm-skk-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'cl-lib)
(require 'ert)

(load (expand-file-name "ewm-test-stubs"
                        (file-name-directory (or load-file-name buffer-file-name)))
      nil t)

(defconst ewm-skk-tests--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(dolist (dir (split-string (or (getenv "EWM_TEST_LOAD_PATH") "") ":" t))
  (add-to-list 'load-path (expand-file-name dir)))
(unless (locate-library "skk")
  (require 'package)
  (package-activate-all))

;; Keep the user's SKK setup and dictionaries out of the suite.
(defvar ewm-skk-tests--home (make-temp-file "ewm-skk-tests" t))
(setq skk-user-directory ewm-skk-tests--home
      skk-init-file (expand-file-name "init" ewm-skk-tests--home)
      skk-jisyo (expand-file-name "jisyo" ewm-skk-tests--home)
      skk-jisyo-code 'utf-8
      skk-backup-jisyo (expand-file-name "jisyo.bak" ewm-skk-tests--home)
      skk-record-file (expand-file-name "record" ewm-skk-tests--home)
      skk-large-jisyo nil
      skk-cdb-large-jisyo nil
      skk-server-host nil
      skk-use-color-cursor nil
      skk-show-mode-show nil
      skk-egg-like-newline nil
      skk-search-prog-list
      `((skk-search-jisyo-file
         '(,(expand-file-name "fixtures/skk-jisyo" ewm-skk-tests--dir) . utf-8)
         0)))

(defconst ewm-skk-tests--have-skk
  (ignore-errors
    (require 'ccc nil t)
    (load "ddskk-autoloads" t t)
    (require 'skk)
    (require 'skk-leim)
    t))

(defvar ewm-skk-tests--focused-id nil)
(defvar ewm-skk-tests--sent nil
  "What reached the client, newest first: (commit . TEXT), (preedit . TEXT)
or (key . KEYCODE).")

(defun ewm-im-commit-module (text _surface-id)
  (push (cons 'commit text) ewm-skk-tests--sent))
(defun ewm-im-preedit-module (text _surface-id)
  (push (cons 'preedit text) ewm-skk-tests--sent))
(defun ewm-text-input-forward-key-module (_surface-id keycode &rest _mods)
  (push (cons 'key keycode) ewm-skk-tests--sent))
(defun ewm-get-focused-id () ewm-skk-tests--focused-id)

(require 'ewm-skk)

(defmacro ewm-skk-tests--with-surface (&rest body)
  "Run BODY with `ewm-skk-mode' on and surface 10 in DDSKK as `surface'."
  (declare (indent 0) (debug t))
  `(progn
     (skip-unless ewm-skk-tests--have-skk)
     (let ((ewm--surfaces (make-hash-table))
           (ewm-skk-tests--sent nil)
           (ewm-skk-tests--focused-id 10)
           (ewm-text-input--raw nil)
           (ewm-text-input--composing nil)
           (ewm-text-input--client-active t)
           (ewm-text-input-key-functions nil)
           (ewm-text-input-surface-composer-functions nil)
           (ewm-text-input-deactivate-hook nil)
           (unread-command-events nil)
           (inhibit-message t)
           (surface (generate-new-buffer " *ewm-skk-surface*")))
       (unwind-protect
           (progn
             (puthash 10 surface ewm--surfaces)
             (with-current-buffer surface
               (ewm-surface-mode)
               (setq ewm-surface-id 10)
               (set-input-method "japanese-skk"))
             (ewm-skk-mode 1)
             ,@body)
         (ewm-skk-mode -1)
         (kill-buffer surface)))))

(defconst ewm-skk-tests--keysyms
  '((backspace . (#xff08 . 22)) (return . (#xff0d . 36)) (left . (#xff51 . 113)))
  "Keysym and keycode of the function keys the suite presses.")

(defun ewm-skk-tests--event (key)
  "Compositor event on surface 10 for KEY: a character, C-x style or a symbol."
  (cond
   ((symbolp key)
    (let ((sym (alist-get key ewm-skk-tests--keysyms)))
      `((surface_id . 10) (keycode . ,(cdr sym)) (keysym . ,(car sym)))))
   ((< key ?\s)
    `((surface_id . 10) (keycode . 99) (utf8 . ,(string (+ key ?`))) (ctrl . t)))
   (t `((surface_id . 10) (keycode . 1) (utf8 . ,(string key))))))

(defun ewm-skk-tests--run-queue ()
  "Run the queued DDSKK keys as the command loop's special-event map would."
  (while (eq (car-safe (car unread-command-events)) 'ewm-skk-key)
    (let ((last-input-event (pop unread-command-events)))
      (ewm-skk--compose))))

(defun ewm-skk-tests--type (&rest keys)
  "Press KEYS one after another; strings stand for their characters."
  (dolist (key keys)
    (dolist (k (if (stringp key) (string-to-list key) (list key)))
      (ewm--handle-key (ewm-skk-tests--event k))
      (ewm-skk-tests--run-queue))))

(defun ewm-skk-tests--commits ()
  "Committed text in order."
  (mapcar #'cdr (seq-filter (lambda (s) (eq (car s) 'commit))
                            (reverse ewm-skk-tests--sent))))

(defun ewm-skk-tests--keys ()
  "Keycodes forwarded raw, in order."
  (mapcar #'cdr (seq-filter (lambda (s) (eq (car s) 'key))
                            (reverse ewm-skk-tests--sent))))

(defun ewm-skk-tests--preedit ()
  "What the client shows as preedit now."
  ;; A commit clears the preedit.
  (let ((last (seq-find (lambda (s) (memq (car s) '(commit preedit)))
                        ewm-skk-tests--sent)))
    (if (eq (car last) 'preedit) (cdr last) "")))

(defun ewm-skk-tests--clean (surface)
  "Non-nil when nothing is left over for the command loop or SURFACE."
  (and (null unread-command-events)
       (null ewm-text-input--raw)
       (with-current-buffer surface (ewm-skk--idle-p))))

(ert-deftest ewm-skk-tests/romaji-commits-kana-once ()
  "`k' shows as preedit, `a' commits one か."
  (ewm-skk-tests--with-surface
    (ewm-skk-tests--type ?k)
    (should (equal (ewm-skk-tests--preedit) "k"))
    (should-not (ewm-skk-tests--commits))
    (ewm-skk-tests--type ?a)
    (should (equal (ewm-skk-tests--commits) '("か")))
    (should (equal (ewm-skk-tests--preedit) ""))
    (should (ewm-skk-tests--clean surface))))

(ert-deftest ewm-skk-tests/conversion-is-preedit-until-confirmed ()
  "▽にほん → ▼日本 → C-j commits 日本 only, without marks or newline."
  (ewm-skk-tests--with-surface
    (ewm-skk-tests--type "Nihon")
    (should (equal (ewm-skk-tests--preedit) "▽にほn"))
    (ewm-skk-tests--type ?n)
    (should (equal (ewm-skk-tests--preedit) "▽にほん"))
    (ewm-skk-tests--type ?\s)
    (should (equal (ewm-skk-tests--preedit) "▼日本"))
    (should-not (ewm-skk-tests--commits))
    (ewm-skk-tests--type ?\C-j)
    (should (equal (ewm-skk-tests--commits) '("日本")))
    (should (equal (ewm-skk-tests--preedit) ""))
    (should-not (ewm-skk-tests--keys))
    (should (ewm-skk-tests--clean surface))))

(ert-deftest ewm-skk-tests/typing-on-confirms-the-candidate ()
  "A kana after ▼ confirms the candidate first, as in Emacs."
  (ewm-skk-tests--with-surface
    (ewm-skk-tests--type "Nihonn " "ga")
    (should (equal (ewm-skk-tests--commits) '("日本" "が")))
    (should (ewm-skk-tests--clean surface))))

(ert-deftest ewm-skk-tests/text-before-a-new-conversion-commits ()
  "Confirmed kana is committed even while a later conversion is open."
  (ewm-skk-tests--with-surface
    (ewm-skk-tests--type "ka" "Ni")
    (should (equal (ewm-skk-tests--commits) '("か")))
    (should (equal (ewm-skk-tests--preedit) "▽に"))))

(ert-deftest ewm-skk-tests/previous-candidate ()
  "`x' in ▼ steps back to the previous candidate."
  (ewm-skk-tests--with-surface
    (ewm-skk-tests--type "Kanji" ?\s)
    (should (equal (ewm-skk-tests--preedit) "▼漢字"))
    (ewm-skk-tests--type ?\s)
    (should (equal (ewm-skk-tests--preedit) "▼感じ"))
    (ewm-skk-tests--type ?x)
    (should (equal (ewm-skk-tests--preedit) "▼漢字"))
    (ewm-skk-tests--type ?\C-j)
    (should (equal (ewm-skk-tests--commits) '("漢字")))))

(ert-deftest ewm-skk-tests/candidate-list-reads-the-next-keys ()
  "Keys queued behind the key opening the candidate list are read by it."
  (ewm-skk-tests--with-surface
    (ewm-skk-tests--type "Ai")
    ;; The fifth space lists 合 会 逢 under a s d; s picks 会.
    (dolist (k (list ?\s ?\s ?\s ?\s ?\s ?s))
      (ewm--handle-key (ewm-skk-tests--event k)))
    (ewm-skk-tests--run-queue)
    (should (equal (ewm-skk-tests--commits) '("会")))
    (should (ewm-skk-tests--clean surface))))

(ert-deftest ewm-skk-tests/reentrant-key-goes-to-the-read ()
  "A queued key run by a read inside DDSKK becomes that read's key."
  (ewm-skk-tests--with-surface
    (with-current-buffer surface
      (let ((ewm-skk--running surface)
            (ewm-text-input--raw nil)
            (last-input-event (list 'ewm-skk-key 10 ?s (ewm-skk-tests--event ?s))))
        (ewm-skk--compose)
        (should (equal unread-command-events '((no-record . ?s))))
        (should (equal ewm-text-input--raw (list (ewm-skk-tests--event ?s))))))))

(ert-deftest ewm-skk-tests/okurigana ()
  "KaKu converts with okurigana and commits 書く."
  (ewm-skk-tests--with-surface
    (ewm-skk-tests--type "KaKu")
    (should (equal (ewm-skk-tests--preedit) "▼書く"))
    (ewm-skk-tests--type ?\C-j)
    (should (equal (ewm-skk-tests--commits) '("書く")))
    (should (ewm-skk-tests--clean surface))))

(ert-deftest ewm-skk-tests/quit-steps-back-then-cancels ()
  "C-g takes ▼ back to ▽, then drops the reading; nothing reaches the client."
  (ewm-skk-tests--with-surface
    (ewm-skk-tests--type "Nihonn ")
    (ewm-skk-tests--type ?\C-g)
    (should (equal (ewm-skk-tests--preedit) "▽にほん"))
    (ewm-skk-tests--type ?\C-g)
    (should (equal (ewm-skk-tests--preedit) ""))
    (should-not (ewm-skk-tests--commits))
    (should-not (ewm-skk-tests--keys))
    (should (ewm-skk-tests--clean surface))))

(ert-deftest ewm-skk-tests/backspace-edits-the-reading ()
  "Backspace edits a pending reading, and reaches the client otherwise."
  (ewm-skk-tests--with-surface
    (ewm-skk-tests--type "Kak" 'backspace)
    (should (equal (ewm-skk-tests--preedit) "▽か"))
    (ewm-skk-tests--type 'backspace)
    (should (equal (ewm-skk-tests--preedit) "▽"))
    (should-not (ewm-skk-tests--keys))
    (ewm-skk-tests--type ?\C-g 'backspace)
    (should (equal (ewm-skk-tests--keys) '(22)))
    (should-not (ewm-skk-tests--commits))))

(ert-deftest ewm-skk-tests/return-confirms-then-types-return ()
  "Return in ▼ commits the candidate and reaches the client as Return."
  (ewm-skk-tests--with-surface
    (ewm-skk-tests--type "Nihonn " 'return)
    (should (equal (ewm-skk-tests--commits) '("日本")))
    (should (equal (ewm-skk-tests--keys) '(36)))
    (should (ewm-skk-tests--clean surface))
    ;; With nothing composing it is just Return.
    (ewm-skk-tests--type 'return)
    (should (equal (ewm-skk-tests--keys) '(36 36)))
    (should (equal (ewm-skk-tests--commits) '("日本")))))

(ert-deftest ewm-skk-tests/egg-like-newline-only-confirms ()
  "With `skk-egg-like-newline', Return in ▼ confirms without a Return."
  (ewm-skk-tests--with-surface
    (let ((skk-egg-like-newline t))
      (ewm-skk-tests--type "Nihonn " 'return))
    (should (equal (ewm-skk-tests--commits) '("日本")))
    (should-not (ewm-skk-tests--keys))))

(ert-deftest ewm-skk-tests/other-keys-confirm-and-reach-the-client ()
  "A key DDSKK has no use for confirms the conversion, then reaches the client."
  (ewm-skk-tests--with-surface
    (ewm-skk-tests--type "Nihonn " 'left)
    (should (equal (ewm-skk-tests--commits) '("日本")))
    (should (equal (ewm-skk-tests--keys) '(113)))
    (should (ewm-skk-tests--clean surface))))

(ert-deftest ewm-skk-tests/shortcuts-pass-when-idle ()
  "Control keys reach the client when nothing is composing, except C-j."
  (ewm-skk-tests--with-surface
    (ewm-skk-tests--type ?\C-c)
    (should (equal (ewm-skk-tests--keys) '(99)))
    (should-not unread-command-events)
    ;; C-j leaves latin mode, which only DDSKK can do.
    (ewm-skk-tests--type "la" ?\C-j "a")
    (should (equal (ewm-skk-tests--commits) '("a" "あ")))
    (should (equal (ewm-skk-tests--keys) '(99)))))

(ert-deftest ewm-skk-tests/burst-keys-keep-their-order ()
  "Keys queued before the first ran are judged once their turn comes."
  (ewm-skk-tests--with-surface
    ;; Backspace arrives while K still waits: DDSKK must get it, not the client.
    (dolist (k (list ?K ?a ?k 'backspace))
      (ewm--handle-key (ewm-skk-tests--event k)))
    (should (= (length unread-command-events) 4))
    (ewm-skk-tests--run-queue)
    (should (equal (ewm-skk-tests--preedit) "▽か"))
    (should-not (ewm-skk-tests--keys))))

(ert-deftest ewm-skk-tests/surface-change-hook-stays-out ()
  "The surface buffer's own commit-on-insert hook never sees DDSKK's text."
  (ewm-skk-tests--with-surface
    (ewm-skk-tests--type "Nihonn " ?\C-j "ka")
    (should (equal (ewm-skk-tests--commits) '("日本" "か")))
    (should (memq #'ewm-surface--after-change
                  (buffer-local-value 'after-change-functions surface)))))

(ert-deftest ewm-skk-tests/deactivation-drops-the-conversion ()
  "A field going away drops the unconfirmed reading without committing it."
  (ewm-skk-tests--with-surface
    (ewm-skk-tests--type "Nihon")
    (ewm--handle-text-input-deactivated)
    (should (ewm-skk-tests--clean surface))
    (ewm--handle-text-input-activated)
    (ewm-skk-tests--type "a")
    (should (equal (ewm-skk-tests--commits) '("あ")))))

(ert-deftest ewm-skk-tests/deactivation-mid-read-stops-the-keys ()
  "Keys for a field that went away during a DDSKK read are dropped with it."
  (ewm-skk-tests--with-surface
    (ewm-skk-tests--type "Nihon")
    (cl-letf* ((orig (symbol-function 'ewm-skk--execute))
               ((symbol-function 'ewm-skk--execute)
                (lambda (&rest args)
                  ;; Keys arrive and the field goes while DDSKK runs.
                  (ewm--handle-key (ewm-skk-tests--event ?a))
                  (ewm--handle-text-input-deactivated)
                  (apply orig args))))
      (ewm-skk-tests--type ?n))
    (should-not (ewm-skk-tests--commits))
    (should (ewm-skk-tests--clean surface))))

(ert-deftest ewm-skk-tests/skk-off-leaves-keys-alone ()
  "Without DDSKK on the surface, or with the mode off, keys take the old path."
  (ewm-skk-tests--with-surface
    (with-current-buffer surface (deactivate-input-method))
    (ewm--handle-key (ewm-skk-tests--event ?a))
    (should (equal (caar unread-command-events) 'ewm-text-input-key))
    (setq unread-command-events nil)
    (with-current-buffer surface (activate-input-method "japanese-skk"))
    (ewm-skk-mode -1)
    (ewm--handle-key (ewm-skk-tests--event ?a))
    (should (equal (caar unread-command-events) 'ewm-text-input-key))))

(ert-deftest ewm-skk-tests/bare-skk-mode-turns-interception-on ()
  "`skk-mode' without the input method still makes auto mode intercept."
  (ewm-skk-tests--with-surface
    (let ((ewm-text-input-auto-mode t)
          (intercepts nil))
      (cl-letf (((symbol-function 'ewm-text-input-intercept-module)
                 (lambda (on) (push on intercepts))))
        (with-current-buffer surface
          (deactivate-input-method)
          (should-not current-input-method)
          (skk-mode 1))
        (should (car intercepts))
        (with-current-buffer surface (skk-mode -1))
        (should-not (car intercepts))))
    (ewm-text-input-mode -1)))

(provide 'ewm-skk-tests)
;;; ewm-skk-tests.el ends here
