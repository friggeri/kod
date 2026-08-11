#!/usr/bin/env bash

greet() {
    local name=${1:-world}
    printf 'Hello, %s\n' "$name"
}

greet "Kod"
