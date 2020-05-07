# Ircord - Discord <-> IRC bridge written in Nim
This project is an IRC <-> Discord bridge, mainly created for Nim IRC channels.
Ircord only depends on OpenSSL (for https), everything else is pure-Nim.

This library is made possible by:

- https://github.com/krisppurg/dimscord library by @krisppurg who also helped me to understand Discord API better :)

- https://github.com/nim-lang/irc library by @dom96

- https://github.com/nitely/nim-regex and https://github.com/zevv/npeg for some text parsing.

- https://github.com/NimParsers/parsetoml for TOML configuration.

- https://github.com/mark-summerfield/diff or message edits diffing.

- https://ix.io for handling big messages/code snippets.


The bot is asynchronous and should be fully cross-platform (there's no OS-specific stuff in the bot).

To configure the bot, copy the config file from ircord_default.toml to ircord.toml and edit to your liking.
You'll need a Discord bot token (it's used in Ircord for mentioning users in Discord from IRC), and
a mapping with IRC channel name, Discord channel ID and a webhook URL for that channel.
