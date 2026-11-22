;;; ewm-xim.el --- XIM server for Xwayland clients -*- lexical-binding: t -*-

;; Copyright (C) 2026 Evgeny Zemtsov
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Ported from EXWM's `exwm-xim.el':
;; Copyright (C) 2019-2025 Free Software Foundation, Inc.
;; Author: Chris Feng <chris.w.feng@gmail.com>

;;; Commentary:

;; X clients under xwayland-satellite never see text-input-v3, so Emacs
;; input methods only reach them through XIM.  This module makes Emacs an
;; XIM server on the Xwayland display, over XELB, which it needs only once
;; `ewm-xim-mode' is on.
;;
;; The server takes the "@server=NAME" selection and lists it in the root
;; window's XIM_SERVERS, then answers the LOCALES and TRANSPORT queries a
;; client makes before connecting.  Like EXWM it offers transport 0.0 over
;; the X connection, static event flow and the root-window style only: the
;; client forwards every key press, and the server types it back or
;; commits text in its place.
;;
;; A forwarded key is answered at once, so the client never waits on Emacs,
;; and becomes a compositor key event for the focused surface.  When that
;; surface's buffer has an input method (or a composer such as ewm-skk) the
;; event goes through `ewm--handle-key' like a text-input key; what the
;; method commits, shows as preedit or hands back then returns over XIM, by
;; `ewm-text-input-client-functions'.  Other keys go straight back.  The
;; root-window style has no preedit in the client, so it shows in the echo
;; area.  A field losing focus runs `ewm-text-input-deactivate-hook', as a
;; text-input field does, so its unconfirmed text is dropped.
;;
;; xwayland-satellite starts on the first X connection, and connecting here
;; is one: the server brings Xwayland up when EWM is ready, so clients find
;; it from their first `XOpenIM'.  If Xwayland goes away the server
;; reconnects, which starts it again.
;;
;; Usage:
;;   (require 'ewm-xim)
;;   (ewm-xim-mode 1)
;; then run X clients with XMODIFIERS=@im=ewm-xim (and GTK_IM_MODULE=xim
;; for GTK).

;;; Code:

(require 'cl-lib)
(require 'xcb)
(require 'xcb-keysyms)
(require 'xcb-xim)
(require 'ewm-text-input)

(defvar ewm-mode)

(defcustom ewm-xim-server-name "ewm-xim"
  "Name X clients select the server by, as in XMODIFIERS=@im=NAME."
  :type 'string
  :group 'ewm-input-methods)

(defcustom ewm-xim-reconnect-delay 2
  "Seconds before reconnecting to an Xwayland display that went away."
  :type 'number
  :group 'ewm-input-methods)

(defconst ewm-xim--locales
  "@locale=\
aa,af,ak,am,an,anp,ar,as,ast,ayc,az,be,bem,ber,bg,bhb,bho,bn,bo,br,brx,bs,byn,\
ca,ce,cmn,crh,cs,csb,cv,cy,da,de,doi,dv,dz,el,en,es,et,eu,fa,ff,fi,fil,fo,fr,\
fur,fy,ga,gd,gez,gl,gu,gv,ha,hak,he,hi,hne,hr,hsb,ht,hu,hy,ia,id,ig,ik,is,it,\
iu,iw,ja,ka,kk,kl,km,kn,ko,kok,ks,ku,kw,ky,lb,lg,li,li,lij,lo,lt,lv,lzh,mag,\
mai,mg,mhr,mi,mk,ml,mn,mni,mr,ms,mt,my,nan,nb,nds,ne,nhn,niu,nl,nn,nr,nso,oc,\
om,or,os,pa,pa,pap,pl,ps,pt,quz,raj,ro,ru,rw,sa,sat,sc,sd,se,shs,si,sid,sk,sl,\
so,sq,sr,ss,st,sv,sw,szl,ta,tcy,te,tg,th,the,ti,tig,tk,tl,tn,tr,ts,tt,ug,uk,\
unm,ur,uz,ve,vi,wa,wae,wal,wo,xh,yi,yo,yue,zh,zu,\
C,no"
  "Locales the server accepts (glibc's).")

(defconst ewm-xim--atom-names
  '(LOCALES TRANSPORT XIM_SERVERS _XIM_PROTOCOL _XIM_XCONNECT)
  "Atoms the protocol needs besides the server's own.")

(defvar ewm-xim--conn nil
  "X connection the server listens on, else nil.")

(defvar ewm-xim--root nil
  "Root window of `ewm-xim--conn'.")

(defvar ewm-xim--event-xwin nil
  "Window owning the server selection.")

(defvar ewm-xim--atoms nil
  "Alist of atom symbol to atom on `ewm-xim--conn'.
`server' is the \"@server=NAME\" selection.")

(defvar ewm-xim--reconnect-timer nil
  "Timer that connects to the display again, else nil.")

(defvar ewm-xim--failures 0
  "Connection attempts in a row that failed or did not last.")

(defvar ewm-xim--connected-at nil
  "When `ewm-xim--conn' was made.")

(cl-defstruct (ewm-xim--client (:constructor ewm-xim--client-create))
  "An XIM client, talking to the server through its own window pair."
  server-xwin client-xwin lsb)

(cl-defstruct (ewm-xim--ic (:constructor ewm-xim--ic-create))
  "An input context of CLIENT."
  client im-id ic-id)

(cl-defstruct (ewm-xim--key (:constructor ewm-xim--key-create))
  "A key press IC forwarded: its serial number and raw EVENT bytes."
  ic serial event)

(defvar ewm-xim--clients (make-hash-table)
  "Server window -> `ewm-xim--client'.")

(defvar ewm-xim--ics (make-hash-table)
  "IC id -> `ewm-xim--ic'.")

(defvar ewm-xim--surface-ics (make-hash-table)
  "Surface id -> the `ewm-xim--ic' its keys last came from.")

(defvar ewm-xim--im-id 0 "Last IM id.")
(defvar ewm-xim--ic-id 0 "Last IC id.")

(defvar ewm-xim--properties (make-vector 64 nil)
  "Atoms of the properties long requests travel in, interned on use.")

(defvar ewm-xim--property-index 0
  "Next slot of `ewm-xim--properties'.")

(defvar ewm-xim--preedit ""
  "Preedit last shown in the echo area.")

(defconst ewm-xim--max-failures 5
  "Attempts in a row after which the server stops reconnecting.")

(defconst ewm-xim--stable-time 10
  "Seconds a connection must live to reset `ewm-xim--failures'.")

(defvar ewm-xim-mode)

;;; X helpers

(defun ewm-xim--atom (name)
  "The atom for NAME, a symbol from `ewm-xim--atoms'."
  (alist-get name ewm-xim--atoms))

(defun ewm-xim--intern (conn name)
  "Intern atom NAME, a string, on CONN."
  (slot-value (xcb:+request-unchecked+reply conn
                  (make-instance 'xcb:InternAtom
                                 :only-if-exists 0
                                 :name-len (length name)
                                 :name name))
              'atom))

(defun ewm-xim--pack-atoms (atoms)
  "ATOMS as the bytes of a format 32 property."
  (let ((pack (if xcb:lsb #'xcb:-pack-u4-lsb #'xcb:-pack-u4)))
    (apply #'vconcat (mapcar pack atoms))))

(defun ewm-xim--unpack-atoms (bytes)
  "The atoms in BYTES, a format 32 property value."
  (let ((bytes (vconcat bytes))
        (unpack (if xcb:lsb #'xcb:-unpack-u4-lsb #'xcb:-unpack-u4)))
    (cl-loop for i from 0 below (/ (length bytes) 4)
             collect (funcall unpack bytes (* i 4)))))

(defun ewm-xim--servers ()
  "The atoms in the root window's XIM_SERVERS."
  (when-let* ((reply (xcb:+request-unchecked+reply ewm-xim--conn
                         (make-instance 'xcb:GetProperty
                                        :delete 0
                                        :window ewm-xim--root
                                        :property (ewm-xim--atom 'XIM_SERVERS)
                                        :type xcb:Atom:ATOM
                                        :long-offset 0
                                        :long-length 1000))))
    (ewm-xim--unpack-atoms (slot-value reply 'value))))

(defun ewm-xim--set-servers (atoms)
  "Make ATOMS the root window's XIM_SERVERS."
  (xcb:+request ewm-xim--conn
      (make-instance 'xcb:ChangeProperty
                     :mode xcb:PropMode:Replace
                     :window ewm-xim--root
                     :property (ewm-xim--atom 'XIM_SERVERS)
                     :type xcb:Atom:ATOM
                     :format 32
                     :data-len (length atoms)
                     :data (ewm-xim--pack-atoms atoms))))

;;; Locales and transport

(defun ewm-xim--on-SelectionRequest (data _synthetic)
  "Answer a client's LOCALES or TRANSPORT query, SelectionRequest DATA."
  (let ((evt (make-instance 'xcb:SelectionRequest)))
    (xcb:unmarshal evt data)
    (with-slots (time requestor selection target property) evt
      (when-let* ((value (cond ((= target (ewm-xim--atom 'LOCALES))
                                ewm-xim--locales)
                               ((= target (ewm-xim--atom 'TRANSPORT))
                                ;; XIM over an X connection.
                                "@transport=X/"))))
        (xcb:+request ewm-xim--conn
            (make-instance 'xcb:ChangeProperty
                           :mode xcb:PropMode:Replace
                           :window requestor
                           :property property
                           :type target
                           :format 8
                           :data-len (length value)
                           :data value))
        (xcb:+request ewm-xim--conn
            (make-instance 'xcb:SendEvent
                           :propagate 0
                           :destination requestor
                           :event-mask xcb:EventMask:NoEvent
                           :event (xcb:marshal
                                      (make-instance 'xcb:SelectionNotify
                                                     :time time
                                                     :requestor requestor
                                                     :selection selection
                                                     :target target
                                                     :property property)
                                      ewm-xim--conn)))
        (xcb:flush ewm-xim--conn)))))

;;; Talking to clients

(defun ewm-xim--property ()
  "An atom for the next long request's property."
  (let ((i ewm-xim--property-index))
    (setq ewm-xim--property-index (% (1+ i) (length ewm-xim--properties)))
    (or (aref ewm-xim--properties i)
        (aset ewm-xim--properties i
              (ewm-xim--intern ewm-xim--conn (format "_EWM_XIM_%d" i))))))

(defun ewm-xim--send (req client)
  "Send XIM request REQ to CLIENT.
Short requests travel in the client message, long ones in a property."
  (let* ((client-xwin (ewm-xim--client-client-xwin client))
         (data (append (xcb:marshal req) nil))
         (short (<= (length data) 20))
         (msg-data
          (if short
              (make-instance 'xcb:ClientMessageData
                             :data8 (append data (make-list (- 20 (length data)) 0)))
            (let ((property (ewm-xim--property)))
              (xcb:+request ewm-xim--conn
                  (make-instance 'xcb:ChangeProperty
                                 :mode xcb:PropMode:Append
                                 :window client-xwin
                                 :property property
                                 :type xcb:Atom:STRING
                                 :format 8
                                 :data-len (length data)
                                 ;; A list here would be marshalled as objects.
                                 :data (vconcat data)))
              (make-instance 'xcb:ClientMessageData
                             :data32 (list (length data) property 0 0 0))))))
    (xcb:+request ewm-xim--conn
        (make-instance 'xcb:SendEvent
                       :propagate 0
                       :destination client-xwin
                       :event-mask xcb:EventMask:NoEvent
                       :event (xcb:marshal
                                  (make-instance 'xcb:ClientMessage
                                                 :format (if short 8 32)
                                                 :window client-xwin
                                                 :type (ewm-xim--atom '_XIM_PROTOCOL)
                                                 :data msg-data)
                                  ewm-xim--conn)))))

(defun ewm-xim--error (&optional im-id ic-id)
  "An XIM error for IM-ID and IC-ID."
  (make-instance 'xim:error
                 :im-id (or im-id 0)
                 :ic-id (or ic-id 0)
                 :flag (cond (ic-id xim:error-flag:invalid-ic-id)
                             (im-id xim:error-flag:invalid-im-id)
                             (t xim:error-flag:invalid-both))
                 :error-code xim:error-code:bad-something
                 :length 0
                 :type 0
                 :detail nil))

(defun ewm-xim--im-attrs ()
  "IM attributes: the input styles."
  (list (make-instance 'xim:XIMATTR
                       :id 0
                       :type xim:ATTRIBUTE-VALUE-TYPE:xim-styles
                       :length (length xlib:XNQueryInputStyle)
                       :attribute xlib:XNQueryInputStyle)))

(defconst ewm-xim--ic-attr-table
  `((,xlib:XNInputStyle . ,xim:ATTRIBUTE-VALUE-TYPE:long-data)
    (,xlib:XNClientWindow . ,xim:ATTRIBUTE-VALUE-TYPE:window)
    ;; Required by e.g. xterm.
    (,xlib:XNFocusWindow . ,xim:ATTRIBUTE-VALUE-TYPE:window)
    ("filterEvents" . ,xim:ATTRIBUTE-VALUE-TYPE:long-data)
    ;; Wine passes preedit and status lists even for the root-window
    ;; style, and libX11 fails XCreateIC on any attribute the server did
    ;; not list.  The values are accepted and ignored.
    ("preeditAttributes" . ,xim:ATTRIBUTE-VALUE-TYPE:xim-nested-list)
    ("statusAttributes" . ,xim:ATTRIBUTE-VALUE-TYPE:xim-nested-list)
    ("fontSet" . ,xim:ATTRIBUTE-VALUE-TYPE:x-font-set)
    ("area" . ,xim:ATTRIBUTE-VALUE-TYPE:x-rectangle)
    ("areaNeeded" . ,xim:ATTRIBUTE-VALUE-TYPE:x-rectangle)
    ("colorMap" . ,xim:ATTRIBUTE-VALUE-TYPE:long-data)
    ("stdColorMap" . ,xim:ATTRIBUTE-VALUE-TYPE:long-data)
    ("foreground" . ,xim:ATTRIBUTE-VALUE-TYPE:long-data)
    ("background" . ,xim:ATTRIBUTE-VALUE-TYPE:long-data)
    ("backgroundPixmap" . ,xim:ATTRIBUTE-VALUE-TYPE:long-data)
    ("spotLocation" . ,xim:ATTRIBUTE-VALUE-TYPE:x-point)
    ("lineSpace" . ,xim:ATTRIBUTE-VALUE-TYPE:long-data)
    ("cursor" . ,xim:ATTRIBUTE-VALUE-TYPE:long-data)
    ("separatorofNestedList" . ,xim:ATTRIBUTE-VALUE-TYPE:separator-of-nestedlist))
  "IC attributes clients may set, as (NAME . TYPE); the id is the position.")

(defun ewm-xim--ic-attrs ()
  "IC attributes clients may set."
  (cl-loop for (name . type) in ewm-xim--ic-attr-table
           for id from 0
           collect (make-instance 'xim:XICATTR
                                  :id id
                                  :type type
                                  :length (length name)
                                  :attribute name)))

(defclass ewm-xim--styles (xim:XIMStyles) ()
  :documentation "XIMStyles with its count of styles right.")

(cl-defmethod xcb:marshal ((obj ewm-xim--styles))
  "Marshal OBJ, counting styles where XELB counts their bytes.
libX11 checks the count against the value's length and rejects it."
  (let ((data (cl-call-next-method obj)))
    (vconcat (funcall (if xim:lsb #'xcb:-pack-u2-lsb #'xcb:-pack-u2)
                      (length (slot-value obj 'styles)))
             (substring data 2))))

(defun ewm-xim--attributes ()
  "The one attribute value the server reports: root-window style only."
  (list (make-instance 'xim:XIMATTRIBUTE
                       :id 0
                       :length nil
                       :value (make-instance
                               'ewm-xim--styles
                               :number nil
                               :styles (list (logior xlib:XIMPreeditNothing
                                                     xlib:XIMStatusNothing))))))

(defun ewm-xim--ic-values (ids)
  "Values of the IC attributes IDS that the server keeps: the input
style and the events to filter.  Others are left out."
  (let ((pack (if xim:lsb #'xcb:-pack-u4-lsb #'xcb:-pack-u4)))
    (cl-loop for id in ids
             for name = (car (nth id ewm-xim--ic-attr-table))
             for value = (pcase name
                           ((pred (equal xlib:XNInputStyle))
                            (logior xlib:XIMPreeditNothing xlib:XIMStatusNothing))
                           ("filterEvents"
                            (logior xcb:EventMask:KeyPress xcb:EventMask:KeyRelease)))
             when value
             collect (make-instance 'xim:XICATTRIBUTE
                                    :id id
                                    :length 4
                                    :value (funcall pack value)))))

(defun ewm-xim--next-id (id)
  "The id after ID, in 1..#xffff."
  (if (< id #xffff) (1+ id) 1))

;;; Connection establishment

(defun ewm-xim--accept (client-xwin)
  "Open a server window for the client asking from CLIENT-XWIN."
  (let ((server-xwin (xcb:generate-id ewm-xim--conn)))
    (puthash server-xwin
             (ewm-xim--client-create :server-xwin server-xwin
                                     :client-xwin client-xwin
                                     :lsb xcb:lsb)
             ewm-xim--clients)
    ;; Learn when the client goes away without a word.
    (xcb:+request ewm-xim--conn
        (make-instance 'xcb:ChangeWindowAttributes
                       :window client-xwin
                       :value-mask xcb:CW:EventMask
                       :event-mask xcb:EventMask:StructureNotify))
    (xcb:+request ewm-xim--conn
        (make-instance 'xcb:CreateWindow
                       :depth 0
                       :wid server-xwin
                       :parent ewm-xim--root
                       :x 0 :y 0 :width 1 :height 1
                       :border-width 0
                       :class xcb:WindowClass:InputOutput
                       :visual 0
                       :value-mask xcb:CW:OverrideRedirect
                       :override-redirect 1))
    ;; Transport version 0.0: client messages, and properties beyond 20 bytes.
    (xcb:+request ewm-xim--conn
        (make-instance 'xcb:SendEvent
                       :propagate 0
                       :destination client-xwin
                       :event-mask xcb:EventMask:NoEvent
                       :event (xcb:marshal
                                  (make-instance
                                   'xcb:ClientMessage
                                   :format 32
                                   :window client-xwin
                                   :type (ewm-xim--atom '_XIM_XCONNECT)
                                   :data (make-instance 'xcb:ClientMessageData
                                                        :data32 (list server-xwin 0 0 0 0)))
                                  ewm-xim--conn)))
    (xcb:flush ewm-xim--conn)))

(defun ewm-xim--drop (client)
  "Forget CLIENT and its input contexts, and close its server window."
  (remhash (ewm-xim--client-server-xwin client) ewm-xim--clients)
  (let (gone)
    (maphash (lambda (id ic) (when (eq (ewm-xim--ic-client ic) client) (push id gone)))
             ewm-xim--ics)
    (dolist (id gone) (ewm-xim--forget-ic id)))
  (when (and ewm-xim--conn (slot-value ewm-xim--conn 'connected))
    (xcb:+request ewm-xim--conn
        (make-instance 'xcb:DestroyWindow
                       :window (ewm-xim--client-server-xwin client)))
    (xcb:flush ewm-xim--conn)))

(defun ewm-xim--forget-ic (ic-id)
  "Forget input context IC-ID."
  (when-let* ((ic (gethash ic-id ewm-xim--ics)))
    (remhash ic-id ewm-xim--ics)
    (let (gone)
      (maphash (lambda (surface other) (when (eq other ic) (push surface gone)))
               ewm-xim--surface-ics)
      (dolist (surface gone) (remhash surface ewm-xim--surface-ics)))))

(defun ewm-xim--on-ClientMessage (data _synthetic)
  "Handle ClientMessage DATA: a new client, or a request from one."
  (let ((evt (make-instance 'xcb:ClientMessage)))
    (xcb:unmarshal evt data)
    (with-slots (format window type (msg data)) evt
      (cond
       ((and (= type (ewm-xim--atom '_XIM_XCONNECT)) (= window ewm-xim--event-xwin))
        (ewm-xim--accept (car (slot-value msg 'data32))))
       ((and (= type (ewm-xim--atom '_XIM_PROTOCOL)) (gethash window ewm-xim--clients))
        (let ((client (gethash window ewm-xim--clients)))
          (if (= format 8)
              (ewm-xim--on-request (vconcat (slot-value msg 'data8)) client)
            (let* ((data32 (slot-value msg 'data32))
                   (reply (xcb:+request-unchecked+reply ewm-xim--conn
                              (make-instance 'xcb:GetProperty
                                             :delete 1
                                             :window window
                                             :property (nth 1 data32)
                                             :type xcb:GetPropertyType:Any
                                             :long-offset 0
                                             :long-length (nth 0 data32))))
                   (value (and reply (slot-value reply 'value))))
              (when (> (length value) 0)
                (ewm-xim--on-request (vconcat value) client))))))))))

(defun ewm-xim--on-DestroyNotify (data synthetic)
  "Drop the client whose window DestroyNotify DATA reports gone."
  (unless synthetic
    (let ((evt (make-instance 'xcb:DestroyNotify))
          gone)
      (xcb:unmarshal evt data)
      (maphash (lambda (_ client)
                 (when (= (ewm-xim--client-client-xwin client) (slot-value evt 'window))
                   (push client gone)))
               ewm-xim--clients)
      (mapc #'ewm-xim--drop gone))))

;;; Requests

(defmacro ewm-xim--parse (class data)
  "Unmarshal DATA as an instance of CLASS."
  `(let ((req (make-instance ,class)))
     (xcb:unmarshal req ,data)
     req))

(defun ewm-xim--on-request (data client)
  "Handle XIM request DATA from CLIENT and send the replies."
  (let ((opcode (aref data 0))
        (xim:lsb (ewm-xim--client-lsb client))
        replies)
    (cond
     ((= opcode xim:opcode:connect)
      ;; The client's byte order holds for the rest of the conversation.
      (setq xim:lsb (= (aref data 4) xim:connect-byte-order:lsb-first))
      (setf (ewm-xim--client-lsb client) xim:lsb)
      (let ((req (ewm-xim--parse 'xim:connect data)))
        (push (if (and (= (slot-value req 'major-version) 1)
                       (= (slot-value req 'minor-version) 0)
                       ;; No authentication.
                       (= (slot-value req 'number) 0))
                  (make-instance 'xim:connect-reply)
                (ewm-xim--error))
              replies)))
     ((memq opcode (list xim:opcode:auth-required xim:opcode:auth-reply
                         xim:opcode:auth-next xim:opcode:auth-ng))
      (push (ewm-xim--error) replies))
     ((= opcode xim:opcode:disconnect)
      (ewm-xim--send (make-instance 'xim:disconnect-reply) client)
      (ewm-xim--drop client))
     ((= opcode xim:opcode:open)
      (setq ewm-xim--im-id (ewm-xim--next-id ewm-xim--im-id))
      (setq replies
            (list (make-instance 'xim:set-event-mask
                                 :im-id ewm-xim--im-id
                                 :ic-id 0
                                 ;; Static event flow.
                                 :forward-event-mask xcb:EventMask:KeyPress
                                 ;; On-demand synchronous.
                                 :synchronous-event-mask xcb:EventMask:NoEvent)
                  (make-instance 'xim:open-reply
                                 :im-id ewm-xim--im-id
                                 :im-attrs-length nil
                                 :im-attrs (ewm-xim--im-attrs)
                                 :ic-attrs-length nil
                                 :ic-attrs (ewm-xim--ic-attrs)))))
     ((= opcode xim:opcode:close)
      (push (make-instance 'xim:close-reply
                           :im-id (slot-value (ewm-xim--parse 'xim:close data) 'im-id))
            replies))
     ((= opcode xim:opcode:trigger-notify)
      ;; Static event flow only.
      (push (ewm-xim--error) replies))
     ((= opcode xim:opcode:encoding-negotiation)
      (let* ((req (ewm-xim--parse 'xim:encoding-negotiation data))
             (index (cl-position "COMPOUND_TEXT"
                                 (mapcar (lambda (i) (slot-value i 'name))
                                         (slot-value req 'names))
                                 :test #'equal)))
        (push (make-instance 'xim:encoding-negotiation-reply
                             :im-id (slot-value req 'im-id)
                             :category xim:encoding-negotiation-reply-category:name
                             ;; -1 is the portable character encoding.
                             :index (or index -1))
              replies)))
     ((= opcode xim:opcode:query-extension)
      (push (make-instance 'xim:query-extension-reply
                           :im-id (slot-value (ewm-xim--parse 'xim:query-extension data)
                                              'im-id)
                           :length 0
                           :extensions nil)
            replies))
     ((= opcode xim:opcode:set-im-values)
      (push (make-instance 'xim:set-im-values-reply
                           :im-id (slot-value (ewm-xim--parse 'xim:set-im-values data)
                                              'im-id))
            replies))
     ((= opcode xim:opcode:get-im-values)
      (let ((req (ewm-xim--parse 'xim:get-im-values data)))
        (push (if (cl-notevery #'zerop (slot-value req 'im-attributes-id))
                  (ewm-xim--error (slot-value req 'im-id))
                (make-instance 'xim:get-im-values-reply
                               :im-id (slot-value req 'im-id)
                               :length nil
                               :im-attributes (ewm-xim--attributes)))
              replies)))
     ((= opcode xim:opcode:create-ic)
      (let ((req (ewm-xim--parse 'xim:create-ic data)))
        ;; The IC attributes need no keeping for the root-window style.
        (setq ewm-xim--ic-id (ewm-xim--next-id ewm-xim--ic-id))
        (puthash ewm-xim--ic-id
                 (ewm-xim--ic-create :client client
                                     :im-id (slot-value req 'im-id)
                                     :ic-id ewm-xim--ic-id)
                 ewm-xim--ics)
        (push (make-instance 'xim:create-ic-reply
                             :im-id (slot-value req 'im-id)
                             :ic-id ewm-xim--ic-id)
              replies)))
     ((= opcode xim:opcode:destroy-ic)
      (let ((req (ewm-xim--parse 'xim:destroy-ic data)))
        (ewm-xim--forget-ic (slot-value req 'ic-id))
        (push (make-instance 'xim:destroy-ic-reply
                             :im-id (slot-value req 'im-id)
                             :ic-id (slot-value req 'ic-id))
              replies)))
     ((= opcode xim:opcode:set-ic-values)
      (let ((req (ewm-xim--parse 'xim:set-ic-values data)))
        (push (make-instance 'xim:set-ic-values-reply
                             :im-id (slot-value req 'im-id)
                             :ic-id (slot-value req 'ic-id))
              replies)))
     ((= opcode xim:opcode:get-ic-values)
      (let ((req (ewm-xim--parse 'xim:get-ic-values data)))
        (push (make-instance 'xim:get-ic-values-reply
                             :im-id (slot-value req 'im-id)
                             :ic-id (slot-value req 'ic-id)
                             :length nil
                             :ic-attributes (ewm-xim--ic-values
                                             (slot-value req 'ic-attributes-id)))
              replies)))
     ((= opcode xim:opcode:set-ic-focus)
      ;; Keys name their IC, and the focused surface names the buffer.
      nil)
     ((= opcode xim:opcode:unset-ic-focus)
      (ewm-xim--on-unfocus
       (slot-value (ewm-xim--parse 'xim:unset-ic-focus data) 'ic-id)))
     ((= opcode xim:opcode:forward-event)
      (ewm-xim--on-forward-event (ewm-xim--parse 'xim:forward-event data) client))
     ((= opcode xim:opcode:sync)
      (let ((req (ewm-xim--parse 'xim:sync data)))
        (push (make-instance 'xim:sync-reply
                             :im-id (slot-value req 'im-id)
                             :ic-id (slot-value req 'ic-id))
              replies)))
     ((memq opcode (list xim:opcode:sync-reply xim:opcode:error)))
     ((= opcode xim:opcode:reset-ic)
      (let ((req (ewm-xim--parse 'xim:reset-ic data)))
        (push (make-instance 'xim:reset-ic-reply
                             :im-id (slot-value req 'im-id)
                             :ic-id (slot-value req 'ic-id)
                             :length 0
                             :string "")
              replies)))
     (t
      ;; Preedit and string conversion replies included: none was asked for.
      (push (ewm-xim--error) replies)))
    (dolist (reply (nreverse replies))
      (ewm-xim--send reply client))
    (when (and ewm-xim--conn (slot-value ewm-xim--conn 'connected))
      (xcb:flush ewm-xim--conn))))

;;; Keys

(defconst ewm-xim--modifiers
  '((ctrl . 4) (alt . 8) (shift . 1) (logo . 64))
  "Compositor key flags and the X modifier masks they stand for.")

(defun ewm-xim--compositor-event (detail state surface-id key)
  "The compositor key event for keycode DETAIL in modifier STATE.
It is aimed at SURFACE-ID and carries KEY, the `ewm-xim--key' to answer."
  (pcase-let* ((`(,keysym . ,_) (xcb:keysyms:keycode->keysym ewm-xim--conn
                                                             detail state))
               (base (and (/= keysym 0)
                          (xcb:keysyms:keysym->event ewm-xim--conn keysym))))
    `((surface_id . ,surface-id)
      (keycode . ,detail)
      (keysym . ,keysym)
      ,@(and (characterp base) (>= base ?\s) (/= base 127)
             `((utf8 . ,(string base))))
      ,@(cl-loop for (flag . mask) in ewm-xim--modifiers
                 unless (zerop (logand state mask)) collect (cons flag t))
      (xim . ,key))))

(defun ewm-xim--composes-p (buffer)
  "Non-nil when surface BUFFER has an input method or a composer."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (or current-input-method
             (run-hook-with-args-until-success
              'ewm-text-input-surface-composer-functions)))))

(defun ewm-xim--on-forward-event (req client)
  "Take the key press REQ that CLIENT forwarded."
  (with-slots (im-id ic-id flag serial-number event) req
    (unless (zerop (logand flag xim:forward-event-flag:synchronous))
      ;; Answered at once: what Emacs makes of it follows later.
      (ewm-xim--send (make-instance 'xim:sync-reply :im-id im-id :ic-id ic-id)
                     client))
    (let* ((ic (or (gethash ic-id ewm-xim--ics)
                   (puthash ic-id (ewm-xim--ic-create :client client
                                                      :im-id im-id :ic-id ic-id)
                            ewm-xim--ics)))
           (key (ewm-xim--key-create :ic ic :serial serial-number :event event))
           (press (make-instance 'xcb:KeyPress))
           (surface-id (ewm-get-focused-id))
           (buffer (ewm--surface-buffer surface-id)))
      (let ((xcb:lsb (ewm-xim--client-lsb client)))
        (xcb:unmarshal press (vconcat event)))
      (if (not (ewm-xim--composes-p buffer))
          (ewm-xim--hand-back key)
        (puthash surface-id ic ewm-xim--surface-ics)
        (ewm--handle-key (ewm-xim--compositor-event (slot-value press 'detail)
                                             (slot-value press 'state)
                                             surface-id key))))))

(defun ewm-xim--on-unfocus (ic-id)
  "Drop the unconfirmed text of the field IC-ID names: it lost focus.
Not while the input method reads for it, as when DDSKK's registration
minibuffer took the focus."
  (when-let* ((ic (gethash ic-id ewm-xim--ics))
              (surface-id (cl-loop for id being the hash-keys of ewm-xim--surface-ics
                                   using (hash-values i)
                                   when (eq i ic) return id))
              ((not (eql ewm-text-input--composing surface-id))))
    (ewm-xim--show-preedit "")
    (run-hooks 'ewm-text-input-deactivate-hook)))

(defun ewm-xim--live-p (ic)
  "Non-nil when IC's client is still connected."
  (and ewm-xim--conn
       (eq (gethash (ewm-xim--ic-ic-id ic) ewm-xim--ics) ic)
       (gethash (ewm-xim--client-server-xwin (ewm-xim--ic-client ic))
                ewm-xim--clients)))

(defun ewm-xim--hand-back (key)
  "Type KEY into its client as the key it was."
  (let ((ic (ewm-xim--key-ic key)))
    (when (ewm-xim--live-p ic)
      (let* ((client (ewm-xim--ic-client ic))
             (xim:lsb (ewm-xim--client-lsb client)))
        (ewm-xim--send (make-instance 'xim:forward-event
                                      :im-id (ewm-xim--ic-im-id ic)
                                      :ic-id (ewm-xim--ic-ic-id ic)
                                      :flag 0
                                      :serial-number (ewm-xim--key-serial key)
                                      :event (ewm-xim--key-event key))
                       client)
        (xcb:flush ewm-xim--conn)))))

(defun ewm-xim--commit (ic text)
  "Commit TEXT to the client of IC."
  (when (ewm-xim--live-p ic)
    (let* ((client (ewm-xim--ic-client ic))
           (xim:lsb (ewm-xim--client-lsb client))
           ;; Also right for the portable character encoding.
           (string (encode-coding-string text 'compound-text-with-extensions)))
      (ewm-xim--send (make-instance 'xim:commit-x-lookup-chars
                                    :im-id (ewm-xim--ic-im-id ic)
                                    :ic-id (ewm-xim--ic-ic-id ic)
                                    :flag xim:commit-flag:x-lookup-chars
                                    :length (length string)
                                    :string string)
                     client)
      (xcb:flush ewm-xim--conn))))

(defun ewm-xim--show-preedit (text)
  "Show TEXT, the preedit, in the echo area: the client has no place for it."
  (unless (equal text ewm-xim--preedit)
    (setq ewm-xim--preedit text)
    (let ((message-log-max nil))
      (if (string-empty-p text) (message nil) (message "%s" text)))))

(defun ewm-xim--deliver (op arg surface-id)
  "Send OP with ARG over XIM when it belongs to an XIM client.
For `ewm-text-input-client-functions'."
  (pcase op
    ('forward
     (when-let* ((key (alist-get 'xim arg)))
       (ewm-xim--hand-back key)
       t))
    ((or 'commit 'preedit)
     (when-let* ((ic (gethash surface-id ewm-xim--surface-ics)))
       (if (not (ewm-xim--live-p ic))
           (progn (remhash surface-id ewm-xim--surface-ics) nil)
         (if (eq op 'commit)
             (progn (ewm-xim--show-preedit "") (ewm-xim--commit ic arg))
           (ewm-xim--show-preedit arg))
         t)))))

;;; Lifecycle

(defun ewm-xim--display ()
  "The Xwayland display to serve, or nil."
  (let ((display (getenv "DISPLAY")))
    (and display (not (string-empty-p display)) display)))

(defun ewm-xim--register ()
  "Take the server selection and list the server in XIM_SERVERS."
  (let ((server (ewm-xim--atom 'server)))
    (xcb:+request ewm-xim--conn
        (make-instance 'xcb:CreateWindow
                       :depth 0
                       :wid ewm-xim--event-xwin
                       :parent ewm-xim--root
                       :x 0 :y 0 :width 1 :height 1
                       :border-width 0
                       :class xcb:WindowClass:InputOutput
                       :visual 0
                       :value-mask xcb:CW:OverrideRedirect
                       :override-redirect 1))
    (xcb:+request ewm-xim--conn
        (make-instance 'xcb:SetSelectionOwner
                       :owner ewm-xim--event-xwin
                       :selection server
                       :time xcb:Time:CurrentTime))
    ;; First, and only once: a server that went away may have left it.
    (ewm-xim--set-servers (cons server (delete server (ewm-xim--servers))))
    (xcb:flush ewm-xim--conn)))

(defun ewm-xim--connect (display)
  "Connect to X DISPLAY and serve XIM there."
  (let* ((xcb:connection-timeout (max xcb:connection-timeout 10))
         (conn (xcb:connect display)))
    (set-process-query-on-exit-flag (slot-value conn 'process) nil)
    (add-function :after (process-sentinel (slot-value conn 'process))
                  #'ewm-xim--sentinel)
    (setq ewm-xim--conn conn
          ewm-xim--connected-at (float-time)
          ewm-xim--root (slot-value (car (slot-value (xcb:get-setup conn) 'roots))
                                    'root)
          ewm-xim--event-xwin (xcb:generate-id conn)
          ewm-xim--atoms
          (cons (cons 'server (ewm-xim--intern
                               conn (concat "@server=" ewm-xim-server-name)))
                (mapcar (lambda (name)
                          (cons name (ewm-xim--intern conn (symbol-name name))))
                        ewm-xim--atom-names)))
    (xcb:keysyms:init conn)
    (xcb:+event conn 'xcb:SelectionRequest #'ewm-xim--on-SelectionRequest)
    (xcb:+event conn 'xcb:ClientMessage #'ewm-xim--on-ClientMessage)
    (xcb:+event conn 'xcb:DestroyNotify #'ewm-xim--on-DestroyNotify)
    (ewm-xim--register)))

(defun ewm-xim--forget ()
  "Drop the state of the current connection."
  (setq ewm-xim--conn nil
        ewm-xim--root nil
        ewm-xim--event-xwin nil
        ewm-xim--atoms nil
        ewm-xim--connected-at nil
        ewm-xim--properties (make-vector (length ewm-xim--properties) nil)
        ewm-xim--property-index 0)
  ;; The clients went with the display.
  (clrhash ewm-xim--clients)
  (clrhash ewm-xim--ics)
  (clrhash ewm-xim--surface-ics))

(defun ewm-xim--start ()
  "Serve XIM on the Xwayland display unless already serving."
  (ewm-xim--cancel-reconnect)
  (unless (and ewm-xim--conn (slot-value ewm-xim--conn 'connected))
    (ewm-xim--forget)
    (if-let* ((display (ewm-xim--display)))
        (condition-case err
            (ewm-xim--connect display)
          (error
           (message "ewm-xim: cannot serve %s: %s" display
                    (error-message-string err))
           (when ewm-xim--conn
             (ignore-errors (xcb:disconnect ewm-xim--conn)))
           (ewm-xim--forget)
           (ewm-xim--schedule-reconnect)))
      (message "ewm-xim: no X display to serve"))))

(defun ewm-xim--stop ()
  "Stop serving XIM: leave XIM_SERVERS and close the connection."
  (ewm-xim--cancel-reconnect)
  (when-let* ((conn ewm-xim--conn))
    ;; Forget first, so the sentinel sees a closing it asked for.
    (let ((atoms ewm-xim--atoms)
          (root ewm-xim--root))
      (ewm-xim--forget)
      (when (slot-value conn 'connected)
        (let ((ewm-xim--conn conn)
              (ewm-xim--atoms atoms)
              (ewm-xim--root root))
          (ignore-errors
            (ewm-xim--set-servers (delete (ewm-xim--atom 'server)
                                          (ewm-xim--servers)))
            (xcb:flush conn)))
        (xcb:disconnect conn))))
  (setq ewm-xim--failures 0))

(defun ewm-xim--sentinel (process _event)
  "Reconnect when PROCESS, the server's connection, closed under it."
  ;; XELB's own sentinel has already reset the connection's slots.
  (when (and (not (process-live-p process))
             ewm-xim--conn
             (eq ewm-xim--conn (process-get process 'connection)))
    (message "ewm-xim: lost the X display")
    (ewm-xim--forget)
    (ewm-xim--schedule-reconnect)))

(defun ewm-xim--schedule-reconnect ()
  "Try the display again later, unless it keeps failing."
  (when ewm-xim-mode
    (if (and ewm-xim--connected-at
             (> (- (float-time) ewm-xim--connected-at) ewm-xim--stable-time))
        (setq ewm-xim--failures 0)
      (cl-incf ewm-xim--failures))
    (ewm-xim--cancel-reconnect)
    (if (> ewm-xim--failures ewm-xim--max-failures)
        (message "ewm-xim: giving up; M-x ewm-xim-mode to retry")
      (setq ewm-xim--reconnect-timer
            (run-with-timer ewm-xim-reconnect-delay nil #'ewm-xim--start)))))

(defun ewm-xim--cancel-reconnect ()
  "Cancel a pending reconnection."
  (when ewm-xim--reconnect-timer
    (cancel-timer ewm-xim--reconnect-timer)
    (setq ewm-xim--reconnect-timer nil)))

(defun ewm-xim--start-when-ready ()
  "Start serving once Emacs is idle, so the session comes up first."
  (when ewm-xim-mode
    (run-with-idle-timer 0 nil (lambda () (when ewm-xim-mode (ewm-xim--start))))))

;;;###autoload
(define-minor-mode ewm-xim-mode
  "Serve Emacs input methods to Xwayland clients over XIM.
The server starts once the EWM session is ready, which starts Xwayland."
  :global t
  :group 'ewm-input-methods
  (if ewm-xim-mode
      (progn
        (setq ewm-xim--failures 0)
        (add-hook 'ewm-text-input-client-functions #'ewm-xim--deliver)
        (add-hook 'ewm-mode-hook #'ewm-xim--start-when-ready)
        (add-hook 'kill-emacs-hook #'ewm-xim--stop -50)
        (when (bound-and-true-p ewm-mode) (ewm-xim--start-when-ready)))
    (remove-hook 'ewm-text-input-client-functions #'ewm-xim--deliver)
    (remove-hook 'ewm-mode-hook #'ewm-xim--start-when-ready)
    (remove-hook 'kill-emacs-hook #'ewm-xim--stop)
    (ewm-xim--stop)))

(provide 'ewm-xim)
;;; ewm-xim.el ends here
