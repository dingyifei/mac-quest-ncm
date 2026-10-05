#!/bin/zsh
# Usage: sudo zsh share-off.sh
TOK=$(cat ~/projects/personal/ncm/docs/evidence/S1-20261005/pf-token 2>/dev/null)
pfctl -a com.apple/questlink -F all
[ -n "$TOK" ] && pfctl -X "$TOK"
echo "anchor flushed, token $TOK released"
