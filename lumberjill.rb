#!/usr/bin/env ruby

require 'securerandom'
require 'telegram/bot'

# FIXME: Figure out a way to have the bot actually respond to CTRL-C
# etc. and exit gracefully and appropriately.

# FIXME: Add handling for commands:
#   /auth [token]           # authenticate
#   /set_timeout [seconds]  # update tree timeout
#   /set_tree_name [name]   # set tree name
#   /commit                 # commit file to tree

# FIXME: Figure out some kind of authentication timeout and
# leave group on failure.

# FIXME: Load secrets from config, not like this.
require_relative 'secrets.rb'

$chat_state = {}

 # FIXME: Is there a better way to get bot id?
$bot_id, = $token.split(':')

class ChatState
  # FIXME: Store *all* of this persistently, somehow.

  attr_reader :authed, :auth_attempts, :auth_token, :tree_name

  def initialize(id)
    @authed = false
    @auth_attempts = 0
    @tree_name = id.to_s

    @auth_token = SecureRandom.urlsafe_base64
  end

  def attempt_auth(text)
    if @auth_token == text
      @authed = true
    else
      @auth_attempts += 1
    end
  end
end

def main
  Telegram::Bot::Client.run($token) do |bot|
    # FIXME: Handle message for when added to group.
    bot.listen do |message|
      if message.chat.type != "group"
        puts "Not a group message! Ignoring!"
        next
      end

      id = message.chat.id

      # FIXME: Handle leaving chat whether authed or not. Delete
      # config/state from hash at this point.
      # FIXME: This doesn't work right. Detect kicked from group and
      # respond. Have a look at Telegram::Bot::Types::ChatMemberUpdated.
      if message.respond_to?("left_chat_member")
        lcm = message.left_chat_member
        if !lcm.nil?
          if lcm.id == $bot_id
            puts "Booted from chat! Clearing state..."
            $chat_state[id] = nil
            next
          end
        end
      end

      cs = $chat_state[id]
      if cs == nil
        cs = ChatState.new id
        $chat_state[id] = cs

        # FIXME: Don't send new auth request here unconditionally.
        # It's bad. Track if initial auth request message has been
        # sent, etc. This will be easier when state is persistent.
        # Furthermore, actually send these things in response to
        # some appropriate joined chat message type rather than
        # just not having state.
        begin
          bot.api.send_message(
            chat_id: $admin_chat_id,
            text: "New auth request.\nChat name: %s\nToken: %s" %
              [message.chat.title, cs.auth_token]
          )
          bot.api.send_message(
            chat_id: id,
            text: "Please enter authentication token to continue."
          )
        rescue Telegram::Bot::Exceptions::ResponseError
          # FIXME: Actually handle this correctly.
          STDERR.puts "Message send failed! Response error!"
        end
        next
      end

      if !cs.authed
        if message.respond_to?("text") && !message.text.nil?
          cs.attempt_auth message.text

          if !cs.authed
            if cs.auth_attempts > 3
              # FIXME: Clean this up. Read max from config.
              # Actually leave group!
              puts "Too many auth attempts. Would leave group."
            else
              begin
                bot.api.send_message(
                  chat_id: id,
                  text: "Please enter authentication token to continue."
                )
              rescue Telegram::Bot::Exceptions::ResponseError
                # FIXME: Actually handle this correctly.
                STDERR.puts "Message send failed! Response error!"
              end
            end
          else
            begin
              bot.api.send_message(
                chat_id: id,
                text: "Successfully authenticated!"
              )
            rescue Telegram::Bot::Exceptions::ResponseError
              # FIXME: Actually handle this correctly.
              STDERR.puts "Message send failed! Response error!"
            end

            # FIXME: Automatically prompt for initial tree name here?
            # Alternatively, notify of initial tree name and instruct
            # on how to use command to set.
          end
        end
      else
        # FIXME: Switch to write to appropriate FD and append newline?
        puts "%s:log:%s" % [cs.tree_name, message.text.gsub(/\n/, "\\n")]
        # puts message.inspect
      end
    end
  end

  return 0
end

if __FILE__ == $0
  exit main()
end
