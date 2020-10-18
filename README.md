# Ircord - Discord <-> IRC bridge written in Nim
This project is an IRC <-> Discord bridge, mainly created for Nim IRC channels.
Ircord only depends on OpenSSL (for https), everything else is pure-Nim.


IRC admin commands (the command itself and the response are not sent to Discord)
- `!getdiscid <string>` - shows IDs of all Discord users which have that string in their name
- `!getlastid` - shows ID of the last person who sent a message in the current channel on Discord
- `!bandisc <number>` - bans the person with that ID on the Discord server
- `!status` - shows bot uptime

This library is made possible by:

- https://github.com/krisppurg/dimscord library by @krisppurg who also helped me to understand Discord API better :)

- https://github.com/nim-lang/irc library by @dom96

- https://github.com/nitely/nim-regex and https://github.com/zevv/npeg for some text parsing.

- https://github.com/NimParsers/parsetoml for TOML configuration.

- https://github.com/mark-summerfield/diff or message edits diffing.

- https://play.nim-lang.org and https://ix.io for handling big messages/code snippets.


The bot is asynchronous and should be fully cross-platform (there's no OS-specific stuff in the bot).

To configure the bot, copy the config file from ircord_default.toml to ircord.toml and edit to your liking.
You'll need a Discord bot token (it's used in Ircord for mentioning users in Discord from IRC), and
a mapping with IRC channel name, Discord channel ID and a webhook URL for that channel.

Some of the features:

- Pinging people in Discord from IRC

- Converting IRC formatting to Discord's markdown and vice-versa

- Word-wrapping big messages or code pastes and sending them with ix.io / paste.rs
