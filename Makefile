INSTALL_ROOT?=
INSTALL_PREFIX?=/usr/local

INSTALL_PATH?=${INSTALL_ROOT}${INSTALL_PREFIX}

install:
	bundle install
	install -m 755 lumberjill.rb ${INSTALL_PATH}/bin/lumberjill.rb

uninstall:
	rm -f ${INSTALL_PATH}/bin/lumberjill.rb
