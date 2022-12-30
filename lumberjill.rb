#!/usr/bin/env ruby

require 'erb'
require 'fileutils'
require 'securerandom'
require 'telegram/bot'
require 'yaml'
require 'yaml/store'

# TODO: Consider adding some sort of authentication timeout.

def attempt_then_log(retries: 0, &block)
  attempts ||= retries
  block.call
rescue Faraday::TimeoutError, Faraday::ConnectionFailed
  retry
rescue Telegram::Bot::Exceptions::ResponseError => err
  attempts += 1
  retry unless attempts > retries
  STDERR.puts <<~END
    ResponseError after #{attempts} attempts: #{err.message}
    Backtrace: #{err.backtrace.inspect}
  END
  nil
end

class BotController
  class Error < RuntimeError
  end

  def initialize(bot:, config:, state:)
    @bot = bot
    @bot_user = nil
    @config = config
    @state = state
  end

  def fetch_user
    @bot_user = attempt_then_log(retries: @config.max_retries) do
      r = @bot.api.get_me
      Telegram::Bot::Types::User.new r["result"] unless
        !r["ok"] || r["result"]["id"].nil? || r["result"]["username"].nil?
    end

    if @bot_user.nil?
      raise BotController::Error.new(
        "Failed to get bot info. Token may be invalid."
      )
    end
  end

  def listen
    # XXX: It would be nice to be able to use the Telegram::Bot::Client
    # listen method, but unfortunately this can throw an exception if
    # the server gives us a 502 error, which seems to sometimes happen.
    # It's not great to crash the entire bot in this case, but
    # unfortunately it's hard to actually deal with this issue without
    # writing our own custom run loop, which is what has been done here.
    loop do
      response = attempt_then_log(retries: @config.max_retries) do
        begin
          @bot.api.get_updates(@bot.options)
        end
      end

      if response.nil?
        # XXX: Back off for a bit before trying again. We don't want
        # to DDOS the Telegram servers if something is wrong.
        sleep 30
      end

      next unless response&.fetch("ok", false)

      response['result'].each do |data|
        dispatch @bot.handle_update(
          Telegram::Bot::Types::Update.new data
        )
      end
    end
  end

  def register_commands
    attempt_then_log(retries: @config.max_retries) do
      @bot.api.set_my_commands(
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
    end
  end

  private

  def chat_auth(cs, msg)
    if cs[:auth_token] != msg.text
      cs[:auth_attempts] += 1

      if cs[:auth_attempts] >= @config.max_failed_auths
        chat_send(cs, "Too many auth attempts. Leaving the group.", msg)

        attempt_then_log(retries: @config.max_retries) do
          @bot.api.leave_chat(chat_id: cs[:id])
          @state.delete cs[:id]
        end
      else
        chat_auth_request(cs, msg)
      end
    else
      cs[:authed] = true

      text = <<~END
        Successfully authenticated!

        Tree name defaults to chat id: "#{cs[:tree_name]}"

        To change this, please use the /set_tree_name command.
      END

      chat_send(cs, text, msg)
    end
  end

  def chat_auth_request(cs, msg)
    if !cs[:admin_auth_sent]
      text = <<~END
        New auth request.
        Chat name: #{msg.chat.title}
        Token: #{cs[:auth_token]}
      END

      attempt_then_log(retries: @config.max_retries) do
        @bot.api.send_message(chat_id: @config.admin_id, text: text)
        cs[:admin_auth_sent] = true
      end
    end

    chat_send(cs, "Please enter authentication token to continue.", msg)
  end

  def chat_send(cs, text, msg=nil)
    attempt_then_log(retries: @config.max_retries) do
      @bot.api.send_message(
        chat_id: cs[:id],
        text: text,
        reply_to_message_id: (msg.message_id if msg.respond_to? :message_id),
        allow_sending_without_reply: true
      )
    end
  end

  def command_extract(text)
    if text.match(/^\/(\w+)(@)?(?(2)#{@bot_user.username}|)\s*(\w*)$/)
      return $1, $3
    end
  end

  def command_process(cs, text, msg)
    cmd, arg = command_extract text

    case command_extract text
    in ["set_timeout", timeout] unless Integer(timeout, exception: false).nil?
      timeout = timeout.to_i.to_s
      emit(cs, "timeout", timeout)
      chat_send(cs, "Timeout updated to #{timeout} seconds.", msg)
    in ["set_tree_name", name] unless name.nil? || name == ""
      cs[:tree_name] = name.gsub(/:/, "_")
      chat_send(cs, "Tree name updated to \"#{name}\".", msg)
    in ["commit",]
      emit(cs, "commit", "")
      chat_send(cs, "Commit message sent.", msg)
    in ["ping",]
      chat_send(cs, "Pong!", msg)
    else
      return false
    end

    true
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

  def emit(cs, command, text)
    if @config.fifo_path.nil?
      # XXX: In order for this to work correctly with maul.rb, the
      # glue script fifo-tee.sh or some similar middleware is necessary.
      # This is because the fifo must be opened, written, and closed
      # before maul.rb will process an entry.
      STDOUT.puts "#{command}:#{cs[:tree_name]}:#{text}"
      STDOUT.flush
    else
      File.open(@config.fifo_path, "w") do |f|
        f.write "#{command}:#{cs[:tree_name]}:#{text}"
        f.flush
      end
    end
  end

  def handle_member_updated(msg)
    chat_id = msg.chat.id
    member = msg.new_chat_member

    # XXX: This is a potentially lengthy transaction, but that shouldn't
    # matter because we are running in one thread and nothing else
    # should need to access this state.
    @state.transaction do
      if member.user.id == @bot_user.id
        if member.status == "left"
          @state.delete chat_id
        elsif member.status == "member" && @state[chat_id].nil?
          cs = ChatState::initial chat_id
          @state[chat_id] = cs
          chat_auth_request(cs, msg)
        end
      end
    end
  end

  def handle_message(msg)
    return unless msg.chat.type == "group"

    chat_id = msg.chat.id

    # XXX: This is a potentially lengthy transaction, but that shouldn't
    # matter because we are running in one thread and nothing else
    # should need to access this state.
    @state.transaction do
      if !msg.text.nil?
        cs = @state[chat_id]

        if cs == nil
          # XXX: This shouldn't really every happen since state is
          # persistent. On the off chance it does, we probably *do* want
          # to start the authentication process unless the message we've
          # received is one notifying that we're no longer in the chat.
          # Those messages don't seem to have a text component, so this
          # should be safe.
          cs = ChatState::initial chat_id
          @state[chat_id] = cs
          chat_auth_request(cs, msg)
        elsif !cs[:authed]
          chat_auth(cs, msg)
        else
          escaped_text = msg.text.gsub(/\n/, "\\n") + "\n"
          command_process(cs, escaped_text, msg) ||
            emit(cs, "log", escaped_text)
        end
      end
    end
  end
end

module ChatState
  def self.initial(id)
    {
      :admin_auth_sent => false,
      :auth_attempts => 0,
      :auth_token => SecureRandom.urlsafe_base64,
      :authed => false,
      :id => id,
      :tree_name => id.to_s,
    }
  end

  def self.load(path)
    FileUtils.mkdir_p(path)
    state_path = File.join(path, "state.yaml")

    YAML::Store.new state_path
  end
end

class Config
  class Error < RuntimeError
  end

  def initialize(*paths)
    # Default values.
    attrs = {
      :admin_id => nil,
      :bot_token => nil,
      :cache_dir => File.join(Dir.home, ".cache", "lumberjill"),
      :max_failed_auths => 3,
      :max_retries => 2,
      :fifo_path => nil,
    }

    # Load configuration from user and system files.
    paths.each { |p| attrs.merge! Config::load_config(p) }

    attrs.each do |k, v|
      singleton_class.class_eval { attr_accessor k }
      instance_variable_set("@#{k}", v)
    end

    if @admin_id.nil?
      raise Config::Error.new "admin_id must be specified"
    end

    if @bot_token.nil?
      raise Config::Error.new "bot_token must be specified"
    end
  end

  private

  def self.load_config(path)
    YAML.load(ERB.new(File.read(path)).result).fetch("lumberjill", {})
  rescue Errno::ENOENT
    {}
  end
end

def main
  config = Config.new(
    File.join("/", "etc", "lumberjill", "config.yaml"),
    File.join(Dir.home, ".config", "lumberjill", "config.yaml"),
  )
  state = ChatState::load config.cache_dir

  Telegram::Bot::Client.run(config.bot_token) do |bot|
    controller = BotController.new(
      bot: bot,
      config: config,
      state: state
    )

    catch :botcontroller_stop do
      Signal.trap("INT") { throw :botcontroller_stop }

      controller.fetch_user
      controller.register_commands
      controller.listen
    end

    Signal.trap("INT", "DEFAULT")
  end
end

if __FILE__ == $0
  main
end
