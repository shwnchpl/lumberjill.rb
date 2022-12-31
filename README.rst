lumberjill.rb
=============

lumberjill.rb is a Telegram bot that listens for messages in groups and
outputs those messages in a plaintext format designed to be consumed by
`maul.rb`_.

.. _maul.rb: https://github.com/shwnchpl/maul.rb

Installation
------------

With Ruby and the `Ruby Bundler`_ installed, lumberjill.rb can be
installed as follows using the provided Makefile::

    # make install

.. _Ruby Bundler: https://bundler.io/

Setup
-----

#. Create a Telegram bot using ``@BotFather`` to get an API token.
#. Ensure group "Privacy Mode" is not enabled for the bot.
#. Note the ID of the Telegram account to be used as admin using
   ``@userinfobot`` or something similar.
#. Create a configuration file with API token and admin id.
#. If desired, install and configure aul.rb and configure
   lumberjill.rb to write its output to the maul.rb pipe.

Usage
-----

With lumberjill.rb running and connected to the bot you've created,
start a conversation with that bot from your admin account. Next, add
your bot to any conversations that you would like to log. The bot will
message your admin account with authentication tokens to be copied into
each chat. Once this has been done, on the server side lumberjill.rb
will log all messages for that group (either to STDOUT or some named
pipe, depending on configuration).

Additionally, the following commands are supported::

    /commit             - Log a maul.rb commit command for this chat's tree.
    /ping               - Respond with pong (useful to check if the bot is
                          listening).
    /set_timeout NUM    - Set the tree timeout to NUM seconds.
    /set_tree_name STR  - Set the tree name to STR.

All chat state (including tree name, authentication, etc.) is stored
persistently in a plain-text YAML file named ``state.yaml`` whose
location is configurable (see below).

Configuration
-------------

lumberjill.rb looks for YAML configuration files at
``/etc/lumberjill/config.yaml`` and
``$HOME/.config/lumberjill/config.yaml``. Configuration options
specified in user config files takes precedence over their corresponding
options in the system configuration file. The following keys are
supported::

    admin_id            - ID of Telegram user to be treated as admin.
                          (mandatory)
    bot_token           - Telegram bot token.
                          (mandatory)
    cache_dir           - Directory in which to store the state.yaml
                          persistant state file.
                          (default: $HOME/.cache/lumberjill)
    max_failed_auths    - Maximum number of failed authentications
                          before the both leaves the group chat.
                          (default: 3)
    max_retries         - Maximum number of retries on HTTP response
                          error.
                          (default: 2)
    fifo_path           - Path to a named pipe where output should be
                          written. If unspecified, output goes to
                          STDOUT.

If at least ``admin_id`` and ``bot_token`` are not specified,
lumberjill.rb will fail to run.

Here is an example minimal configuration file for use with maul.rb::

    ---
    lumberjill:
      admin_id: "123456789"
      bot_token: "987654321:mysupersecrettoken"
      fifo_path: "/tmp/maul.fifo"

Examples
--------

Running lumberjill.rb and maul.rb on a server, it may be desirable to
create systemd unit files to run the services automatically. Example
unit files are provided in the ``examples/`` directory. Additionally,
provided is a simple utility script ``autocommit.sh``, which
automatically attempts to create a git commit with any changes to some
directory tree and pushes it to all remotes, as well as systemd unit
files to run this script every 15 minutes.

If installing these units to be run as a user, be sure to first run
``loginctl enabled-linger USER`` first, where ``USER`` is the name of
the user from which the units will be run.

License
-------

lumberjill.rb is the work of Shawn M. Chapla and it is released under
the MIT license. For more details, see the LICENSE file.
