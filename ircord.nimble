version       = "0.5.2"
author        = "Danil Yarantsev (Yardanico)"
description   = "Discord-IRC bridge with support for Discord webhooks and more!"
license       = "MIT"
srcDir        = "src"
bin           = @["ircord"]


requires "nim >= 1.2.0", "irc", "parsetoml", "dimscord", "diff", "npeg >= 0.23.0"