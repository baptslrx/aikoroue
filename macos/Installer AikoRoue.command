#!/bin/bash
cd "$(dirname "$0")"
./build.sh --install 2>&1 | tee build.log
echo
read -n 1 -s -r -p "Appuie sur une touche pour fermer…"
