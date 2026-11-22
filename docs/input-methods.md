# EWM Input Methods

## Feature Status

| Feature | Protocol | Status | Notes |
|---------|----------|--------|-------|
| Commit string | `text_input_v3` / `input_method_v2` | Done | Direct on compositor thread, queued during gaps |
| Key interception | `text_input_v3` | Done | Printable keys routed to Emacs for IM translation |
| Activate/deactivate | `input_method_v2` | Done | Relay thread forwards events to Emacs |
| XKB layout switching | core Wayland | Done | Multi-layout with temporary reset for intercepts |
| Preedit (composing text) | `text_input_v3` | Done | The input method's buffer text, mirrored while it composes |
| Content type hints | `text_input_v3` | TODO | Auto-disable intercept for password fields |
| Surrounding text | `text_input_v3` | TODO | Selection access for cut/copy in surface buffers |
| Delete surrounding text | `input_method_v2` | TODO | Cut in surface buffers, backspace during composition |
| Input popup surface | `input_method_v2` | Done | Candidate window below the client cursor |
| External input methods | `input_method_v2` | Done | `ewm-text-input-provider` hands the seat to fcitx5 or ibus |
| DDSKK | `text_input_v3` | Done | `ewm-skk-mode` (`lisp/ewm-skk.el`) |
| Xwayland clients | XIM | Done | `ewm-xim-mode` (`lisp/ewm-xim.el`), needs XELB; on-the-spot and root-window styles |

### Priority

**Surrounding text + delete** together enable clipboard operations (cut/copy)
in surface buffers via the protocol rather than synthetic keypresses:

1. Client sends `set_surrounding_text(text, cursor, anchor)`. When
   `cursor != anchor`, the text between them is the selection.
2. Emacs extracts the selected portion and puts it on the clipboard.
3. For cut, compositor sends `delete_surrounding_text` via `input_method_v2`
   to remove the selection in the client.

This would let `s-x` (cut) and `s-c` (copy) work in surface buffers the
same way they work in Emacs buffers, using the Wayland protocol instead of
injecting synthetic Ctrl+X/C keypresses.

## Overview

EWM provides:
- **XKB Layout Switching**: Multiple keyboard layouts with hardware/software switching
- **Text Input Protocol**: Emacs input methods work in external Wayland apps (Firefox, terminals)
- **External input methods**: fcitx5 or ibus can take the seat instead of Emacs

## Provider

The seat has one `input_method_v2` slot. `ewm-text-input-provider` says who
holds it:

- `emacs` (default): the relay below holds the slot and Emacs input methods
  serve client text fields. Emacs frames stay out of text-input focus so
  Emacs's own GTK input context never reaches the relay.
- `external`: the relay is disconnected (or never connected) and an input
  method such as fcitx5 binds the slot. Emacs frames get text-input focus
  like any client, so the same input method serves Emacs through GTK's
  Wayland input context.

The Emacs-side text input relay (activation events, `ewm-edit`, intercept)
only works with the `emacs` provider.

## XKB Keyboard Layouts

### Configuration

```elisp
(setopt ewm-input-config
        '((keyboard :xkb-layouts "us,ru,no"
                    :xkb-options "grp:caps_toggle")))
```

On startup, Emacs configures XKB through the input-device configuration sent
to the dynamic module.

### Module Interface

**Emacs -> Compositor (module functions):**

```elisp
(ewm-configure-module config)      ; Every option, keyboard layouts among them
(ewm-switch-layout-module layout)    ; Switch to layout by name
(ewm-get-layouts-module)             ; Query current layouts
```

**Compositor -> Emacs (events via pipe fd):**

| Event | Fields | Purpose |
|-------|--------|---------|
| `layouts` | `layouts`, `current` | Report configured layouts |
| `layout-switched` | `layout`, `index` | Layout changed |

### Implementation

XKB supports multiple layouts via "groups" (indexed 0, 1, 2...). Switching
between groups is fast (no keymap recompilation). XKB options like
`grp:caps_toggle` work natively.

#### Layout and the prefix key

The key that starts a redirected sequence (`C-x`, `M-x`) is forwarded under
the base layout (index 0), so Emacs finds the binding whatever layout is
active. The keys that follow arrive under the active layout.

Emacs requests keyboard capture through one tokened lease. Beginning capture
returns a token, and ending capture must present that same token, so a stale
end from an earlier input context cannot clear the capture a later one holds.
Keyboard-dispatch intercepts also open synchronous redirect capture in
the compositor so a prefix like `C-x` keeps the next key routed to Emacs even
if the physical prefix key is released before Lisp's post-command hook runs.
The next inactive command-loop sync clears that redirect capture.

Each binding reaches the compositor with one of three deliveries in its
`:dispatch` field. `command` is what `ewm-mode-map` commands use: the Wayland
keyboard stays with the client and the key goes to Lisp over the event pipe,
and bindings flagged `:repeat` with `ewm-key`, as the default navigation and
media keys are, repeat from the compositor timer. `keyboard` moves the Wayland
keyboard to Emacs for the key and whatever follows, for keys flagged
`:intercept`, such as `M-x` and `C-u`, and for a key that holds a keymap.
`(action ...)` carries the action of a command defined with
`ewm--define-action`, which the compositor runs itself.

The repeat configuration has one effective source: the `(keyboard
:repeat-rate ... :repeat-delay ...)` entry in `ewm-input-config`, falling back
to `25Hz` and `200ms`. The compositor applies that same `(rate, delay)` to
Wayland keyboard repeat and to intercepted command/text-input repeat.
Repeatable command-dispatch bindings use the compositor timer. Text-input
repeat still follows XKB repeatability so client text input behaves like
ordinary Wayland keyboard input.

Held-key ownership and timers live in `im::repeat`.

#### Intercepted key invariants

The intercept/capture hot path keeps these invariants:

1. Keyboard capture is a Wayland keyboard-focus overlay; it does not change
   the window focus the layout derives.
2. Command-dispatch intercepted keys are `ewm-mode-map` command bindings; they
   go through the event pipe and do not move keyboard focus to Emacs by
   themselves.
3. Once EWM consumes an intercepted physical press, backend repeat presses and
   the matching release are consumed by EWM too, never forwarded to the client
   surface.
4. A held command or media key stops repeating at its next tick once keyboard
   capture is active, so it cannot keep going behind a minibuffer, transient
   or `read-key` sequence.
5. Stale keyboard-capture token ends are ignored.
6. Repeat timers are valid only for the currently held intercepted key.

## Text Input (Emacs IM in External Apps)

Allows Emacs input methods to work in external Wayland surfaces, similar
to exwm-xim on X11.

### How It Works

```
Application                    Compositor                      Emacs
     |                              |                              |
     |--enable text_input---------->|                              |
     |                              |--text-input-activated------->|
     |                              |                              |
     |  [user types]                |                              |
     |                              |--key {keysym, utf8}--------->|
     |                              |                              |
     |                              |<--im-commit {text, id}-------|
     |<--commit_string (direct)-----|                              |
```

Commits are applied directly on the compositor thread via `TextInputHandle`,
avoiding cross-thread serial races. If the client is in a disable->enable gap
(e.g., after focus returned from the minibuffer), commits are queued and
drained on the next Activated event for the same surface.

Lisp runs the surface buffer's own input method in the command loop, so
buffer-local input methods cannot leak between surfaces and multi-key
sequences compose the way they do in Emacs. A text key queues an
`ewm-text-input-key` special event. Its handler calls `input-method-function`
in the surface buffer, where the method reads the keys the compositor keeps
intercepting from `unread-command-events` and shows its guidance in the echo
area. The text it composes in the buffer is mirrored to the client as preedit.
When it returns, the result is committed and the keys it handed back are typed
into the client (text through the method again, other keys replayed by keycode).
A field deactivating mid-composition aborts it.

### Module Interface

**Compositor -> Emacs (events via pipe fd):**

| Event | Fields | Purpose |
|-------|--------|---------|
| `text-input-activated` | - | Text field focused in client |
| `text-input-deactivated` | - | Text field unfocused |
| `key` | `keysym`, `utf8`, `keycode`, modifiers | Key press in text field |

**Emacs -> Compositor (module functions):**

```elisp
(ewm-im-commit-module text surface-id)           ; Insert text into focused field
(ewm-im-preedit-module text surface-id)          ; Show composing text, caret at its end
(ewm-text-input-intercept-module enable)         ; Enable/disable key interception
```

### Usage

1. Focus a text field in a Wayland app (Firefox, foot, etc.)
2. Activate an Emacs input method: `M-x set-input-method RET russian-computer`
3. Type - keys are intercepted, processed by Emacs, and committed to the app

No environment variables needed (unlike X11's `XMODIFIERS`).

### DDSKK

DDSKK is not a quail method: its `input-method-function` is `list` and the
conversion happens in `skk-j-mode-map` commands editing the buffer, so the
relay above would commit raw romaji. `lisp/ewm-skk.el` adapts it (opt-in):

```elisp
(require 'ewm-skk)
(ewm-skk-mode 1)
```

Then turn on `japanese-skk` (`C-\`) or `skk-mode` in the app's buffer.
DDSKK must already be installed and configured for Emacs itself: its
dictionaries, `skk-egg-like-newline` and the rest apply unchanged. With
`ewm-xim-mode` (below) the same works in Xwayland apps.

- A key for a surface whose buffer has `skk-mode` queues an `ewm-skk-key`
  special event. Its handler looks the key up in the surface buffer's keymaps
  and runs the command between `pre-command-hook` and `post-command-hook`, as
  the command loop would; keys DDSKK reads mid-command (the candidate list,
  dictionary registration) come from `unread-command-events` like quail's.
- After each key, text before the ▽/▼ mark (all text when not converting) is
  confirmed: it is committed and deleted. The rest, with the pending romaji
  prefix, is shown as preedit, so the buffer only holds unconfirmed text.
- With nothing unconfirmed, only text keys and `ewm-skk-keys` (`C-j`) go to
  DDSKK; Return, Backspace and shortcuts reach the client untouched. Mid
  conversion, DDSKK commands (and `ewm-skk-commands`) run; any other key
  confirms the conversion and then reaches the client.
- A newline produced by Return (DDSKK confirms and inserts one unless
  `skk-egg-like-newline`) is typed into the client as Return.
- A field deactivating drops the unconfirmed reading without learning it.
- The compositor applies `ewm-surface-emulate-keys` and `ewm-mode-map` keys
  before text input sees them, and a client handed C-m as Return keeps its
  preedit as text. While ▽/▼ is open, the focused surface's emulations and
  the `ewm-mode-map` keys bound to DDSKK commands are not intercepted
  (`ewm-intercept-keys-filter-functions`). A key then keeps its DDSKK meaning
  (C-m confirms, C-g cancels), takes the key it emulates when only that one
  means something to DDSKK (C-h as Backspace), or confirms and sends what it
  emulates.
- Before DDSKK's registration minibuffer takes the focus, the client's
  preedit is cleared, since a client losing focus may keep it as text.
  The reading itself survives the registration, and what it confirms is
  committed once the minibuffer exits.

Keys DDSKK commonly binds in Emacs keep working mid conversion even if
`ewm-mode-map` or `ewm-surface-emulate-keys` claims them, for example:

```elisp
(define-key ewm-mode-map (kbd "C-j") #'skk-kakutei)   ; still confirms
(customize-set-variable
 'ewm-surface-emulate-keys
 (append '(("C-m" . "<return>") ("C-h" . "<backspace>") ("C-g" . "<escape>"))
         ewm-surface-emulate-keys))
```

With nothing converting these keys behave as configured; while ▽/▼ is
open C-m confirms, C-h deletes in the reading and C-g cancels.

## Xwayland Clients (XIM)

X clients run through xwayland-satellite and never see `text_input_v3`, so
the relay above cannot reach them. `lisp/ewm-xim.el` makes Emacs an XIM
server on the Xwayland display instead, written with XELB and ported from
EXWM's `exwm-xim.el`. It is opt-in, and XELB is needed only when it is on:

```elisp
(require 'ewm-xim)
(ewm-xim-mode 1)
```

Start X clients with the server named in `XMODIFIERS`; GTK also needs its
XIM module:

```sh
XMODIFIERS=@im=ewm-xim xterm
XMODIFIERS=@im=ewm-xim GTK_IM_MODULE=xim GDK_BACKEND=x11 mousepad
```

Then turn on the input method in the app's surface buffer, as for a
Wayland app. `xprop -root XIM_SERVERS` lists `@server=ewm-xim` while the
server runs. A client started before the server does not use it; restart
the client.

### How It Works

```
X client            xwayland-satellite / Xwayland            Emacs (ewm-xim)
    |                              |                              |
    |  [user types]                |                              |
    |--XIM FORWARD_EVENT (KeyPress, over X ClientMessages)------->|
    |<--SYNC_REPLY (at once)--------------------------------------|
    |                              |      ewm--handle-key         |
    |                              |      (focused surface)       |
    |<--COMMIT (COMPOUND_TEXT) or FORWARD_EVENT (key unused)------|
```

- The server takes the `@server=ewm-xim` selection, lists it in the root
  window's `XIM_SERVERS` and answers the `LOCALES` and `TRANSPORT` queries.
  Like EXWM it offers transport 0.0 over the X connection and static
  event flow. It offers two input styles: on-the-spot
  (`XIMPreeditCallbacks | XIMStatusNothing`) and root-window
  (`XIMPreeditNothing | XIMStatusNothing`).
- Every key press the client forwards is answered with `SYNC_REPLY` at
  once, since Xlib blocks until it is. Emacs's answer follows later.
- The key becomes a compositor key event for the focused surface. If that
  surface's buffer has an input method, or a composer such as `ewm-skk`, it
  goes through `ewm--handle-key` like a text-input key, so quail methods and
  DDSKK serve X clients unchanged. Otherwise it is handed straight back.
- What the input method commits, shows as preedit or hands back returns
  over XIM through `ewm-text-input-client-functions` instead of text
  input. An on-the-spot client (GTK, Wine) is sent `PREEDIT_START`,
  `PREEDIT_DRAW` and `PREEDIT_DONE`, and draws the reading underlined in
  its field. A commit ends the preedit first. The root-window style
  (xterm) gives the client no place for preedit, so it shows in the echo
  area.
- A field losing focus (`UNSET_IC_FOCUS`) runs
  `ewm-text-input-deactivate-hook`, as a text-input field does, so the
  unconfirmed reading is dropped. Not while the input method itself reads,
  as when DDSKK's registration minibuffer takes the focus.
- xwayland-satellite starts on the first X connection, and the server's is
  one: it connects once EWM is ready (`ewm-mode-hook`), so Xwayland is up
  and the server registered before any client calls `XOpenIM`. If Xwayland
  goes away the server reconnects after `ewm-xim-reconnect-delay`, and
  gives up after repeated quick failures.
- XELB writes the count of `XIMStyles` as a byte count, which current
  libX11 rejects ("input method doesn't support any style"). The server
  marshals the styles with the count fixed.

### Limitations

- The caret is always at the end of the preedit, and the whole of it is
  underlined. No status callbacks: the input method's mode shows in the
  surface buffer's mode line.
- Keys are mapped to the focused surface, not to the X window that sent
  them; with one X client focused at a time they agree.

### Implementation Notes

The compositor implements both protocols:
- `zwp_text_input_v3` (client-side): Apps request text input
- `zwp_input_method_v2` (compositor-side): Manages input method state

Extension points other input code can use:
- `ewm-text-input-key-functions`: take a key before the input method sees it
- `ewm-text-input-surface-composer-functions`: say a surface buffer composes
- `ewm-text-input-deactivate-hook`: a client field lost focus
- `ewm-text-input-client-functions`: deliver commits, preedits and handed-back
  keys some other way than text input (XIM uses it)
- `ewm-intercept-keys-filter-functions`: keep keys from being intercepted

Key interception only occurs when:
1. Text input is active (app requested it)
2. An Emacs input method is enabled (or, with `ewm-skk-mode`, `skk-mode`)
3. The focused surface is not Emacs (Emacs handles its own input)
4. `ewm-text-input-provider` is `emacs`
