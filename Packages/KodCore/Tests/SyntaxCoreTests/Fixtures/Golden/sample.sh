#!/bin/sh

greet() {
  local name="${1:-world}"
  printf 'Hello, %s\n' "$name"
}

if [ -n "$USER" ]; then
  greet "$USER"
fi
