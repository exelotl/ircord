# Package

version       = "0.1.0"
author        = "Danil Yarantsev (Yardanico)"
description   = "Discord-IRC bridge with support for Discord webhooks"
license       = "MIT"
srcDir        = "src"
bin           = @["ircord"]

# Dependencies

requires "nim >= 0.18.0", "irc", "parsetoml", "websocket", "zip"