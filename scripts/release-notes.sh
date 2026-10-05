#!/bin/zsh
# Prints the CHANGELOG section for <version> (without its heading).
awk -v v="$1" '$0 ~ "^## "v"( |$)" {f=1; next} /^## / && f {exit} f' "${0:A:h}/../CHANGELOG.md"
