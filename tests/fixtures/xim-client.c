/* xim-client.c --- an Xlib XIM client for tests/ewm-xim-tests.el
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Opens the input method named by XMODIFIERS, creates an input context
 * with the style given as argv[1] ("callbacks" or "root") and reports on
 * stdout, one line each:
 *   window ID         once, the window to focus
 *   start             preedit started
 *   draw C F L TEXT   preedit draw: caret, change first, change length, text
 *   done              preedit done
 *   commit TEXT       text the input method committed
 *   key KEYSYM        a key the input method handed back
 */

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int preedit_start(XIC ic, XPointer data, XPointer call)
{
  (void)ic; (void)data; (void)call;
  printf("start\n");
  fflush(stdout);
  return -1;
}

static void preedit_draw(XIC ic, XPointer data, XIMPreeditDrawCallbackStruct *call)
{
  (void)ic; (void)data;
  const char *text = "";
  if (call->text && !call->text->encoding_is_wchar && call->text->string.multi_byte)
    text = call->text->string.multi_byte;
  printf("draw %d %d %d %s\n", call->caret, call->chg_first, call->chg_length, text);
  fflush(stdout);
}

static void preedit_done(XIC ic, XPointer data, XPointer call)
{
  (void)ic; (void)data; (void)call;
  printf("done\n");
  fflush(stdout);
}

int main(int argc, char **argv)
{
  int callbacks = argc > 1 && strcmp(argv[1], "callbacks") == 0;
  setlocale(LC_ALL, "");
  if (!XSupportsLocale()) return 1;
  XSetLocaleModifiers("");
  Display *dpy = XOpenDisplay(NULL);
  if (!dpy) return 1;
  XIM im = XOpenIM(dpy, NULL, NULL, NULL);
  if (!im) { fprintf(stderr, "no im\n"); return 1; }

  XIMStyle want = callbacks ? (XIMPreeditCallbacks | XIMStatusNothing)
                            : (XIMPreeditNothing | XIMStatusNothing);
  XIMStyles *styles = NULL;
  int found = 0;
  if (XGetIMValues(im, XNQueryInputStyle, &styles, NULL) || !styles) {
    fprintf(stderr, "no styles\n");
    return 1;
  }
  for (int i = 0; i < styles->count_styles; i++)
    if (styles->supported_styles[i] == want) found = 1;
  XFree(styles);
  if (!found) { fprintf(stderr, "style not offered\n"); return 1; }

  Window win = XCreateSimpleWindow(dpy, DefaultRootWindow(dpy), 0, 0, 100, 100, 0, 0, 0);
  XSelectInput(dpy, win, KeyPressMask | KeyReleaseMask | FocusChangeMask);
  XMapWindow(dpy, win);

  XIMCallback start = {NULL, (XIMProc)preedit_start};
  XIMCallback draw = {NULL, (XIMProc)preedit_draw};
  XIMCallback done = {NULL, (XIMProc)preedit_done};
  XVaNestedList preedit = XVaCreateNestedList(0,
                                              XNPreeditStartCallback, &start,
                                              XNPreeditDrawCallback, &draw,
                                              XNPreeditDoneCallback, &done,
                                              NULL);
  XIC ic = callbacks
    ? XCreateIC(im, XNInputStyle, want, XNClientWindow, win, XNFocusWindow, win,
                XNPreeditAttributes, preedit, NULL)
    : XCreateIC(im, XNInputStyle, want, XNClientWindow, win, XNFocusWindow, win, NULL);
  XFree(preedit);
  if (!ic) { fprintf(stderr, "no ic\n"); return 1; }
  XSetICFocus(ic);

  printf("window %lu\n", win);
  fflush(stdout);

  for (;;) {
    XEvent ev;
    XNextEvent(dpy, &ev);
    if (XFilterEvent(&ev, None)) continue;
    if (ev.type == FocusIn) XSetICFocus(ic);
    else if (ev.type == FocusOut) XUnsetICFocus(ic);
    else if (ev.type == KeyPress) {
      char buf[256];
      KeySym keysym = NoSymbol;
      Status status;
      int n = Xutf8LookupString(ic, &ev.xkey, buf, sizeof buf - 1, &keysym, &status);
      buf[n > 0 ? n : 0] = 0;
      if (status == XLookupChars)
        printf("commit %s\n", buf);
      else if (status == XLookupKeySym || status == XLookupBoth)
        printf("key %s\n", XKeysymToString(keysym));
      fflush(stdout);
    }
  }
}
