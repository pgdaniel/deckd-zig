#!/bin/sh
# Flattens gtk/gtk.h (and everything it pulls in) into one fully
# preprocessed header that zig's translate-c (aro) can actually parse.
# Run at build time by build.zig — regenerated fresh each build so it
# always matches whatever GTK is actually installed, rather than being a
# vendored snapshot that could drift from the system.
#
# Plain `@cInclude("gtk/gtk.h")` doesn't work with zig 0.16's C frontend
# against a real desktop's GTK4 install; three independent things need
# working around, all confirmed against this system's gtk4 4.22:
#
#  1. GLib's G_DECLARE_FINAL_TYPE and friends expand to a bare _Pragma(...)
#     operator between declarations (e.g. G_GNUC_BEGIN_IGNORE_DEPRECATIONS).
#     aro chokes on that. A real preprocessing pass turns _Pragma(...) into
#     actual #pragma directives, which parse fine.
#  2. graphene's SIMD headers use GCC vector-extension builtins
#     (__builtin_shuffle, __builtin_ia32_*) aro doesn't implement. graphene
#     already ships a portable scalar fallback for exactly this situation —
#     it's what the gobject-introspection scanner uses — gated behind
#     __GI_SCANNER__, so we just claim to be that.
#  3. Recent glibc (sys/cdefs.h, __GNUC_PREREQ(11,0)) uses a two-argument
#     form of __attribute__((__malloc__(deallocator, argno))) that aro
#     doesn't support. Reporting an older __GNUC__ makes glibc fall back to
#     the plain no-argument form, which aro handles fine — this only
#     affects that one attribute, not any real codegen (we never compile
#     this flattened text with GCC, only feed its declarations to aro).
#
# On top of that, glib's g_set_object() (gobject/gobject.h) is a `static
# inline` function whose body translate-c turns into Zig that fails to
# type-check (an un-annotated @ptrCast). We never call it, so it's
# rewritten to a bare `extern` prototype instead of a body. If future GTK
# usage hits more functions like this, add them here the same way.
#
# usage: gen_gtk_header.sh <output-file>
set -eu

out="$1"
mkdir -p "$(dirname "$out")"

cflags=$(pkg-config --cflags-only-I gtk4)

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# shellcheck disable=SC2086
cc -E -std=gnu11 \
  -D__GI_SCANNER__=1 \
  -U__GNUC__ -D__GNUC__=10 -U__GNUC_MINOR__ -D__GNUC_MINOR__=0 \
  $cflags \
  -x c - <<'EOF' > "$tmp"
#include <gtk/gtk.h>
EOF

# g_set_object: static inline whose body doesn't translate cleanly (see
# above) — replace with a plain prototype. It's a real exported symbol in
# libgobject, so this stays linkable if anything ever does call it.
awk '
  /^static inline gboolean$/ { pending = 1; next }
  pending && /^\(g_set_object\) \(GObject \*\*object_ptr,$/ {
    print "extern gboolean g_set_object(GObject **object_ptr, GObject *new_object);"
    pending = 0
    skipping = 1
    depth = 0
    started = 0
    next
  }
  pending { print "static inline gboolean"; pending = 0 }
  skipping {
    n = gsub(/\{/, "{"); depth += n
    n = gsub(/\}/, "}"); depth -= n
    if (index($0, "{") > 0) started = 1
    if (started && depth <= 0) skipping = 0
    next
  }
  { print }
' "$tmp" > "$out"
