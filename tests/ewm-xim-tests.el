;;; ewm-xim-tests.el --- ERT tests for the XIM server -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Runs the server against a private Xvfb and checks it from a second X
;; connection, as a client would see it.  The end-to-end tests type with
;; XTEST into a real xterm whose shell writes what it gets to a file.
;;
;; XELB, Xvfb and xterm are not part of EWM.  Tests skip unless what they
;; need is found; point EWM_TEST_LOAD_PATH (colon separated) at XELB, ddskk
;; and ccc, or let `package-activate-all' find them:
;;   emacs -Q -batch -L lisp -l tests/ewm-xim-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'cl-lib)
(require 'ert)

(load (expand-file-name "ewm-test-stubs"
                        (file-name-directory (or load-file-name buffer-file-name)))
      nil t)

(dolist (dir (split-string (or (getenv "EWM_TEST_LOAD_PATH") "") ":" t))
  (add-to-list 'load-path (expand-file-name dir)))
(unless (locate-library "xcb")
  (require 'package)
  (package-activate-all))

(defconst ewm-xim-tests--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defconst ewm-xim-tests--have-xim
  (and (executable-find "Xvfb")
       (ignore-errors (require 'ewm-xim) t)))

(defconst ewm-xim-tests--have-xterm
  (and ewm-xim-tests--have-xim
       (executable-find "xterm")
       (ignore-errors (require 'xcb-xtest) t)))

;; Keep the user's SKK setup and dictionaries out of the suite.
(defvar ewm-xim-tests--skk-home (make-temp-file "ewm-xim-tests" t))
(setq skk-user-directory ewm-xim-tests--skk-home
      skk-init-file (expand-file-name "init" ewm-xim-tests--skk-home)
      skk-jisyo (expand-file-name "jisyo" ewm-xim-tests--skk-home)
      skk-jisyo-code 'utf-8
      skk-backup-jisyo (expand-file-name "jisyo.bak" ewm-xim-tests--skk-home)
      skk-record-file (expand-file-name "record" ewm-xim-tests--skk-home)
      skk-large-jisyo nil
      skk-cdb-large-jisyo nil
      skk-server-host nil
      skk-use-color-cursor nil
      skk-show-mode-show nil
      skk-egg-like-newline nil
      skk-search-prog-list
      `((skk-search-jisyo-file
         '(,(expand-file-name "fixtures/skk-jisyo" ewm-xim-tests--dir) . utf-8)
         0)))

(defconst ewm-xim-tests--have-skk
  (and ewm-xim-tests--have-xterm
       (ignore-errors
         (require 'ccc nil t)
         (load "ddskk-autoloads" t t)
         (require 'skk)
         (require 'skk-leim)
         (require 'ewm-skk)
         t)))

;;; A private X server

(defvar ewm-xim-tests--xvfb nil "The Xvfb process.")
(defvar ewm-xim-tests--display nil "Its display name.")

(defun ewm-xim-tests--start-xvfb ()
  "Start Xvfb on a free display and wait for its socket."
  (let ((n (cl-loop for n from 90 below 140
                    unless (or (file-exists-p (format "/tmp/.X%d-lock" n))
                               (file-exists-p (format "/tmp/.X11-unix/X%d" n)))
                    return n)))
    (setq ewm-xim-tests--display (format ":%d" n)
          ewm-xim-tests--xvfb
          (start-process "xvfb" nil "Xvfb" ewm-xim-tests--display
                         "-nolisten" "tcp" "-screen" "0" "640x480x24"))
    (set-process-query-on-exit-flag ewm-xim-tests--xvfb nil)
    (with-timeout (10 (error "Xvfb did not start"))
      (while (not (file-exists-p (format "/tmp/.X11-unix/X%d" n)))
        (accept-process-output nil 0.05)))
    ;; The socket appears before the server answers.
    (sleep-for 0.2)))

(defun ewm-xim-tests--stop-xvfb ()
  "Stop Xvfb."
  (when (process-live-p ewm-xim-tests--xvfb)
    ;; Killed outright, Xvfb would leave its lock and socket behind.
    (signal-process ewm-xim-tests--xvfb 'SIGTERM)
    (while (process-live-p ewm-xim-tests--xvfb)
      (accept-process-output nil 0.05))))

(defmacro ewm-xim-tests--with-server (&rest body)
  "Run BODY with the server on a fresh Xvfb, as DISPLAY."
  (declare (indent 0))
  `(progn
     (skip-unless ewm-xim-tests--have-xim)
     (ewm-xim-tests--start-xvfb)
     (let ((process-environment
            (cons (concat "DISPLAY=" ewm-xim-tests--display) process-environment))
           (ewm-xim-reconnect-delay 0.1))
       (unwind-protect
           (progn
             (setq ewm-xim-mode t ewm-xim--failures 0)
             (ewm-xim--start)
             ,@body)
         (setq ewm-xim-mode nil)
         (ewm-xim--stop)
         (ewm-xim-tests--stop-xvfb)))))

;;; Looking from a client

(defun ewm-xim-tests--intern (conn name)
  (slot-value (xcb:+request-unchecked+reply conn
                  (make-instance 'xcb:InternAtom :only-if-exists 0
                                 :name-len (length name) :name name))
              'atom))

(defun ewm-xim-tests--root (conn)
  (slot-value (car (slot-value (xcb:get-setup conn) 'roots)) 'root))

(defun ewm-xim-tests--servers (conn)
  "Names of the servers in XIM_SERVERS, seen from CONN."
  (let ((value (slot-value
                (xcb:+request-unchecked+reply conn
                    (make-instance 'xcb:GetProperty
                                   :delete 0 :window (ewm-xim-tests--root conn)
                                   :property (ewm-xim-tests--intern conn "XIM_SERVERS")
                                   :type xcb:Atom:ATOM
                                   :long-offset 0 :long-length 100))
                'value)))
    (let ((xcb:lsb xcb:lsb)
          (bytes (vconcat value)))
      (cl-loop for i from 0 below (/ (length bytes) 4)
               collect (xcb:+request-unchecked+reply conn
                           (make-instance 'xcb:GetAtomName
                                          :atom (funcall (if xcb:lsb #'xcb:-unpack-u4-lsb
                                                           #'xcb:-unpack-u4)
                                                         bytes (* i 4))))
               into replies
               finally return (mapcar (lambda (r) (slot-value r 'name)) replies)))))

(defun ewm-xim-tests--query (conn target)
  "Convert the server selection to TARGET from CONN, as XOpenIM does."
  (let* ((root (ewm-xim-tests--root conn))
         (win (xcb:generate-id conn))
         (prop (ewm-xim-tests--intern conn "EWM_XIM_TEST"))
         notified)
    (xcb:+event conn 'xcb:SelectionNotify (lambda (&rest _) (setq notified t)))
    (xcb:+request conn
        (make-instance 'xcb:CreateWindow
                       :depth 0 :wid win :parent root :x 0 :y 0 :width 1 :height 1
                       :border-width 0 :class xcb:WindowClass:InputOutput :visual 0
                       :value-mask 0))
    (xcb:+request conn
        (make-instance 'xcb:ConvertSelection
                       :requestor win
                       :selection (ewm-xim-tests--intern conn "@server=ewm-xim")
                       :target (ewm-xim-tests--intern conn target)
                       :property prop
                       :time xcb:Time:CurrentTime))
    (xcb:flush conn)
    (with-timeout (5 (error "No SelectionNotify for %s" target))
      (while (not notified) (accept-process-output nil 0.05)))
    (let ((value (slot-value
                  (xcb:+request-unchecked+reply conn
                      (make-instance 'xcb:GetProperty
                                     :delete 1 :window win :property prop
                                     :type xcb:GetPropertyType:Any
                                     :long-offset 0 :long-length 1000))
                  'value)))
      (concat value))))

(defmacro ewm-xim-tests--with-client (var &rest body)
  "Run BODY with VAR an X connection to the test display."
  (declare (indent 1))
  `(let ((,var (xcb:connect ewm-xim-tests--display)))
     (unwind-protect (progn ,@body)
       (xcb:disconnect ,var))))

;;; Typing into xterm

(defvar ewm-xim-tests--xtest nil "The X connection keys are faked on.")
(defvar ewm-xim-tests--out nil "File the xterm's shell writes its input to.")
(defvar ewm-xim-tests--surface nil "The xterm's surface buffer.")

(defun ewm-xim-tests--pump (seconds)
  "Serve X and run queued keys for SECONDS, as the command loop would."
  (let ((end (+ (float-time) seconds)))
    (while (< (float-time) end)
      (accept-process-output nil 0.02)
      (while (memq (car-safe (car unread-command-events))
                   '(ewm-text-input-key ewm-skk-key))
        (let ((last-input-event (pop unread-command-events)))
          (if (eq (car last-input-event) 'ewm-skk-key)
              (ewm-skk--compose)
            (ewm-text-input--compose)))))))

(defun ewm-xim-tests--fake (type keycode)
  (xcb:+request ewm-xim-tests--xtest
      (make-instance 'xcb:xtest:FakeInput :type type :detail keycode :time 0
                     :root 0 :rootX 0 :rootY 0 :deviceid 0)))

(defun ewm-xim-tests--press (&rest keys)
  "Press KEYS, characters or symbols, with Shift where they need it."
  (let ((conn ewm-xim-tests--xtest))
    (dolist (key keys)
      (dolist (k (if (stringp key) (string-to-list key) (list key)))
        (let* ((keysym (car (xcb:keysyms:event->keysyms conn k)))
               (code (xcb:keysyms:keysym->keycode conn (car keysym)))
               (shift (and (/= 0 (logand (cdr keysym) 1))
                           (xcb:keysyms:keysym->keycode conn #xffe1))))
          (when shift (ewm-xim-tests--fake 2 shift))
          (ewm-xim-tests--fake 2 code)
          (ewm-xim-tests--fake 3 code)
          (when shift (ewm-xim-tests--fake 3 shift))
          (xcb:flush conn)
          (ewm-xim-tests--pump 0.1))))))

(defun ewm-xim-tests--typed ()
  "What reached the xterm's shell so far."
  (if (file-exists-p ewm-xim-tests--out)
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8))
          (insert-file-contents ewm-xim-tests--out))
        (buffer-string))
    ""))

(defun ewm-xim-tests--wait-typed (text)
  "Wait until the shell got TEXT, and return what it got."
  (with-timeout (5 nil)
    (while (not (equal (ewm-xim-tests--typed) text))
      (ewm-xim-tests--pump 0.05)))
  (ewm-xim-tests--typed))

(defun ewm-xim-tests--focus (conn xwin)
  "Give the X input focus to XWIN."
  (xcb:+request conn
      (make-instance 'xcb:SetInputFocus :revert-to xcb:InputFocus:PointerRoot
                     :focus xwin :time xcb:Time:CurrentTime))
  (xcb:flush conn))

(defun ewm-xim-tests--focused (conn)
  "The window with the X input focus."
  (slot-value (xcb:+request-unchecked+reply conn (make-instance 'xcb:GetInputFocus))
              'focus))

(defmacro ewm-xim-tests--with-xterm (&rest body)
  "Run BODY with an XIM xterm focused, as surface 10 of buffer `surface'."
  (declare (indent 0))
  `(progn
     (skip-unless ewm-xim-tests--have-xterm)
     (ewm-xim-tests--with-server
       (let* ((tmp (make-temp-file "ewm-xim-xterm" t))
              (id-file (expand-file-name "id" tmp))
              (ewm-xim-tests--out (expand-file-name "out" tmp))
              (ewm--surfaces (make-hash-table))
              (ewm-text-input-client-functions '(ewm-xim--deliver))
              (ewm-text-input--composing nil)
              (ewm-text-input--raw nil)
              (unread-command-events nil)
              (inhibit-message t)
              (surface (generate-new-buffer " *ewm-xim-xterm*"))
              (xterm (let ((process-environment
                            (append '("XMODIFIERS=@im=ewm-xim" "LC_ALL=C.UTF-8")
                                    process-environment)))
                       (start-process
                        "xterm" nil "xterm" "-e" "sh" "-c"
                        (format "echo $WINDOWID > %s; exec cat > %s"
                                (shell-quote-argument id-file)
                                (shell-quote-argument ewm-xim-tests--out)))))
              (ewm-xim-tests--xtest (xcb:connect ewm-xim-tests--display)))
         (set-process-query-on-exit-flag xterm nil)
         (unwind-protect
             (cl-letf (((symbol-function 'ewm-get-focused-id) (lambda () 10)))
               (puthash 10 surface ewm--surfaces)
               (with-current-buffer surface
                 (ewm-surface-mode)
                 (setq ewm-surface-id 10))
               (xcb:keysyms:init ewm-xim-tests--xtest)
               (xcb:get-extension-data ewm-xim-tests--xtest 'xcb:xtest)
               (with-timeout (10 (error "No xterm window"))
                 (while (not (and (file-exists-p id-file)
                                  (> (file-attribute-size (file-attributes id-file)) 0)))
                   (ewm-xim-tests--pump 0.05)))
               (xcb:+request ewm-xim-tests--xtest
                   (make-instance 'xcb:SetInputFocus
                                  :revert-to xcb:InputFocus:PointerRoot
                                  :focus (string-to-number
                                          (with-temp-buffer
                                            (insert-file-contents id-file)
                                            (buffer-string)))
                                  :time xcb:Time:CurrentTime))
               (xcb:flush ewm-xim-tests--xtest)
               (with-timeout (10 (error "xterm made no input context"))
                 (while (zerop (hash-table-count ewm-xim--ics))
                   (ewm-xim-tests--pump 0.05)))
               ,@body)
           (when (process-live-p xterm) (delete-process xterm))
           (xcb:disconnect ewm-xim-tests--xtest)
           (kill-buffer surface)
           (delete-directory tmp t))))))

;;; An Xlib client with preedit callbacks

(defconst ewm-xim-tests--client-binary
  (and ewm-xim-tests--have-xterm
       (executable-find "cc")
       (let ((out (expand-file-name "xim-client" (make-temp-file "ewm-xim-client" t))))
         (and (zerop (call-process "cc" nil nil nil "-o" out
                                   (expand-file-name "fixtures/xim-client.c"
                                                     ewm-xim-tests--dir)
                                   "-lX11"))
              out)))
  "The test client from fixtures/xim-client.c, built, or nil.")

(defvar ewm-xim-tests--client nil "The running test client.")

(defun ewm-xim-tests--client-lines ()
  "Lines the test client reported, but the first (its window)."
  (cdr (split-string (with-current-buffer (process-buffer ewm-xim-tests--client)
                       (buffer-string))
                     "\n" t)))

(defun ewm-xim-tests--wait-line (line)
  "Wait until the test client reports LINE; non-nil if it did."
  (with-timeout (5 nil)
    (while (not (member line (ewm-xim-tests--client-lines)))
      (ewm-xim-tests--pump 0.05))
    t))

(defmacro ewm-xim-tests--with-xim-client (style &rest body)
  "Run BODY with the test client focused in STYLE, as surface 10 of `surface'."
  (declare (indent 1))
  `(progn
     (skip-unless ewm-xim-tests--client-binary)
     (ewm-xim-tests--with-server
       (let* ((ewm--surfaces (make-hash-table))
              (ewm-text-input-client-functions '(ewm-xim--deliver))
              (ewm-text-input--composing nil)
              (ewm-text-input--raw nil)
              (unread-command-events nil)
              (inhibit-message t)
              (surface (generate-new-buffer " *ewm-xim-client*"))
              (ewm-xim-tests--client
               (let ((process-environment
                      (append '("XMODIFIERS=@im=ewm-xim" "LC_ALL=C.UTF-8")
                              process-environment))
                     (process-connection-type nil))
                 (start-process "xim-client" (generate-new-buffer " *xim-client*")
                                ewm-xim-tests--client-binary ,style)))
              (ewm-xim-tests--xtest (xcb:connect ewm-xim-tests--display)))
         (set-process-query-on-exit-flag ewm-xim-tests--client nil)
         (set-process-coding-system ewm-xim-tests--client 'utf-8 'utf-8)
         (unwind-protect
             (cl-letf (((symbol-function 'ewm-get-focused-id) (lambda () 10)))
               (puthash 10 surface ewm--surfaces)
               (with-current-buffer surface
                 (ewm-surface-mode)
                 (setq ewm-surface-id 10))
               (xcb:keysyms:init ewm-xim-tests--xtest)
               (xcb:get-extension-data ewm-xim-tests--xtest 'xcb:xtest)
               (let ((xwin nil))
                 (with-timeout (10 (error "No client window"))
                   (while (not xwin)
                     (ewm-xim-tests--pump 0.05)
                     (with-current-buffer (process-buffer ewm-xim-tests--client)
                       (goto-char (point-min))
                       (when (re-search-forward "^window \\([0-9]+\\)$" nil t)
                         (setq xwin (string-to-number (match-string 1)))))))
                 (ewm-xim-tests--focus ewm-xim-tests--xtest xwin))
               (with-timeout (10 (error "The client made no input context"))
                 (while (zerop (hash-table-count ewm-xim--ics))
                   (ewm-xim-tests--pump 0.05)))
               ,@body)
           (when (process-live-p ewm-xim-tests--client)
             (delete-process ewm-xim-tests--client))
           (kill-buffer (process-buffer ewm-xim-tests--client))
           (xcb:disconnect ewm-xim-tests--xtest)
           (kill-buffer surface))))))

(defmacro ewm-xim-tests--with-skk (&rest body)
  "Run BODY with `ewm-skk-mode' on and DDSKK in buffer `surface'."
  (declare (indent 0))
  `(let ((ewm-text-input-key-functions nil)
         (ewm-text-input-surface-composer-functions nil)
         (ewm-text-input-deactivate-hook nil)
         (ewm-intercept-keys-filter-functions nil)
         (ewm-skk--converting nil))
     (ewm-skk-mode 1)
     (unwind-protect
         (progn
           (with-current-buffer surface (set-input-method "japanese-skk"))
           ,@body)
       (ewm-skk-mode -1))))

;;; Tests

(ert-deftest ewm-xim-styles-count-styles ()
  "The style list is counted in styles, as libX11 checks."
  (skip-unless ewm-xim-tests--have-xim)
  (let* ((xim:lsb t)
         (data (xcb:marshal (car (ewm-xim--attributes)))))
    ;; Attribute id, value length, then the XIMStyles count.
    (should (equal (append (substring data 0 6) nil) '(0 0 12 0 2 0)))))

(ert-deftest ewm-xim-lists-preedit-and-status-attributes ()
  "IC attributes Wine passes for the root-window style are listed.
libX11 fails XCreateIC on any attribute the server did not list."
  (skip-unless ewm-xim-tests--have-xim)
  (let ((names (mapcar (lambda (attr) (slot-value attr 'attribute))
                       (ewm-xim--ic-attrs))))
    (dolist (name '("inputStyle" "clientWindow" "focusWindow" "filterEvents"
                    "preeditAttributes" "statusAttributes" "fontSet"
                    "spotLocation"))
      (should (member name names)))))

(ert-deftest ewm-xim-answers-ic-values ()
  "GET_IC_VALUES answers the input style and the events to filter."
  (skip-unless ewm-xim-tests--have-xim)
  (let* ((xim:lsb t)
         (id (lambda (name)
               (cl-position name ewm-xim--ic-attr-table :key #'car :test #'equal)))
         (values (ewm-xim--ic-values (list (funcall id "filterEvents")
                                           (funcall id "inputStyle")
                                           (funcall id "fontSet")))))
    (should (equal (mapcar (lambda (v) (append (xcb:marshal v) nil)) values)
                   (list (list (funcall id "filterEvents") 0 4 0 3 0 0 0)
                         (list (funcall id "inputStyle") 0 4 0 8 4 0 0))))))

(ert-deftest ewm-xim-registers-server ()
  "The server is listed in XIM_SERVERS and owns its selection."
  (ewm-xim-tests--with-server
    (ewm-xim-tests--with-client conn
      (should (equal (ewm-xim-tests--servers conn) '("@server=ewm-xim")))
      (should (= (slot-value (xcb:+request-unchecked+reply conn
                                 (make-instance 'xcb:GetSelectionOwner
                                                :selection (ewm-xim-tests--intern
                                                            conn "@server=ewm-xim")))
                             'owner)
                 ewm-xim--event-xwin)))))

(ert-deftest ewm-xim-answers-queries ()
  "LOCALES and TRANSPORT get the answers XOpenIM looks for."
  (ewm-xim-tests--with-server
    (ewm-xim-tests--with-client conn
      (should (string-match-p "\\`@locale=.*\\bja\\b" (ewm-xim-tests--query conn "LOCALES")))
      (should (equal (ewm-xim-tests--query conn "TRANSPORT") "@transport=X/")))))

(ert-deftest ewm-xim-registers-once ()
  "Starting again keeps one entry, and other servers stay listed."
  (ewm-xim-tests--with-server
    (ewm-xim-tests--with-client conn
      (let ((other (ewm-xim-tests--intern conn "@server=other")))
        (xcb:+request conn
            (make-instance 'xcb:ChangeProperty
                           :mode xcb:PropMode:Append
                           :window (ewm-xim-tests--root conn)
                           :property (ewm-xim-tests--intern conn "XIM_SERVERS")
                           :type xcb:Atom:ATOM :format 32 :data-len 1
                           :data (funcall (if xcb:lsb #'xcb:-pack-u4-lsb #'xcb:-pack-u4)
                                          other)))
        (xcb:flush conn)
        (ewm-xim--register)
        (should (equal (ewm-xim-tests--servers conn)
                       '("@server=ewm-xim" "@server=other")))
        (ewm-xim--stop)
        (should (equal (ewm-xim-tests--servers conn) '("@server=other")))))))

(ert-deftest ewm-xim-stop-leaves-the-display ()
  "Stopping closes the connection and does not reconnect."
  (ewm-xim-tests--with-server
    (let ((conn ewm-xim--conn))
      (ewm-xim--stop)
      (should-not ewm-xim--conn)
      (should-not (slot-value conn 'connected))
      (sleep-for 0.3)
      (should-not ewm-xim--conn)
      (should-not ewm-xim--reconnect-timer))))

(ert-deftest ewm-xim-reconnects ()
  "When the display restarts the server registers on the new one."
  (ewm-xim-tests--with-server
    (ewm-xim-tests--stop-xvfb)
    (with-timeout (5 (error "The lost display went unnoticed"))
      (while ewm-xim--conn (accept-process-output nil 0.05)))
    (should ewm-xim--reconnect-timer)
    (let ((display ewm-xim-tests--display))
      (setq ewm-xim-tests--xvfb
            (start-process "xvfb" nil "Xvfb" display "-nolisten" "tcp"))
      (set-process-query-on-exit-flag ewm-xim-tests--xvfb nil))
    (with-timeout (10 (error "No reconnection"))
      (while (not ewm-xim--conn) (accept-process-output nil 0.05)))
    (ewm-xim-tests--with-client conn
      (should (equal (ewm-xim-tests--servers conn) '("@server=ewm-xim"))))))

(ert-deftest ewm-xim-gives-up ()
  "A display that never answers stops the retries."
  (skip-unless ewm-xim-tests--have-xim)
  (let ((process-environment (cons "DISPLAY=:139" process-environment))
        (ewm-xim-reconnect-delay 0.01)
        (inhibit-message t))
    (unwind-protect
        (progn
          (setq ewm-xim-mode t ewm-xim--failures 0)
          (ewm-xim--start)
          (with-timeout (5 (error "Still retrying"))
            (while (<= ewm-xim--failures ewm-xim--max-failures)
              (accept-process-output nil 0.02)))
          (should-not ewm-xim--reconnect-timer)
          (should-not ewm-xim--conn))
      (setq ewm-xim-mode nil)
      (ewm-xim--stop))))

(ert-deftest ewm-xim-xterm-keeps-plain-keys ()
  "With no input method, keys go back to the client as they were."
  (ewm-xim-tests--with-xterm
    (ewm-xim-tests--press "aB" 'return)
    (should (equal (ewm-xim-tests--wait-typed "aB\n") "aB\n"))
    (should (= (hash-table-count ewm-xim--clients) 1))))

(ert-deftest ewm-xim-xterm-types-skk ()
  "DDSKK commits kana and confirmed kanji; Return goes back as a key."
  (skip-unless ewm-xim-tests--have-skk)
  (ewm-xim-tests--with-xterm
    (let ((ewm-text-input-key-functions nil)
          (ewm-text-input-surface-composer-functions nil)
          (ewm-text-input-deactivate-hook nil)
          (ewm-intercept-keys-filter-functions nil)
          (ewm-skk--converting nil))
      (ewm-skk-mode 1)
      (unwind-protect
          (progn
            (with-current-buffer surface (set-input-method "japanese-skk"))
            (ewm-xim-tests--press "ka" "Nihon" ?\s)
            (should (equal ewm-xim--preedit "▼日本"))
            (ewm-xim-tests--press 'return)
            (should (equal (ewm-xim-tests--wait-typed "か日本\n") "か日本\n"))
            (should (equal ewm-xim--preedit "")))
        (ewm-skk-mode -1)))))

(ert-deftest ewm-xim-xterm-unfocus-drops-reading ()
  "A client losing focus mid-conversion drops the reading, typing nothing."
  (skip-unless ewm-xim-tests--have-skk)
  (ewm-xim-tests--with-xterm
    (let ((ewm-text-input-key-functions nil)
          (ewm-text-input-surface-composer-functions nil)
          (ewm-text-input-deactivate-hook nil)
          (ewm-intercept-keys-filter-functions nil)
          (ewm-skk--converting nil)
          (xwin (ewm-xim-tests--focused ewm-xim-tests--xtest)))
      (ewm-skk-mode 1)
      (unwind-protect
          (progn
            (with-current-buffer surface (set-input-method "japanese-skk"))
            (ewm-xim-tests--press "Nihon")
            (should (string-prefix-p "▽にほ" ewm-xim--preedit))
            (ewm-xim-tests--focus ewm-xim-tests--xtest xcb:InputFocus:None)
            (with-timeout (5 (error "The reading was kept"))
              (while (not (with-current-buffer surface (ewm-skk--idle-p)))
                (ewm-xim-tests--pump 0.05)))
            (should (equal ewm-xim--preedit ""))
            (ewm-xim-tests--focus ewm-xim-tests--xtest xwin)
            (ewm-xim-tests--pump 0.2)
            (ewm-xim-tests--press "a" 'return)
            (should (equal (ewm-xim-tests--wait-typed "あ\n") "あ\n")))
        (ewm-skk-mode -1)))))

(ert-deftest ewm-xim-xterm-unfocus-keeps-a-read ()
  "Focus leaving for the input method's own read keeps the reading."
  (skip-unless ewm-xim-tests--have-skk)
  (ewm-xim-tests--with-xterm
    (let ((ewm-text-input-key-functions nil)
          (ewm-text-input-surface-composer-functions nil)
          (ewm-text-input-deactivate-hook nil)
          (ewm-intercept-keys-filter-functions nil)
          (ewm-skk--converting nil))
      (ewm-skk-mode 1)
      (unwind-protect
          (progn
            (with-current-buffer surface (set-input-method "japanese-skk"))
            (ewm-xim-tests--press "Nihon")
            (let ((ewm-text-input--composing 10))
              (ewm-xim-tests--focus ewm-xim-tests--xtest xcb:InputFocus:None)
              (ewm-xim-tests--pump 0.5))
            (should-not (with-current-buffer surface (ewm-skk--idle-p))))
        (ewm-skk-mode -1)))))

(ert-deftest ewm-xim-offers-on-the-spot ()
  "Both styles are offered, preedit callbacks first."
  (skip-unless ewm-xim-tests--have-xim)
  (let ((styles (slot-value (slot-value (car (ewm-xim--attributes)) 'value) 'styles)))
    (should (equal styles (list ewm-xim--callback-style ewm-xim--root-style)))))

(ert-deftest ewm-xim-client-draws-the-preedit ()
  "An on-the-spot client draws the reading as it changes, then gets the commit."
  (skip-unless ewm-xim-tests--have-skk)
  (ewm-xim-tests--with-xim-client "callbacks"
    (should (= (ewm-xim--ic-style (car (hash-table-values ewm-xim--ics)))
               ewm-xim--callback-style))
    (ewm-xim-tests--with-skk
      (ewm-xim-tests--press "Ni")
      (should (ewm-xim-tests--wait-line "draw 2 0 2 ▽に"))
      (ewm-xim-tests--press "hon" ?\s)
      (should (ewm-xim-tests--wait-line "draw 3 0 4 ▼日本"))
      (ewm-xim-tests--press 'return)
      (should (ewm-xim-tests--wait-line "commit 日本"))
      ;; Nothing in the echo area, and the preedit ends before the commit.
      (should (equal ewm-xim--preedit ""))
      (let ((lines (seq-remove (lambda (line) (string-prefix-p "key " line))
                               (ewm-xim-tests--client-lines))))
        (should (equal (car lines) "start"))
        (should (equal (last lines 3) '("draw 0 0 3 " "done" "commit 日本")))))))

(ert-deftest ewm-xim-client-unfocus-ends-the-preedit ()
  "A field losing focus mid-conversion has its preedit ended."
  (skip-unless ewm-xim-tests--have-skk)
  (ewm-xim-tests--with-xim-client "callbacks"
    (ewm-xim-tests--with-skk
      (ewm-xim-tests--press "Ni")
      (should (ewm-xim-tests--wait-line "draw 2 0 2 ▽に"))
      (ewm-xim-tests--focus ewm-xim-tests--xtest xcb:InputFocus:None)
      (should (ewm-xim-tests--wait-line "done"))
      (should-not (ewm-xim--ic-preedit (car (hash-table-values ewm-xim--ics)))))))

(ert-deftest ewm-xim-client-root-style-uses-the-echo-area ()
  "A root-window client gets no preedit callbacks."
  (skip-unless ewm-xim-tests--have-skk)
  (ewm-xim-tests--with-xim-client "root"
    (ewm-xim-tests--with-skk
      (ewm-xim-tests--press "Ni")
      (should (equal ewm-xim--preedit "▽に"))
      (ewm-xim-tests--press 'return)
      (should (ewm-xim-tests--wait-line "commit に"))
      (should-not (member "start" (ewm-xim-tests--client-lines))))))

(ert-deftest ewm-xim-client-types-quail ()
  "A quail input method composes for an XIM client too."
  (skip-unless ewm-xim-tests--client-binary)
  (ewm-xim-tests--with-xim-client "callbacks"
    (let ((ewm-text-input-key-functions nil)
          (ewm-text-input-surface-composer-functions nil))
      (with-current-buffer surface (activate-input-method "latin-1-postfix"))
      ;; Batch quail reads its later keys from the queue, not from stdin,
      ;; so they are all in before it starts.  Batch has no redisplay,
      ;; hence no preedit.
      (cl-letf (((symbol-function 'ewm-xim-tests--pump)
                 (lambda (seconds)
                   (let ((end (+ (float-time) seconds)))
                     (while (< (float-time) end)
                       (accept-process-output nil 0.02))))))
        (ewm-xim-tests--press "a'b"))
      (should (equal (mapcar #'car-safe unread-command-events)
                     '(ewm-text-input-key no-record no-record)))
      (let ((last-input-event (pop unread-command-events)))
        (ewm-text-input--compose))
      (should (ewm-xim-tests--wait-line "commit á"))
      (should (ewm-xim-tests--wait-line "commit b")))))

(ert-deftest ewm-xim-xterm-client-goes-away ()
  "A client that exits leaves no client or input context behind."
  (ewm-xim-tests--with-xterm
    (delete-process xterm)
    (with-timeout (5 (error "The client was kept"))
      (while (> (hash-table-count ewm-xim--clients) 0)
        (ewm-xim-tests--pump 0.05)))
    (should (zerop (hash-table-count ewm-xim--ics)))))

(provide 'ewm-xim-tests)
;;; ewm-xim-tests.el ends here
