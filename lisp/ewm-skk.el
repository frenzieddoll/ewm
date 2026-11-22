;;; ewm-skk.el --- DDSKK input for Wayland text fields -*- lexical-binding: t -*-

;; Copyright (C) 2026 Evgeny Zemtsov
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; DDSKK is not a quail method: `input-method-function' is `list' and the
;; conversion lives in `skk-j-mode-map' commands that edit the buffer.  The
;; quail relay in ewm-text-input.el therefore commits raw letters.
;;
;; With `ewm-skk-mode' on, keys for a surface whose buffer has `skk-mode' run
;; there as commands: looked up in the buffer's keymaps and executed between
;; `pre-command-hook' and `post-command-hook', as the command loop would.  The
;; surface buffer then only ever holds text DDSKK has not confirmed:
;;
;;   - text before the ▽/▼ mark (or all of it, with no conversion) is
;;     confirmed, so it is committed to the client and deleted;
;;   - the rest, plus a pending romaji prefix, is shown as preedit.
;;
;; A key nothing is composing for, other than text and `ewm-skk-keys', goes
;; to the client untouched, so Return, Backspace and shortcuts behave as
;; before when no conversion is under way.
;;
;; The compositor emulates `ewm-surface-emulate-keys' and runs `ewm-mode-map'
;; keys before text input sees them, so C-m as Return would let the client
;; take its preedit as typed text.  While ▽/▼ is open the focused surface's
;; emulations, and `ewm-mode-map' keys bound to DDSKK commands, are not
;; intercepted; emulations are then applied here instead.
;;
;; Usage:
;;   (require 'ewm-skk)
;;   (ewm-skk-mode 1)
;; then turn on japanese-skk (C-\) or `skk-mode' in an app's buffer.

;;; Code:

(require 'cl-lib)
(require 'ewm-text-input)
(require 'ewm-input)

(defvar skk-mode)
(defvar skk-henkan-mode)
(defvar skk-henkan-start-point)
(defvar skk-prefix-overlay)
(declare-function skk-henkan-inactivate "skk")
(declare-function skk-henkan-off-by-quit "skk")
(declare-function skk-erase-prefix "skk-macs")
(declare-function skk-kakutei "skk")

(defcustom ewm-skk-keys '(?\C-j)
  "Non-text keys DDSKK reads on an SKK surface even with nothing composing.
`C-j' must reach DDSKK to leave latin mode.  Other non-text keys go to the
client unless a conversion is under way."
  :type '(repeat sexp)
  :group 'ewm-input-methods)

(defcustom ewm-skk-commands
  '(keyboard-quit newline delete-backward-char backward-delete-char-untabify
    self-insert-command)
  "Non-SKK commands a key may run while a conversion is under way.
Commands named skk-* always run.  Any other key confirms the conversion,
then goes to the client."
  :type '(repeat symbol)
  :group 'ewm-input-methods)

(defconst ewm-skk--key-translations
  '((backspace . ?\d) (return . ?\r) (kp-enter . ?\r) (tab . ?\t)
    (escape . ?\e) (delete . ?\d))
  "Function keys as the ASCII keys `local-function-key-map' turns them into.")

(defconst ewm-skk--marks '(?▽ ?▼)
  "Characters DDSKK puts before the text it is converting.")

(defvar-local ewm-skk--last-command nil
  "The `this-command' of the last key DDSKK ran in this surface buffer.")

(defvar-local ewm-skk--preedit ""
  "Text last shown as preedit for this surface buffer's field.")

(defvar ewm-skk--running nil
  "Surface buffer DDSKK is running a key in, else nil.")

(defvar ewm-skk--depth 0
  "Minibuffer depth when DDSKK started the running key.")

(defvar ewm-skk--converting nil
  "Surface buffer in ▽/▼ whose intercepted keys are lifted, else nil.")

;;; State

(defun ewm-skk--surface-p (buffer)
  "Non-nil when BUFFER is a live surface buffer in `skk-mode'."
  (and (buffer-live-p buffer)
       (buffer-local-value 'ewm-surface-id buffer)
       (with-current-buffer buffer (bound-and-true-p skk-mode))))

(defun ewm-skk--prefix ()
  "The romaji DDSKK is still reading, as displayed, or nil."
  (when-let* ((ov (bound-and-true-p skk-prefix-overlay))
              ((overlayp ov))
              ((eq (overlay-buffer ov) (current-buffer)))
              (text (overlay-get ov 'after-string))
              ((not (string-empty-p text))))
    text))

(defun ewm-skk--idle-p ()
  "Non-nil when DDSKK holds nothing unconfirmed in the current buffer."
  (and (not (bound-and-true-p skk-henkan-mode))
       (not (ewm-skk--prefix))
       (= (point-min) (point-max))))

(defun ewm-skk--boundary ()
  "Position before which the current buffer's text is confirmed."
  (let ((start (and (bound-and-true-p skk-henkan-mode)
                    (markerp skk-henkan-start-point)
                    (marker-position skk-henkan-start-point))))
    (cond ((null start) (point-max))
          ((memq (char-before start) ewm-skk--marks) (1- start))
          (t start))))

(defun ewm-skk--preedit-text ()
  "The current buffer's unconfirmed text with the pending romaji in place."
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (if-let* ((prefix (ewm-skk--prefix))
              (at (- (overlay-start skk-prefix-overlay) (point-min)))
              ((<= 0 at (length text))))
        (concat (substring text 0 at) (substring-no-properties prefix)
                (substring text at))
      text)))

;;; Talking to the client

(defun ewm-skk--emulation (key)
  "Keys the current surface's `ewm-surface-emulate-keys' sends for KEY, or nil."
  (cl-loop for (from . to) in (append ewm-surface-emulate-keys
                                      (default-value 'ewm-surface-emulate-keys))
           when (and (not (symbolp from)) (eql (ewm--key-event from) key))
           return to))

(defun ewm-skk--return-p (key)
  "Non-nil when KEY is Return."
  (memq key '(?\r return kp-enter)))

(defun ewm-skk--show-preedit (surface-id text)
  "Show TEXT as SURFACE-ID's preedit unless it already shows."
  (unless (equal text ewm-skk--preedit)
    (setq ewm-skk--preedit text)
    (ewm-im-preedit text surface-id)))

(defun ewm-skk--forward (surface-id key raw)
  "Hand KEY, compositor key RAW, to SURFACE-ID's client, clearing the preedit.
An emulated KEY sends what it emulates, as the compositor would have."
  (ewm-skk--show-preedit surface-id "")
  (if-let* ((to (and key (ewm-skk--emulation key))))
      (ewm-send-key to surface-id)
    (when raw (ewm-text-input--forward-key raw))))

(defun ewm-skk--commit (surface-id text key raw)
  "Commit confirmed TEXT to SURFACE-ID.
A newline that Return KEY (compositor key RAW) produced is typed as
Return, so the field handles it as a key, not as inserted text."
  (let ((lines (split-string text "\n")))
    (while lines
      (unless (string-empty-p (car lines))
        ;; A commit replaces the preedit.
        (setq ewm-skk--preedit "")
        (ewm-im-commit (car lines) surface-id))
      (when (cdr lines)
        (if (ewm-skk--return-p key)
            (ewm-skk--forward surface-id key raw)
          (setq ewm-skk--preedit "")
          (ewm-im-commit "\n" surface-id)))
      (pop lines))))

(defun ewm-skk--flush (surface-id key raw)
  "Send what DDSKK confirmed to SURFACE-ID and show the rest as preedit.
KEY, compositor key RAW, is the key DDSKK just ran."
  (let* ((end (ewm-skk--boundary))
         (text (buffer-substring-no-properties (point-min) end)))
    (let ((inhibit-modification-hooks t))
      (delete-region (point-min) end))
    (ewm-skk--commit surface-id text key raw)
    (ewm-skk--show-preedit surface-id (ewm-skk--preedit-text))
    (ewm-skk--track-conversion)))

;;; Lifting intercepted keys mid-conversion

(defun ewm-skk--resend-intercepts ()
  "Tell the compositor which keys to intercept now."
  (when ewm--module-mode (ewm--send-intercept-keys)))

(defun ewm-skk--track-conversion ()
  "Lift intercepted keys while the current buffer converts, restore them after."
  (let ((converting (cond ((bound-and-true-p skk-henkan-mode) (current-buffer))
                          ((eq ewm-skk--converting (current-buffer)) nil)
                          (t ewm-skk--converting))))
    (unless (eq converting ewm-skk--converting)
      (setq ewm-skk--converting converting)
      (ewm-skk--resend-intercepts))))

(defun ewm-skk--lifted-p (spec)
  "Non-nil when intercept SPEC must reach DDSKK in the converting surface.
That is every emulation in its scope, `ewm-mode-map' keys it binds to
DDSKK commands, and `ewm-mode-map' keys its emulations shadow: with the
emulation lifted, C-h would otherwise take the keyboard to Emacs, and the
client would keep its preedit as typed text."
  (when-let* ((buf ewm-skk--converting)
              ((buffer-live-p buf)))
    (let ((dispatch (plist-get spec :dispatch))
          (surface (plist-get spec :surface)))
      (if (eq (car-safe dispatch) 'emulate)
          (or (null surface)
              (eql surface (buffer-local-value 'ewm-surface-id buf)))
        (when-let* ((key (ewm--key-event (plist-get spec :description))))
          (with-current-buffer buf
            (or (ewm-skk--emulation key)
                (and (eq dispatch 'command)
                     (ewm-skk--skk-command-p (ewm-skk--binding key))))))))))

;;; Running keys

(defun ewm-skk--binding (key)
  "The command KEY runs in the current buffer, or nil."
  (let* ((key (alist-get key ewm-skk--key-translations key))
         (cmd (key-binding (vector key) t)))
    (and (commandp cmd) cmd)))

(defun ewm-skk--skk-command-p (cmd)
  "Non-nil when CMD belongs to DDSKK or to `ewm-skk-commands'."
  (and (symbolp cmd)
       (or (string-prefix-p "skk-" (symbol-name cmd))
           (memq cmd ewm-skk-commands))))

(defun ewm-skk--run-hook (hook)
  "Run HOOK, reporting instead of raising its errors."
  (condition-case err
      (run-hooks hook)
    (error (message "ewm-skk: %s: %s" hook (error-message-string err)))))

(defun ewm-skk--execute (key &optional cmd)
  "Run CMD, else what KEY is bound to, in the current buffer.
It runs as the command loop would, with KEY as the key that invoked it."
  (let* ((event (alist-get key ewm-skk--key-translations key))
         (keys (vector event))
         (cmd (or cmd (ewm-skk--binding key))))
    (when cmd
      (let ((last-command ewm-skk--last-command)
            (this-command cmd)
            (real-this-command cmd)
            (this-original-command cmd)
            (last-command-event event)
            (last-nonmenu-event event)
            (current-prefix-arg nil)
            (deactivate-mark nil))
        ;; DDSKK replays a key's original binding from `this-command-keys'.
        (when (characterp event)
          (set--this-command-keys (string event)))
        ;; The flush that follows reads this buffer, wherever CMD went.
        (save-current-buffer
          (ewm-skk--run-hook 'pre-command-hook)
          (condition-case err
              (command-execute cmd nil keys)
            ;; DDSKK quits or errors where the command loop would beep.
            (quit nil)
            (error (message "%s" (error-message-string err))))
          (ewm-skk--run-hook 'post-command-hook))
        (setq ewm-skk--last-command this-command)))))

(defun ewm-skk--handed-back ()
  "Remove and return the plain events DDSKK unread, oldest first.
Compositor keys are queued as conses; a bare event can only come
from the input method handing a key back."
  (let (handed kept)
    (dolist (ev unread-command-events)
      (if (consp ev) (push ev kept) (push ev handed)))
    (setq unread-command-events (nreverse kept))
    (nreverse handed)))

(defun ewm-skk--effective-key (key)
  "KEY, or the key it emulates when only that one means something to DDSKK.
So C-h emulating Backspace deletes in the reading."
  (if (ewm-skk--skk-command-p (ewm-skk--binding key))
      key
    (let ((to (and (ewm-skk--emulation key)
                   (ewm--key-event (ewm-skk--emulation key)))))
      (if (and to (ewm-skk--skk-command-p (ewm-skk--binding to))) to key))))

(defun ewm-skk--key (surface-id key raw)
  "Give KEY (compositor key RAW) to DDSKK in the current surface buffer."
  (cond
   ;; The field went away under a read; `ewm-skk--input' cleans up.
   ((eq key 'ewm-text-input-abort))
   ((null key) (ewm-skk--forward surface-id nil raw))
   (t
    (let ((run (cond ((or (ewm-text-input--text-p key) (member key ewm-skk-keys)) key)
                     ((not (ewm-skk--idle-p))
                      (let ((eff (ewm-skk--effective-key key)))
                        (and (ewm-skk--skk-command-p (ewm-skk--binding eff)) eff))))))
      (cond
       (run
        (ewm-skk--execute run)
        (ewm-skk--flush surface-id key raw))
       ((ewm-skk--idle-p) (ewm-skk--forward surface-id key raw))
       (t
        ;; Leaving the conversion for another key confirms it, as `C-j' does.
        (ewm-skk--execute ?\C-j #'skk-kakutei)
        (ewm-skk--flush surface-id nil nil)
        (ewm-skk--forward surface-id key raw)))))))

(defun ewm-skk--minibuffer-setup ()
  "Clear the client's preedit before DDSKK's minibuffer takes the focus.
A client losing focus may keep its preedit as typed text."
  (when (and (buffer-live-p ewm-skk--running)
             (= (minibuffer-depth) (1+ ewm-skk--depth)))
    (with-current-buffer ewm-skk--running
      (ewm-skk--show-preedit ewm-surface-id ""))))

(defun ewm-skk--preedit-sync (_window)
  "Before a redisplay mid-command, show the client what DDSKK has so far."
  (when-let* ((surface-id ewm-text-input--composing)
              ;; Not while DDSKK's minibuffer holds the focus.
              ((= (minibuffer-depth) ewm-skk--depth))
              (buf (ewm--surface-buffer surface-id))
              ((ewm-skk--surface-p buf)))
    (with-current-buffer buf
      (ewm-skk--show-preedit surface-id (ewm-skk--preedit-text)))))

(defun ewm-skk--adopt-queued (surface-id)
  "Turn the keys queued for SURFACE-ID's DDSKK into keys it reads.
Done before DDSKK runs, so a read it makes mid-command (a candidate
list) gets them as keys rather than running them reentrantly."
  (let (adopted)
    (while (pcase (car unread-command-events)
             (`(ewm-skk-key ,(pred (eql surface-id)) ,key ,raw)
              (pop unread-command-events)
              (if key
                  (push (cons (cons 'no-record key) raw) adopted)
                ;; A read cannot take a key Emacs has no name for.
                (ewm-text-input--forward-key raw))
              t)))
    (setq adopted (nreverse adopted))
    (setq ewm-text-input--raw (nconc (mapcar #'cdr adopted) ewm-text-input--raw))
    (setq unread-command-events
          (nconc (mapcar #'car adopted) unread-command-events))))

(defun ewm-skk--input (surface-id key raw)
  "Run KEY, compositor key RAW, through DDSKK on SURFACE-ID's buffer.
Keys DDSKK reads or hands back meanwhile run there too."
  (let ((buf (ewm--surface-buffer surface-id)))
    (if (not (ewm-skk--surface-p buf))
        ;; DDSKK went off while the key was queued.
        (when raw (ewm-text-input--forward-key raw))
      (with-current-buffer buf
        ;; A key DDSKK reads mid-command (a candidate list) arrives while
        ;; composing, so `ewm--handle-key' queues it for that read.  The
        ;; field going away clears this.
        (let ((ewm-text-input--composing surface-id)
              (ewm-skk--running buf)
              (ewm-skk--depth (minibuffer-depth))
              (minibuffer-setup-hook
               (cons #'ewm-skk--minibuffer-setup minibuffer-setup-hook))
              ;; Unconfirmed text is preedit, not an insertion to commit.
              (after-change-functions nil)
              (pre-redisplay-functions
               (cons #'ewm-skk--preedit-sync pre-redisplay-functions)))
          (ewm-skk--adopt-queued surface-id)
          (ewm-skk--key surface-id key raw)
          (while (and ewm-text-input--composing (buffer-live-p buf))
            (let ((handed (ewm-skk--handed-back)))
              (cond
               (handed
                (dolist (ev handed)
                  (ewm-skk--key surface-id ev (ewm-text-input--raw-key ev))))
               ((eq (car-safe (car unread-command-events)) 'no-record)
                (let ((ev (cdr (pop unread-command-events))))
                  (ewm-skk--key surface-id ev (ewm-text-input--raw-key ev))))
               (t (setq ewm-text-input--composing nil
                        ewm-skk--running nil)))))
          (setq ewm-text-input--raw nil)
          (when (and ewm-skk--running (buffer-live-p buf))
            ;; The field went away: its keys and unconfirmed text die with it.
            (ewm-skk--handed-back)
            (while (eq (car-safe (car unread-command-events)) 'no-record)
              (pop unread-command-events))
            (ewm-skk--abandon)))))))

(defun ewm-skk--compose ()
  "Run DDSKK for the key in `last-input-event'."
  (interactive)
  (pcase-let ((`(,_ ,surface-id ,key ,raw) last-input-event))
    (cond
     ((not ewm-skk--running) (ewm-skk--input surface-id key raw))
     ;; A read inside DDSKK met a key queued before it: hand the key to
     ;; that read, as the oldest one waiting.
     (key (push raw ewm-text-input--raw)
          (push (cons 'no-record key) unread-command-events))
     (t (ewm-text-input--forward-key raw)))))

(defun ewm-skk--pending-p ()
  "Non-nil when a key queued for DDSKK has yet to run."
  (seq-some (lambda (event) (eq (car-safe event) 'ewm-skk-key))
            unread-command-events))

(defun ewm-skk--handle-key (event key surface-buf)
  "Queue compositor EVENT (Emacs KEY) for DDSKK when SURFACE-BUF is in SKK.
Keys go through the queue in order once one waits there; otherwise only
keys DDSKK may want do, and the rest reach the client at once."
  (when (and (ewm-skk--surface-p surface-buf)
             (or (ewm-skk--pending-p)
                 (and key
                      (or (ewm-text-input--text-p key)
                          (member key ewm-skk-keys)
                          (not (with-current-buffer surface-buf
                                 (ewm-skk--idle-p)))))))
    (setq unread-command-events
          (nconc unread-command-events
                 (list (list 'ewm-skk-key (alist-get 'surface_id event)
                             key event))))
    t))

(defun ewm-skk--abandon ()
  "Drop the current buffer's unfinished conversion without learning it."
  (let ((after-change-functions nil))
    (condition-case err
        (progn
          (when (eq skk-henkan-mode 'active) (skk-henkan-inactivate))
          (when (eq skk-henkan-mode 'on) (skk-henkan-off-by-quit))
          (skk-erase-prefix 'clean))
      (error (message "ewm-skk: %s" (error-message-string err))))
    (let ((inhibit-modification-hooks t))
      (erase-buffer))
    (setq ewm-skk--preedit "")
    (ewm-skk--track-conversion)))

(defun ewm-skk--field-gone ()
  "Abandon every SKK surface's conversion: its field went away."
  (maphash
   (lambda (_id buf)
     ;; A buffer mid-key is abandoned once DDSKK returns.
     (when (and (not (eq buf ewm-skk--running))
                (ewm-skk--surface-p buf)
                (not (with-current-buffer buf (ewm-skk--idle-p))))
       (with-current-buffer buf (ewm-skk--abandon))))
   ewm--surfaces))

(defun ewm-skk--composer-p ()
  "Non-nil when the current surface buffer is in `skk-mode'."
  (bound-and-true-p skk-mode))

(defun ewm-skk--refresh (&rest _)
  "Recheck interception after `skk-mode' toggled."
  (when ewm-text-input-auto-mode
    (ewm-text-input--refresh-auto-state)))

(define-key special-event-map [ewm-skk-key] #'ewm-skk--compose)

;;;###autoload
(define-minor-mode ewm-skk-mode
  "Type into Wayland text fields with DDSKK.
Surfaces whose buffer has `skk-mode' on convert in Emacs and show the
reading as preedit; other surfaces keep the plain input method relay."
  :global t
  :group 'ewm-input-methods
  (let ((add (if ewm-skk-mode #'add-hook #'remove-hook)))
    (funcall add 'ewm-text-input-key-functions #'ewm-skk--handle-key)
    (funcall add 'ewm-text-input-surface-composer-functions #'ewm-skk--composer-p)
    (funcall add 'ewm-text-input-deactivate-hook #'ewm-skk--field-gone)
    (funcall add 'ewm-intercept-keys-filter-functions #'ewm-skk--lifted-p))
  (unless ewm-skk-mode
    (when ewm-skk--converting
      (setq ewm-skk--converting nil)
      (ewm-skk--resend-intercepts)))
  (if ewm-skk-mode
      (advice-add 'skk-mode :after #'ewm-skk--refresh)
    (advice-remove 'skk-mode #'ewm-skk--refresh))
  (ewm-skk--refresh))

(provide 'ewm-skk)
;;; ewm-skk.el ends here
