#!/usr/bin/env ruby

require 'securerandom'
require 'telegram/bot'

# TODO: Figure out some kind of authentication timeout?

# FIXME: Be on the lookout for rogue 502 error. This happens in call
# and is hard to handle using the listen loop. Possibly better to call
# fetch_updates manually?

# FIXME: Load secrets from config, not like this.
require_relative 'secrets.rb'

# FIXME: Read from config!
$chat_state = {}
$max_failed_auths = 3
#$maul_pipe = ""
$maul_pipe = "/tmp/maul.fifo"

class ChatState
  # FIXME: Store *all* of this persistently, somehow.

  attr_reader :auth_token, :id
  attr_accessor :authed, :tree_name, :auth_attempts, :admin_auth_sent

  def initialize(id)
    @authed = false
    @auth_attempts = 0
    @admin_auth_sent = false
    @id = id
    @tree_name = id.to_s
    @auth_token = SecureRandom.urlsafe_base64
  end
end

class BotController
  def initialize(bot, bot_user)
    @bot = bot
    @bot_user = bot_user
  end

  def dispatch(msg)
    case msg
    when Telegram::Bot::Types::ChatMemberUpdated
      handle_member_updated msg
    when Telegram::Bot::Types::Message
      handle_message msg
    else
      STDERR.puts "Unhandled message type: #{msg.inspect}"
    end
  end

  private

  def handle_member_updated(msg)
    chat_id = msg.chat.id
    member = msg.new_chat_member

    if member.user.id == @bot_user.id
      if member.status == "left"
        $chat_state.delete chat_id
      elsif member.status == "member" && $chat_state[chat_id].nil?
        cs = ChatState.new chat_id
        $chat_state[chat_id] = cs
        send_auth_request(msg, cs)
      end
    end
  end

  def handle_message(msg)
    if msg.chat.type != "group"
      return
    end

    chat_id = msg.chat.id

    if !msg.text.nil?
      cs = $chat_state[chat_id]

      if cs == nil
        # XXX: This shouldn't really every happen since state is
        # persistent. On the off chance it does, we probably *do* want
        # to start the authentication process unless the message we've
        # received is one notifying that we're no longer in the chat.
        # Those messages don't seem to have a text component, so this
        # should be safe.
        cs = ChatState.new chat_id
        $chat_state[chat_id] = cs
        send_auth_request(msg, cs)
      elsif !cs.authed
        attempt_auth(msg, cs)
      else
        escaped_text = msg.text.gsub(/\n/, "\\n") + "\n"
        handle_command(msg, cs, escaped_text) ||
          emit_text(cs, "log", escaped_text)
      end
    end
  end

  def extract_command(text)
    if text.match(/^\/(\w+)(@)?(?(2)#{@bot_user.username}|)\s*(\w*)$/)
      return $1, $3
    end
  end

  def handle_command(msg, cs, text)
    cmd, arg = extract_command text

    case extract_command text
    in ["set_timeout", timeout] unless Integer(timeout, exception: false).nil?
      timeout = timeout.to_i.to_s
      emit_text(cs, "timeout", timeout)
      chat_send(cs, "Timeout updated to #{timeout} seconds.", msg)
    in ["set_tree_name", name] unless name.nil? || name == ""
      cs.tree_name = name.gsub(/:/, "_")
      chat_send(cs, "Tree name updated to \"#{name}\".", msg)
    in ["commit",]
      emit_text(cs, "commit", "")
      chat_send(cs, "Commit message sent.", msg)
    in ["ping",]
      chat_send(cs, "Pong!", msg)
    else
      return false
    end

    true
  end

  def attempt_auth(msg, cs)
    if cs.auth_token != msg.text
      cs.auth_attempts += 1

      if cs.auth_attempts >= $max_failed_auths
        chat_send(cs, "Too many auth attempts. Leaving the group.", msg)

        begin
          @bot.api.leave_chat(chat_id: cs.id)
          $chat_state.delete cs.id
        rescue Telegram::Bot::Exceptions::ResponseError
          # FIXME: Handle error from this?
        end
      else
        send_auth_request(msg, cs)
      end
    else
      cs.authed = true

      text = <<~END
        Successfully authenticated!

        Tree name defaults to chat id: "#{cs.tree_name}"

        To change this, please use the /set_tree_name command.
      END

      chat_send(cs, text, msg)
    end
  end

  def chat_send(cs, text, msg=nil)
    @bot.api.send_message(
      chat_id: cs.id,
      text: text,
      reply_to_message_id: (msg.message_id if msg.respond_to? :message_id),
      allow_sending_without_reply: true
    )
  rescue Telegram::Bot::Exceptions::ResponseError
    # FIXME: Actually handle this correctly.
    STDERR.puts "Message send failed! Response error!"
  end

  def send_auth_request(msg, cs)
    if !cs.admin_auth_sent
      begin
        text = <<~END
            New auth request.
            Chat name: #{msg.chat.title}
            Token: #{cs.auth_token}
        END

        @bot.api.send_message(chat_id: $admin_chat_id, text: text)
        cs.admin_auth_sent = true
      rescue Telegram::Bot::Exceptions::ResponseError
        # FIXME: Actually handle this correctly.
        STDERR.puts "Message send failed! Response error!"
      end
    end

    chat_send(cs, "Please enter authentication token to continue.", msg)
  end

  def emit_text(cs, command, text)
    if $maul_pipe == ""
      # XXX: In order for this to work correctly with maul.rb, the
      # glue script fifo-tee.sh or some similar middleware is necessary.
      # This is because the fifo must be opened, written, and closed
      # before maul.rb will process an entry.
      STDOUT.puts "#{command}:#{cs.tree_name}:#{text}"
      STDOUT.flush
    else
      File.open($maul_pipe, "w") do |f|
        f.write "#{command}:#{cs.tree_name}:#{text}"
        f.flush
      end
    end
  end
end

def main
  Telegram::Bot::Client.run($token) do |bot|
    response = bot.api.get_me

    if !response["ok"]
      STDERR.puts "Failed to get bot info. Token may be invalid."
      return 1
    end

    data = response["result"]
    if data["id"].nil? || data["username"].nil?
      STDERR.puts "Failed to get bot ID or username."
      return 1
    end

    bot_user = Telegram::Bot::Types::User.new data

    bot.api.set_my_commands(
      commands: [
        Telegram::Bot::Types::BotCommand.new(
          command: "commit",
          description: "Commits the current file."
        ),
        Telegram::Bot::Types::BotCommand.new(
          command: "ping",
          description: "Responds with pong."
        ),
        Telegram::Bot::Types::BotCommand.new(
          command: "set_timeout",
          description: "Sets timeout for chat."
        ),
        Telegram::Bot::Types::BotCommand.new(
          command: "set_tree_name",
          description: "Sets the log file tree name."
        ),
      ],
      scope: Telegram::Bot::Types::BotCommandScopeAllGroupChats.new()
    )

    controller = BotController.new(bot, bot_user)

    # FIXME: This can throw an exception if the server gives us a
    # 502 error, which seems to sometimes happen. It's not great to
    # crash the entire bot in this case, but unfortunately it's hard
    # to actually deal with this issue without using our own run loop
    # that directly calls fetch_updates, which is probably the best
    # course of action.
    bot.listen { |msg| controller.dispatch msg }
  end

  return 0
end

if __FILE__ == $0
  exit main
end
