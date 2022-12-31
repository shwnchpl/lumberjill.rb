#!/bin/bash

if [ ! $# -eq 1 ]; then
  echo "usage: $0 [path-to-git-tree]"
  exit 1
fi

git -C "$1" add -A
git -C "$1" commit -m "Auto-commit: $(date)"
git -C "$1" remote | xargs -L1 git -C "$1" push
