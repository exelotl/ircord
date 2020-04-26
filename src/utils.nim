import dimscord, asyncdispatch, strutils, options

proc getUsers*(s: DiscordClient, guild, part: string): Future[seq[User]] {.async.} = 
  ## Get all users whose usernames contain `part` string
  result = @[]
  var data = await s.api.getGuildMembers(guild, 1000, "0")
  for member in data:
    if part in $member.user:
      let user = member.user
      result.add(user)