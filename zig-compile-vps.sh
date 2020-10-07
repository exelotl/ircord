#!/bin/bash
nim c -d:release --stackTrace:on --lineTrace:on \
--cc:clang --clang.exe="zigcc" --clang.linkerexe="zigcc" \
--passC:"-target x86_64-linux-gnu.2.24 -O2" --passL:"-target x86_64-linux-gnu.2.24 -O2" -o:ircordvps src/ircord.nim