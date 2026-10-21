#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
deps="$root/tests/.deps"
mkdir -p "$deps/parser"

install_parser() {
  language=$1
  revision=$2
  source="$deps/tree-sitter-$language"
  if [ ! -d "$source" ]; then
    git clone --depth 1 --branch "$revision" \
      "https://github.com/tree-sitter/tree-sitter-$language.git" "$source"
  fi
  "${CC:-cc}" -O2 -fPIC -shared -I"$source/src" \
    "$source/src/parser.c" "$source/src/scanner.c" -o "$deps/parser/$language.so"
}

install_parser python v0.23.6
install_parser julia v0.23.1
