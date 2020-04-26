version       = "0.3.2"
author        = "Danil Yarantsev (Yardanico)"
description   = "Discord-IRC bridge with support for Discord webhooks"
license       = "MIT"
srcDir        = "src"
bin           = @["ircord"]


requires "nim >= 1.0.0", "irc", "parsetoml", "dimscord", "https://github.com/mark-summerfield/diff"